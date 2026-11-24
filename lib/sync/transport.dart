/// 局域网传输：一个极小的 WebSocket 服务端 + 一个客户端。
///
/// 为什么不用 shelf / shelf_web_socket（ADR 变更，见《PNote项目说明》7.1）：
///   我们只需要「收几条 JSON、回几条 JSON、关闭」，dart:io 的
///   HttpServer + WebSocketTransformer 十几行就够。
///
/// 一次同步（协议 /7，见 7.6 与 7.12）：
///   1. 拨号方 A --state（任务 + 笔记元信息）--> 监听方 B
///   2. B 合并任务、应用删除、算出「我需要哪些笔记」，
///      回 --state（合并后的任务 + 自己的笔记元信息 + want）--> A
///   3. A 把 B 要的内容分块 --blobs--> B，最后 --blobsDone（带上 A 自己的 want）
///   4. B 把 A 要的内容分块 --blobs--> A，最后 --blobsDone
///   5. A --ack--> B，双方关闭
/// 没有笔记（notes == null）时退化成 1→2→5，也就是旧的两帧流程。
library;

import 'dart:async';
import 'dart:io';

import 'package:pnote/data/models.dart';
import 'package:pnote/sync/notes_channel.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/payload.dart';

/// 连接/收发超时。局域网内正常应 < 200 ms，超过这个数基本就是对方卡死或被拦。
const Duration kConnectTimeout = Duration(seconds: 5);
const Duration kReceiveTimeout = Duration(seconds: 15);

/// 整趟同步（含传笔记）的上限：大文件多时给足时间，但绝不无限等。
const Duration kSessionTimeout = Duration(seconds: 90);

/// 服务端：等别人来拨号。收到对端状态后交给回调合并，再把合并结果回给对方。
class SyncServer {
  SyncServer({
    required this.deviceId,
    required this.onRemoteState,
    this.notes,
    this.preferredPort = kSyncPort,
  });

  final String deviceId;

  /// 合并对端状态并返回「本机合并后的全量状态」（会被回发给对端）。
  final Future<SyncState> Function(SyncState remote) onRemoteState;

  /// 笔记同步通道；为 null 时只说任务（测试与老场景）。
  final NotesChannel? notes;

  final int preferredPort;

  HttpServer? _server;

