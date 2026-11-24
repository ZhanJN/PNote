/// 同步报文的编解码。纯 Dart，不 import Flutter。
/// 报文格式见《PNote项目说明》7.6、7.12（笔记）。
library;

import 'dart:convert';

import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/notes_channel.dart';

class PayloadException implements Exception {
  const PayloadException(this.message);
  final String message;

  @override
  String toString() => '报文不合法：$message';
}

/// 协议常量。改动 proto 值即意味着「不兼容旧版本」，必须同时改文档。
///   /1 -> 只有 tasks（墓碑用 deleted_at 字段表达）
///   /2 -> 多一个 purged 数组（只有 id）
///   /3 -> purged 变成带版本的记录 [{"id":..., "hlc":{...}}]，
///         这样「清除之后又被恢复/编辑」的任务可以压过清除（见 7.10）
///   /4 -> 任务多一个可合并字段 order（1.20 手动拖拽排序）。
///   /5 -> 任务多三个可合并字段 parent / collapsed / color，并且每条记录
///         多一个 "kind":"task"|"group"（1.24 两级分组）。
///   /6 -> 任务多五个可合并字段 due / due_precision / remind_lead /
///         repeat_rule / series_id（1.31 时间系统）。
///   /7 -> 报文多三样东西（1.47 笔记同步）：
///         notes   每个笔记/附件一个 {path, hlc, sha, size}
///         noteDels 删除墓碑 {path, hlc}
///         want    只出现在监听方的回包里：「我需要这些路径的内容」
///         另有两种新帧：blobs（内容分块，每块 ≤ 1 MB）与 blobsDone。
///         旧版本收到带 notes 的报文会因为不认识这个键而拒绝，故必须升版本。
const String kProto = 'pnote-sync/7';
const String kTypeState = 'state';
const String kTypeAck = 'ack';
const String kTypeBlobs = 'blobs';
const String kTypeBlobsDone = 'blobsDone';

/// 单帧内容上限：局域网里 1 MB 一帧，既不会撞上 8 MB 的单帧限制，
/// 也不会因为一篇文章很大就整趟同步卡住。
const int kBlobChunkBytes = 1024 * 1024;

/// 一帧 state 里同时装着任务状态与笔记元信息。
class SyncEnvelope {
  const SyncEnvelope({
    required this.state,
    this.notes,
    this.want = const [],
  });

  final SyncState state;

  /// 对端的笔记元信息；对方版本太旧（没有这个键）时为 null。
  final NotesSyncState? notes;

  /// 对端希望本机发过去的路径（只有监听方的回包才有）。
  final List<String> want;
}

/// 把本地全量状态编码成一个 JSON 字符串。
///
/// [notes] 为 null 时退化成原来的任务报文（字节兼容旧格式，但版本号已是 /7，
/// 所以只有 /7 的对端才认得）。
String encodeState(
  SyncState state, {
  DateTime? sentAt,
  NotesSyncState? notes,
  List<String> want = const [],
}) {
  final now = sentAt ?? DateTime.now();
  final purgedIds = state.purged.keys.toList()..sort();
  final body = <String, Object?>{
    'proto': kProto,
    'type': kTypeState,
    'deviceId': state.deviceId,
    'deviceName': state.deviceName,
    'hlc': state.maxHlc?.toJson() ?? {'ms': 0, 'c': 0, 'dev': state.deviceId},
    'sentAt': now.millisecondsSinceEpoch,
    'tasks': [for (final t in state.tasks.values) t.toJson()],
    'purged': [
      for (final id in purgedIds)
        {'id': id, 'hlc': state.purged[id]!.toJson()},
    ],
    if (notes != null) 'notes': _encodeNoteMeta(notes),
    if (notes != null) 'noteDels': _encodeNoteDels(notes),
    if (notes != null) 'notePurges': _encodeNotePurges(notes),
    if (want.isNotEmpty) 'want': want,
  };
  return jsonEncode(body);
}

List<Map<String, Object?>> _encodeNoteMeta(NotesSyncState notes) => [
      for (final entry in notes.files.entries)
        {
          'path': entry.key,
          'hlc': entry.value.hlc.toJson(),
          'sha': entry.value.sha,
          'size': entry.value.size,
        },
    ];

List<Map<String, Object?>> _encodeNoteDels(NotesSyncState notes) => [
      for (final entry in notes.deleted.entries)
        {'path': entry.key, 'hlc': entry.value.toJson()},
    ];

