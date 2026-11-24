/// 同步编排：把「发现」「传输」「合并」串成用户按下按钮后的一条路径。
///
/// 生命周期（谁在什么时候做什么）：
///   - App 启动 → start()：开 WebSocket 服务端 + 开 UDP 广播。
///     这一步只是「守在门口」，不代表会自动同步。
///   - 用户点「同步」→ syncNow()：找出**所有**新鲜对端 → 依次拨号 → 互换状态 →
///     合并落库 → 返回可读结果。同一时间只允许一次。
///   - 别人点「同步」拨到我们 → onRemoteState 合并并回发，然后通过
///     applied 流通知界面刷新（用户会在自己那边看到结果）。
///   - App 退出 → dispose()。
/// 明确不做：后台定时同步、自动发现即同步（OUT-01 / OUT-02）。
///
/// 和 N 台设备交换的具体做法在 mesh.dart（那边不依赖广播，可以直接单测）。
library;

import 'dart:async';
import 'dart:io' show stderr;

import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/sync/discovery.dart';
import 'package:pnote/sync/merge.dart';
import 'package:pnote/sync/notes_channel.dart';
import 'package:pnote/sync/mesh.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/scan.dart';
import 'package:pnote/sync/sync_result.dart';
import 'package:pnote/sync/transport.dart';

/// 对端推来数据并合并完成后的通知（界面据此刷新与提示）。
class SyncApplied {
  const SyncApplied({required this.peerName, required this.stats});
  final String peerName;
  final MergeStats stats;
}

class SyncService {
  SyncService({
    required this.dao,
    required this.deviceName,
    this.notes,
    String? account,
  }) {
    _account = account;
  }

  final TaskDao dao;
  final String deviceName;

  /// 笔记同步通道（1.47）。为 null 时只同步任务。
  final NotesChannel? notes;

  /// 当前账号名（1.51）。null 表示还没从 meta 读出来，[start] 时补读。
  String? _account;

  /// 当前账号。对界面/服务端始终是有效值（空时退回默认账号）。
  String get account => normalizeAccount(_account ?? kDefaultAccount);

  /// 改账号：只改内存里的名字 + 让广播立刻带新名字，不重启服务。
  /// 落库由调用方负责（设置页写 meta），这样失败时不会两边不一致。
  void setAccount(String name) {
    _account = normalizeAccount(name);
    _discovery?.account = _account!;
  }

  SyncServer? _server;
  LanDiscovery? _discovery;
  bool _started = false;
  String? _startError;
  bool _syncing = false;

  /// 这一趟同步是否已经扫过网段，以及扫描结果（见 [_scanOnce]）。
  bool _rescanned = false;
  List<Peer> _scanCache = const [];

  final StreamController<SyncApplied> _applied =
      StreamController<SyncApplied>.broadcast();
  final StreamController<List<Peer>> _peers =
      StreamController<List<Peer>>.broadcast();

  /// 别人拨号过来、合并完成时推一次。
  Stream<SyncApplied> get applied => _applied.stream;

  /// 当前能看见的对端列表（变化时推一次）。
  Stream<List<Peer>> get peerChanges => _peers.stream;

  List<Peer> get peers => [for (final p in _discovery?.peers ?? const <Peer>[])
    if (_isSameAccount(p)) p];

  /// 广播里听见了、但账号不同的设备（不参与同步，界面单独列出来）。
  List<Peer> get otherAccountPeers => [
        for (final p in _discovery?.peers ?? const <Peer>[])
          if (!_isSameAccount(p)) p,
      ];

  /// 扫描兜底找到的候选还没有账号信息（account 为空），先放行去拨号，
  /// 真正的账号由 state 报文回来时校验。
  bool _isSameAccount(Peer peer) =>
      peer.account.isEmpty || peer.account == account;

  String get deviceId => dao.clock.deviceId;

  /// 本机显示用的短名：设备名 + id 前 8 位（规格 8.1 ⑤）。
  String get displayName => '$deviceName · ${deviceId.substring(0, 8)}';

  bool get isStarted => _started;

  Future<void> start() async {
    if (_started || _startError != null) return;
    var step = '启动';
    try {
      _account ??= normalizeAccount(
        await dao.readSetting(kAccountKey) ?? kDefaultAccount,
      );
      step = '打开 WebSocket 端口';
      final server = SyncServer(
        deviceId: deviceId,
        onRemoteState: _onRemoteState,
        notes: notes,
        accountOf: () => account,
      );
      await server.start();
      _server = server;

      step = '打开 UDP 广播';
      final discovery = LanDiscovery(
        deviceId: deviceId,
        deviceName: deviceName,
        servicePort: server.boundPort!,
        account: account,
      );
      await discovery.start();
      _discovery = discovery;
      step = '订阅广播';
      discovery.peerChanges.listen((list) {
        if (!_peers.isClosed) _peers.add(list);
      });
      _started = true;
    } catch (e) {
      _startError = '$step失败：$e';
      stderr.writeln('[pnote] 同步服务启动失败 —— $_startError');
    }
  }

  /// 启动失败时的原因（界面上直接显示，方便用户回报问题）。
  String? get startError => _startError;

  /// 本机 WebSocket 实际监听的端口（1.19 起给"连接设备"页显示用）。
  /// 端口可能从 47822 起回退，所以取服务器真正绑定的那个。
  int? get servicePort => _server?.boundPort;