  /// 实际监听的端口（preferredPort 被占用时会往后顺延）。
  int? get boundPort => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    Object? lastError;
    for (var i = 0; i < 10; i++) {
      final port = preferredPort + i;
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        break;
      } on SocketException catch (e) {
        lastError = e; // 端口被占用，试下一个
      }
    }
    final server = _server;
    if (server == null) {
      throw StateError('47822–47831 端口都被占用：$lastError');
    }
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      WebSocket socket;
      try {
        socket = await WebSocketTransformer.upgrade(request);
      } on Exception {
        return;
      }
      _handle(socket);
    });
  }

  void _handle(WebSocket socket) {
    final session = _ServerSession(
      socket: socket,
      deviceId: deviceId,
      onRemoteState: onRemoteState,
      notes: notes,
    );
    session.start();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

class _ServerSession {
  _ServerSession({
    required this.socket,
    required this.deviceId,
    required this.onRemoteState,
    required this.notes,
  });

  final WebSocket socket;
  final String deviceId;
  final Future<SyncState> Function(SyncState) onRemoteState;
  final NotesChannel? notes;

  Timer? _guard;
  bool _closed = false;
  var _phase = _ServerPhase.awaitingState;

  /// 拨号方要我们发过去的路径（来自它最后一帧 blobsDone）。
  var _wanted = <String>[];

  void start() {
    // 兜底发现会「连上就关」地探端口，这类连接永远不发数据；
    // 整趟超时能保证它们不会一直挂着。
    _guard = Timer(kSessionTimeout, _close);
    // 帧必须串行处理：笔记内容是异步落盘的，并行处理会出现
    // 「一帧还在 rename、另一帧已经回执」的半成品状态。
    var chain = Future<void>.value();
    socket.listen(
      (dynamic data) {
        if (data is! String) {
          _close();
          return;
        }
        chain = chain.then((_) => _onFrame(data));
      },
      onError: (Object _) => _close(),
      cancelOnError: true,
      onDone: () => _guard?.cancel(),
    );
  }

  Future<void> _onFrame(String raw) async {
    final type = frameType(raw);
    try {
      switch (type) {
        case kTypeState:
          if (_phase != _ServerPhase.awaitingState) return;
          _phase = _ServerPhase.receivingBlobs;
          await _onState(raw);
        case kTypeBlobs:
          if (_phase != _ServerPhase.receivingBlobs) return;
          await _onBlobs(raw);
        case kTypeBlobsDone:
          if (_phase != _ServerPhase.receivingBlobs) return;
          _phase = _ServerPhase.sendingBlobs;
          await _onBlobsDone(raw);
        case kTypeAck:
          _close();
        default:
          // 不认识的帧：可能是新旧版本混跑，直接结束这一趟。
          _close();
      }
    } on Object catch (e) {
      _send(encodeAck(deviceId: deviceId, ok: false, message: '$e'));
      _close();
    }
  }

  Future<void> _onState(String raw) async {
    final envelope = decodeEnvelope(raw);
    final merged = await onRemoteState(envelope.state);
    final channel = notes;
    final remoteNotes = envelope.notes;
    if (channel == null || remoteNotes == null) {
      _send(encodeState(merged, notes: null));
      _phase = _ServerPhase.done;
      return;
    }

    // 先把删除落地（墓碑是元信息，不需要内容），再算「我需要什么」。
    await channel.apply(remoteNotes, const []);
    final local = await channel.describe();
    final want = local.wantFrom(remoteNotes);
    _send(encodeState(merged, notes: local, want: want));
  }

  Future<void> _onBlobs(String raw) async {
    final channel = notes;
    if (channel == null) return;
    final blobs = decodeBlobs(raw);
    if (blobs.isEmpty) return;
    await channel.apply(const NotesSyncState(), blobs);
  }

  Future<void> _onBlobsDone(String raw) async {
    final channel = notes;
    final done = decodeBlobsDone(raw);
    _wanted = done.want;
    if (channel == null || _wanted.isEmpty) {
      _send(encodeBlobsDone());
      _phase = _ServerPhase.done;
      return;
    }
    final blobs = await channel.read(_wanted);
    for (final chunk in chunkBlobs(blobs)) {
      _send(encodeBlobs(chunk));
    }
    final skipped = _wanted.length - blobs.length;
    _send(encodeBlobsDone(skipped: skipped));
    _phase = _ServerPhase.done;
  }

  void _send(String frame) {
    if (_closed) return;
    try {
      socket.add(frame);
    } on Object {
      _close();
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _guard?.cancel();
    try {
      socket.close().catchError((Object _) {});
    } on Object {
      // 忽略
    }
  }
}

enum _ServerPhase { awaitingState, receivingBlobs, sendingBlobs, done }

/// 一次同步交换的结果：任务状态 + 笔记落盘统计。
class SyncExchange {
  const SyncExchange({required this.state, this.notes});

  final SyncState state;
  final NotesApplyReport? notes;
}

/// 客户端：拨号到对端，互换任务与笔记。
Future<SyncExchange> exchangeWithPeerFull({
  required Peer peer,
  required SyncState local,
  NotesChannel? notes,
}) async {
  final url = 'ws://${peer.host}:${peer.port}/';
  final socket = await WebSocket.connect(url).timeout(kConnectTimeout);
  final frames = StreamIterator<String>(socket.where((dynamic d) => d is String)
      .cast<String>());

  Future<bool> next() => frames.moveNext().timeout(kReceiveTimeout);

  try {
    final channel = notes;
    // 自己的笔记元信息要一开头就发过去，对端才知道它缺什么。
    final mine = channel == null ? null : await channel.describe();
    socket.add(encodeState(local, notes: mine));
    if (!await next()) throw const SocketException('对端在回复前关闭了连接');
    final first = decodeEnvelope(frames.current);

    NotesApplyReport? report;
    final remoteNotes = first.notes;
    if (channel != null && remoteNotes != null) {
      // 1. 先把删除落地（墓碑是元信息，不需要内容）。
      report = await channel.apply(remoteNotes, const []);
      // 2. 算「我需要什么」，并把对端要的东西发过去。
      final myWant = mine!.wantFrom(remoteNotes);
      final forPeer = await channel.read(first.want);
      for (final chunk in chunkBlobs(forPeer)) {
        socket.add(encodeBlobs(chunk));
      }
      socket.add(encodeBlobsDone(
        want: myWant,
        skipped: first.want.length - forPeer.length,
      ));

      // 3. 收对端发来的内容，直到它说「发完了」。
      final incoming = <NoteBlob>[];
      while (true) {
        if (!await next()) throw const SocketException('对端没有把笔记发完');
        final type = frameType(frames.current);
        if (type == kTypeBlobs) {
          incoming.addAll(decodeBlobs(frames.current));
          continue;
        }
        if (type == kTypeBlobsDone) break;
        if (type == kTypeAck) {
          // 对端出错时会用 ack 说明原因，别当成正常结束悄悄吞掉。
          final ack = decodeAck(frames.current);
          if (!ack.ok) {
            throw PayloadException('对端没处理成：${ack.message ?? '未知原因'}');
          }
          break;
        }
        throw PayloadException('收到意外帧：$type');
      }
      if (incoming.isNotEmpty) {
        report = report + await channel.apply(remoteNotes, incoming);
      }
    }

    try {
      socket.add(encodeAck(deviceId: local.deviceId, ok: true));
    } on Object {
      // 回执失败不影响结果
    }
    return SyncExchange(state: first.state, notes: report);
  } finally {
    await frames.cancel();
    try {
      await socket.close();
    } on Object {
      // 忽略
    }
  }
}

/// 旧入口：只要任务结果（没有笔记通道时用）。
Future<SyncState> exchangeWithPeer({
  required Peer peer,
  required SyncState local,
  NotesChannel? notes,
}) async {
  final result = await exchangeWithPeerFull(peer: peer, local: local, notes: notes);
  return result.state;
}

/// 把待发内容切成若干块，每块编码后不超过 [kBlobChunkBytes]。
List<List<NoteBlob>> chunkBlobs(List<NoteBlob> blobs) {
  final out = <List<NoteBlob>>[];
  var current = <NoteBlob>[];
  var size = 0;
  for (final blob in blobs) {
    // base64 会膨胀约 4/3，估算时按 4/3 算，宁可多发几帧。
    final cost = (blob.size * 4 ~/ 3) + 200;
    if (current.isNotEmpty && size + cost > kBlobChunkBytes) {
      out.add(current);
      current = <NoteBlob>[];
      size = 0;
    }
    current.add(blob);
    size += cost;
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}