/// 彻底删除记录：`{name, hlc}`。用文件名而不是路径 —— 回收站里的文件已经
/// 不在原路径上了，两端只共识「文件名」这把钥匙（见 notes_channel.dart）。
List<Map<String, Object?>> _encodeNotePurges(NotesSyncState notes) => [
      for (final entry in notes.purged.entries)
        {'name': entry.key, 'hlc': entry.value.toJson()},
    ];

/// 解析对端报文（任务 + 笔记元信息）。任何不符合约定的输入都抛
/// PayloadException，由上层翻译成「对方版本不兼容」或「数据损坏」。
SyncEnvelope decodeEnvelope(String raw) {
  final map = _decodeRoot(raw, kTypeState);
  final deviceId = map['deviceId'];
  if (deviceId is! String || deviceId.isEmpty) {
    throw const PayloadException('缺少 deviceId');
  }
  final deviceName = map['deviceName'];
  final tasksRaw = map['tasks'];
  if (tasksRaw is! List) throw const PayloadException('tasks 必须是数组');

  final purged = <String, Hlc>{};
  final purgedRaw = map['purged'];
  if (purgedRaw != null) {
    if (purgedRaw is! List) throw const PayloadException('purged 必须是数组');
    for (final item in purgedRaw) {
      if (item is! Map) {
        throw const PayloadException('purged 元素必须是 {id, hlc} 对象');
      }
      final entry = Map<String, Object?>.from(item);
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        throw const PayloadException('purged 元素的 id 必须是非空字符串');
      }
      purged[id] = _hlcOf(entry['hlc'], 'purged 元素');
    }
  }

  final tasks = <String, TaskState>{};
  for (final item in tasksRaw) {
    if (item is! Map) throw const PayloadException('tasks 元素必须是对象');
    final task = TaskState.fromJson(Map<String, Object?>.from(item));
    if (tasks.containsKey(task.id)) {
      throw PayloadException('任务 ID 重复：${task.id}');
    }
    tasks[task.id] = task;
  }

  NotesSyncState? notes;
  if (map.containsKey('notes') ||
      map.containsKey('noteDels') ||
      map.containsKey('notePurges')) {
    final files = <String, NoteVersion>{};
    final notesRaw = map['notes'];
    if (notesRaw is List) {
      for (final item in notesRaw) {
        if (item is! Map) {
          throw const PayloadException('notes 元素必须是对象');
        }
        final entry = Map<String, Object?>.from(item);
        final path = entry['path'];
        final sha = entry['sha'];
        final size = entry['size'];
        if (path is! String || path.isEmpty) {
          throw const PayloadException('notes 元素的 path 必须是非空字符串');
        }
        if (sha is! String || size is! int) {
          throw const PayloadException('notes 元素缺少 sha/size');
        }
        files[path] = NoteVersion(
          hlc: _hlcOf(entry['hlc'], 'notes 元素'),
          sha: sha,
          size: size,
        );
      }
    }
    final deleted = <String, Hlc>{};
    final delsRaw = map['noteDels'];
    if (delsRaw is List) {
      for (final item in delsRaw) {
        if (item is! Map) {
          throw const PayloadException('noteDels 元素必须是对象');
        }
        final entry = Map<String, Object?>.from(item);
        final path = entry['path'];
        if (path is! String || path.isEmpty) {
          throw const PayloadException('noteDels 元素的 path 必须是非空字符串');
        }
        deleted[path] = _hlcOf(entry['hlc'], 'noteDels 元素');
      }
    }
    final purges = <String, Hlc>{};
    final purgesRaw = map['notePurges'];
    if (purgesRaw is List) {
      for (final item in purgesRaw) {
        if (item is! Map) {
          throw const PayloadException('notePurges 元素必须是对象');
        }
        final entry = Map<String, Object?>.from(item);
        final name = entry['name'];
        if (name is! String || name.isEmpty) {
          throw const PayloadException('notePurges 元素的 name 必须是非空字符串');
        }
        purges[name] = _hlcOf(entry['hlc'], 'notePurges 元素');
      }
    }
    notes = NotesSyncState(files: files, deleted: deleted, purged: purges);
  }

  final want = <String>[];
  final wantRaw = map['want'];
  if (wantRaw is List) {
    for (final item in wantRaw) {
      if (item is String && item.isNotEmpty) want.add(item);
    }
  }

  return SyncEnvelope(
    state: SyncState(
      deviceId: deviceId,
      deviceName: deviceName is String ? deviceName : '未知设备',
      tasks: tasks,
      purged: purged,
    ),
    notes: notes,
    want: want,
  );
}

