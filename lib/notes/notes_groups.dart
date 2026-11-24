/// 笔记「组」= 纯文件夹思路 + 多组归属（1.48）。
///
/// 两条来源同时存在，最后合并成一张「组 → 笔记」的表：
///
/// 1. **磁盘目录**：笔记库根下的普通目录就是组（层数不限）。目录里放着的
///    `.md` 自动属于这个一级组。`年` 这种四位数字目录是「时间目录」，
///    不算组（`.trash`、`*.assets`、点开头的内部目录也不算出组）。
/// 2. **清单**：库根的 `.groups.json`，记「组名 → 笔记相对路径」，所以同一篇
///    笔记可以同时出现在好几个组里（文件还是那一份，改了到处都变）。
///
/// 组名允许带 `/` 表示嵌套（`工作/项目A`）；界面上的标签只用一级组名。
/// 清单是**本机**的（不进同步），删掉它不会动任何笔记文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_model.dart';

/// 存在笔记库根的组清单文件名。
const String kGroupsFileName = '.groups.json';

/// 组 → 笔记相对路径（`2026/11/x.md`）的只读快照。
class NoteGroups {
  const NoteGroups(this.byGroup);

  const NoteGroups.empty() : byGroup = const <String, List<String>>{};

  final Map<String, List<String>> byGroup;

  /// 全部组名（含嵌套），按名字排序。
  List<String> get names {
    final list = byGroup.keys.toList()..sort();
    return list;
  }

  /// 一级组名（`工作/项目A` → `工作`），去重且排序。
  List<String> get topNames {
    final set = <String>{};
    for (final name in byGroup.keys) {
      final top = topOf(name);
      if (top.isNotEmpty) set.add(top);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// 这个一级组下（含所有子组）的笔记路径集合。
  Set<String> notesUnder(String top) {
    final out = <String>{};
    for (final entry in byGroup.entries) {
      if (topOf(entry.key) != top) continue;
      out.addAll(entry.value);
    }
    return out;
  }

  /// 一篇笔记属于哪些组。
  List<String> groupsOf(String relPath) {
    final out = <String>[];
    for (final entry in byGroup.entries) {
      if (entry.value.contains(relPath)) out.add(entry.key);
    }
    out.sort();
    return out;
  }

  NoteGroups copyWith(Map<String, List<String>> next) => NoteGroups(next);
}

/// 取组名的一级段（`工作/项目A` → `工作`；无 `/` 时返回自身）。
String topOf(String group) {
  final i = group.indexOf('/');
  return i < 0 ? group : group.substring(0, i);
}

/// 相对路径里的一级目录名（`2026/11/x.md` → `2026`）。
String? topDirOf(String relPath) {
  final norm = relPath.replaceAll('\\', '/');
  final i = norm.indexOf('/');
  if (i <= 0) return null;
  return norm.substring(0, i);
}

/// 四位数字目录 = 时间目录（`2026`），不算组。
bool isYearDir(String name) => RegExp(r'^\d{4}$').hasMatch(name);

/// 内部目录 / 文件：不出现在组标签里。
bool isInternalName(String name) {
  if (name.isEmpty) return true;
  if (name.startsWith('.')) return true;
  if (name.endsWith('.assets')) return true;
  return false;
}

/// 从清单 JSON 文本解析；坏掉就当「没有清单」，绝不让笔记库打不开。
NoteGroups parseGroups(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const NoteGroups.empty();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const NoteGroups.empty();
    final out = <String, List<String>>{};
    decoded.forEach((key, value) {
      if (key is! String || value is! List) return;
      final name = key.trim();
      if (name.isEmpty) return;
      final paths = <String>{
        for (final item in value)
          if (item is String && item.trim().isNotEmpty)
            item.trim().replaceAll('\\', '/'),
      }.toList()..sort();
      if (paths.isNotEmpty) out[name] = paths;
    });
    return NoteGroups(out);
  } catch (_) {
    return const NoteGroups.empty();
  }
}

/// 序列化成便于人看的 JSON。
String encodeGroups(NoteGroups groups) {
  final sorted = <String, List<String>>{};
  for (final name in groups.names) {
    final paths = List<String>.of(groups.byGroup[name]!)..sort();
    sorted[name] = paths;
  }
  return const JsonEncoder.withIndent('  ').convert(sorted);
}

/// 读库根清单（文件不存在 / 坏掉 → 空）。
NoteGroups readGroupsSync(Directory root) {
  final file = File(p.join(root.path, kGroupsFileName));
  if (!file.existsSync()) return const NoteGroups.empty();
  try {
    return parseGroups(file.readAsStringSync());
  } catch (_) {
    return const NoteGroups.empty();
  }
}

/// 把磁盘上的普通目录并进组表（与清单同名的一级组做并集）。
///
/// `notes` 传 `store.list()` 的结果即可：目录里的笔记按一级目录名归组。
NoteGroups mergePhysical(
    Directory root, NoteGroups manifest, List<NoteFile> notes) {
  final out = <String, List<String>>{
    for (final name in manifest.names)
      name: List<String>.of(manifest.byGroup[name]!),
  };
  final dirs = <String>{};
  try {
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (isInternalName(name) || isYearDir(name)) continue;
      dirs.add(name);
    }
  } catch (_) {
    // 目录读不到就只用清单，不影响页面。
  }
  for (final name in dirs) {
    final bucket = out[name] ??= <String>[];
    for (final note in notes) {
      if (topDirOf(note.relPath) != name) continue;
      if (!bucket.contains(note.relPath)) bucket.add(note.relPath);
    }
    bucket.sort();
  }
  return NoteGroups(out);
}
