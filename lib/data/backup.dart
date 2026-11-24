/// 导出 / 导入备份。
///
/// 备份文件就是一份「和同步报文几乎一样的 JSON」：
///   `{"proto":"pnote-bundle/1","exportedAt":毫秒,"deviceId":..,"deviceName":..,`
///   `"tasks":[...],"purged":[...]}`
/// 里面包含**墓碑**（deleted_at）与**永久删除记录**（purged），
/// 所以导入之后两台设备的状态和导出时完全一致，而不是只恢复「看得见的任务」。
///
/// 为什么格式复用同步报文：格式只有一份，校验只有一份，测试也只有一份。
/// 导入不走「覆盖」，走的是和同步完全相同的合并算法 —— 幂等、可重复导入、
/// 不怕导入一个旧备份把新数据冲掉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:pnote/sync/payload.dart';
import 'package:pnote/data/models.dart';

/// 备份文件的协议号。和同步报文分开，避免把备份文件误当成网络报文。
const String kBundleProto = 'pnote-bundle/1';

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 备份文件里允许出现的类型过滤器。
const XTypeGroup _jsonTypeGroup = XTypeGroup(
  label: 'JSON 备份',
  extensions: <String>['json'],
  mimeTypes: <String>['application/json'],
);

/// 建议的文件名，带时间戳，避免覆盖上一次的备份。
String suggestedBackupName({DateTime? now}) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'pnote-backup-${t.year}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
}

/// 把状态编码成备份文件内容。
String encodeBundle(SyncState state, {DateTime? exportedAt}) {
  final t = exportedAt ?? DateTime.now();
  final purgedIds = state.purged.keys.toList()..sort();
  return jsonEncode(<String, Object?>{
    'proto': kBundleProto,
    'exportedAt': t.millisecondsSinceEpoch,
    'deviceId': state.deviceId,
    'deviceName': state.deviceName,
    'tasks': [for (final task in state.tasks.values) task.toJson()],
    'purged': [
      for (final id in purgedIds)
        {'id': id, 'hlc': state.purged[id]!.toJson()},
    ],
  });
}

/// 解析备份文件内容。所有结构校验复用 [decodeState]，两条路径不会跑偏。
SyncState decodeBundle(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw BackupException('这个文件不是合法的 JSON（${e.message}）');
  }
  if (decoded is! Map) throw const BackupException('备份文件的最外层应该是一个对象');
  final map = Map<String, Object?>.from(decoded);
  final proto = map['proto'];
  if (proto != kBundleProto) {
    throw BackupException('这不是 PNote 的备份文件（协议是 ${proto ?? '空'}）');
  }
  // 把 proto/type 换成同步报文的样子，剩下的校验完全交给 decodeState。
  final normalised = jsonEncode(<String, Object?>{
    ...map,
    'proto': kProto,
    'type': kTypeState,
  });
  try {
    return decodeState(normalised);
  } on PayloadException catch (e) {
    throw BackupException('备份内容不合法：${e.message}');
  }
}

/// 导出到用户选的位置。返回保存到的路径；用户取消则返回 null。
///
/// 平台差异（已核实 file_selector 1.1.0 的能力表）：
///   Windows —— 有「保存位置」对话框，可以自己挑目录。
///   Android —— **没有**保存对话框，只能写到应用自己的外部目录，
///              路径由系统决定；界面上把路径显示出来，方便用文件管理器找到。
Future<String?> saveBundleToFile(String json, {String? fileName}) async {
  final name = fileName ?? suggestedBackupName();

  if (!Platform.isAndroid && !Platform.isIOS) {
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [_jsonTypeGroup],
    );
    if (location == null) return null;
    final file = File(location.path);
    await file.writeAsString(json, flush: true);
    return file.path;
  }

  final dir = await _androidExportDir();
  final file = File(p.join(dir.path, name));
  await file.writeAsString(json, flush: true);
  return file.path;
}

/// Android：优先写应用的外部存储目录（`Android/data/<包名>/files/…`），
/// 这个目录不占用户空间配额、能被部分文件管理器直接看到。
Future<Directory> _androidExportDir() async {
  Directory base;
  try {
    base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  } on Exception {
    base = await getApplicationDocumentsDirectory();
  }
  final dir = Directory(p.join(base.path, 'PNote 备份'));
  await dir.create(recursive: true);
  return dir;
}

/// 让用户挑一个备份文件并读出来。取消则返回 null。
Future<SyncState?> pickAndReadBundle() async {
  XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: const [_jsonTypeGroup]);
  } on ArgumentError {
    // 某些平台不接受 mimeTypes，退化为不过滤。
    file = await openFile();
  }
  if (file == null) return null;
  final text = await file.readAsString();
  return decodeBundle(text);
}