SyncState decodeState(String raw) => decodeEnvelope(raw).state;

/// 内容帧：一批文件（base64），一帧不超过 [kBlobChunkBytes] 左右。
String encodeBlobs(List<NoteBlob> blobs) {
  return jsonEncode(<String, Object?>{
    'proto': kProto,
    'type': kTypeBlobs,
    'entries': [
      for (final blob in blobs)
        {
          'path': blob.path,
          'hlc': blob.hlc.toJson(),
          'sha': blob.sha,
          'data': base64Encode(blob.bytes),
        },
    ],
  });
}

List<NoteBlob> decodeBlobs(String raw) {
  final map = _decodeRoot(raw, kTypeBlobs);
  final entries = map['entries'];
  if (entries is! List) throw const PayloadException('entries 必须是数组');
  final out = <NoteBlob>[];
  for (final item in entries) {
    if (item is! Map) throw const PayloadException('entries 元素必须是对象');
    final entry = Map<String, Object?>.from(item);
    final path = entry['path'];
    final sha = entry['sha'];
    final data = entry['data'];
    if (path is! String || path.isEmpty) {
      throw const PayloadException('内容帧的 path 必须是非空字符串');
    }
    if (sha is! String || data is! String) {
      throw const PayloadException('内容帧缺少 sha/data');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw PayloadException('内容帧的 data 不是合法 base64：$path');
    }
    out.add(NoteBlob(
      path: path,
      hlc: _hlcOf(entry['hlc'], '内容帧'),
      sha: sha,
      bytes: bytes,
    ));
  }
  return out;
}

/// 「我说完了，你需要什么」帧。
String encodeBlobsDone({List<String> want = const [], int skipped = 0}) {
  return jsonEncode(<String, Object?>{
    'proto': kProto,
    'type': kTypeBlobsDone,
    if (want.isNotEmpty) 'want': want,
    if (skipped > 0) 'skipped': skipped,
  });
}

class BlobsDone {
  const BlobsDone({this.want = const [], this.skipped = 0});
  final List<String> want;
  final int skipped;
}

BlobsDone decodeBlobsDone(String raw) {
  final map = _decodeRoot(raw, kTypeBlobsDone);
  final want = <String>[];
  final raw2 = map['want'];
  if (raw2 is List) {
    for (final item in raw2) {
      if (item is String && item.isNotEmpty) want.add(item);
    }
  }
  final skipped = map['skipped'];
  return BlobsDone(want: want, skipped: skipped is int ? skipped : 0);
}

/// 回执帧。
String encodeAck({required String deviceId, required bool ok, String? message}) {
  return jsonEncode(<String, Object?>{
    'proto': kProto,
    'type': kTypeAck,
    'deviceId': deviceId,
    'ok': ok,
    'message': ?message,
  });
}

/// 回执帧的内容。字段缺省时按「成功」处理（老版本可能不带 message）。
({bool ok, String? message}) decodeAck(String raw) {
  final root = _decodeRoot(raw, kTypeAck);
  final ok = root['ok'];
  final message = root['message'];
  return (ok: ok != false, message: message is String ? message : null);
}

/// 判断一帧的类型（不认识时返回 null），供多帧会话分发。
String? frameType(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final type = decoded['type'];
    return type is String ? type : null;
  } on FormatException {
    return null;
  }
}

Map<String, Object?> _decodeRoot(String raw, String expectType) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw PayloadException('不是合法 JSON（${e.message}）');
  }
  if (decoded is! Map) throw const PayloadException('顶层必须是对象');
  final map = Map<String, Object?>.from(decoded);

  final proto = map['proto'];
  if (proto != kProto) {
    throw PayloadException('协议版本不匹配（收到 ${proto ?? '空'}，期望 $kProto）');
  }
  final type = map['type'];
  if (type != expectType) {
    throw PayloadException('报文类型不是 $expectType（收到 ${type ?? '空'}）');
  }
  return map;
}

Hlc _hlcOf(Object? raw, String where) {
  if (raw is! Map) throw PayloadException('$where 缺少 hlc');
  try {
    return Hlc.fromJson(Map<String, Object?>.from(raw));
  } on FormatException catch (e) {
    throw PayloadException('$where 的 hlc 不合法（${e.message}）');
  }
}