  /// 对端拨号过来：合并它给的状态，把本机合并后的全量回给它。
  Future<SyncState> _onRemoteState(SyncState remote) async {
    final stats = await dao.applyRemote(remote);
    if (!_applied.isClosed) {
      _applied.add(SyncApplied(peerName: remote.deviceName, stats: stats));
    }
    return dao.exportState(deviceName: deviceName);
  }

  /// 补充轮开始前给广播留的时间：每台 700 ms 发一次，300 ms 够听见
  /// 「刚刚上线」的那一台，又不至于让用户明显等待。
  static const Duration kPeerSettle = Duration(milliseconds: 300);

  /// 用户按下「同步」：和同一局域网里**所有**被发现的设备交换状态。
  ///
  /// 1.14 起不再「只找一台」；1.15 起每次按下都会**边同步边重新收集**
  /// 对端（见 mesh.dart 的 syncMesh），避免「按下那一刻没听见的设备」
  /// 被整趟漏掉。
  Future<SyncBatch> syncNow({
    Duration discoveryWait = const Duration(seconds: 3),
  }) async {
    if (_syncing) {
      return SyncBatch.single(
        const SyncResult.failed(SyncFailure.localError, detail: '正在同步中'),
      );
    }
    await start();
    if (!_started) {
      return SyncBatch.single(
        SyncResult.failed(SyncFailure.notStarted, detail: _startError),
      );
    }

    _syncing = true;
    _rescanned = false;
    _scanCache = const [];
    try {
      final results = await syncMesh(
        dao: dao,
        deviceName: deviceName,
        notes: notes,
        account: account,
        collectPeers: (pass) => _collectPeers(pass, discoveryWait),
      );
      if (results.isEmpty) {
        final others = otherAccountPeers.length;
        if (others > 0) {
          return SyncBatch.single(
            SyncResult.failed(
              SyncFailure.account,
              detail: '发现 $others 台其它账号',
            ),
          );
        }
        return SyncBatch.single(const SyncResult.failed(SyncFailure.noPeer));
      }
      return SyncBatch(results);
    } finally {
      _syncing = false;
    }
  }

  /// 第 [pass] 轮「现在能和谁同步」。
  Future<List<Peer>> _collectPeers(int pass, Duration discoveryWait) async {
    if (pass == 0) {
      final targets = await _collectTargets(discoveryWait);
      if (targets.isNotEmpty) return targets;
      // 广播没动静 → 兜底扫网段（广播被 AP / 防火墙吞掉是常态）。
      return _scanOnce();
    }
    // 补充轮：先等一小会儿，让正在广播的设备把这一声发出来。
    await Future<void>.delayed(kPeerSettle);
    final fresh = _freshPeers();
    if (fresh.isNotEmpty) return fresh;
    return _scanOnce();
  }

  /// 扫网段兜底。一趟同步里最多扫一次（扫一次要几秒，重复扫纯属浪费）。
  Future<List<Peer>> _scanOnce() async {
    if (_rescanned) return _scanCache;
    _rescanned = true;
    _scanCache =
        await scanLanForPeers(port: _server?.boundPort ?? kSyncPort);
    return _scanCache;
  }

  /// 收集这一轮要同步的对端：优先用已有的广播列表；一条都没有时才等广播。
  Future<List<Peer>> _collectTargets(Duration wait) async {
    final known = _freshPeers();
    if (known.isNotEmpty) return known;

    final appeared = await _waitForFirstPeer(wait);
    if (!appeared) return const [];

    // 同一批广播里通常还有别的设备（每台 700ms 发一次），
    // 多等一小会儿把它们一起收进来，避免「只同步到先到的那一台」。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return _freshPeers();
  }

  /// 等到第一台新鲜对端出现（最多 wait）。返回是否等到了。
  Future<bool> _waitForFirstPeer(Duration wait) async {
    final completer = Completer<bool>();
    final timer = Timer(wait, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    late final StreamSubscription<List<Peer>> sub;
    void check(List<Peer> _) {
      if (_freshPeers().isNotEmpty && !completer.isCompleted) {
        completer.complete(true);
      }
    }

    sub = _peers.stream.listen(check);
    final appeared = await completer.future;
    timer.cancel();
    await sub.cancel();
    return appeared;
  }

  /// 当前所有「活着」的对端，按最近一次广播倒序，同一台设备只留一条。
  List<Peer> _freshPeers() {
    final byKey = <String, Peer>{};
    for (final peer in peers) {
      if (!peer.isFresh() || peer.deviceId == deviceId) continue;
      final key = peerKey(peer);
      final prev = byKey[key];
      if (prev == null || peer.lastSeen.isAfter(prev.lastSeen)) {
        byKey[key] = peer;
      }
    }
    final list = byKey.values.toList()
      ..sort((a, b) {
        final byTime = b.lastSeen.compareTo(a.lastSeen);
        return byTime != 0 ? byTime : a.deviceId.compareTo(b.deviceId);
      });
    return list;
  }

  Future<void> dispose() async {
    await _discovery?.dispose();
    await _server?.stop();
    _discovery = null;
    _server = null;
    _started = false;
    await _applied.close();
    await _peers.close();
  }
}
