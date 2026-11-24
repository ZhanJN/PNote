/// 笔记文件层：扫描、读写、新建、改名、删除、素材导入（1.41）。
///
/// 三条硬规矩（见项目说明 8.12）：
///   1. 写盘永远「临时文件 + rename」，断电不会留下半个文件；
///   2. 删笔记只是移到 `.trash/`，不依赖数据库，也不需要回收站表；
///   3. 任何操作失败都抛 [NotesIoException]，界面必须如实显示，不许说"已保存"。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';

/// 组内顺序文件的文件名（放在库根，点开头所以不会被当成笔记）。
const String kOrderFileName = '.order.json';

/// 月分组键（`2026-11`）：列表按月分组，拖拽顺序按组记在 [kOrderFileName] 里。
String monthKeyOf(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}';

/// 文件操作失败时抛出，message 是能直接给用户看的短句。
class NotesIoException implements Exception {
  NotesIoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 笔记库的读写门面。无状态，可以随便 new。
class NotesStore {
  const NotesStore();

  // ---------------------------------------------------------------- 读

  /// 扫描整个库（跳过 `.trash`、`.assets` 和任何点目录）。
  Future<List<NoteFile>> list() async {
    final root = await notesRoot();
    final out = <NoteFile>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.md')) continue;
      final rel = p.relative(entity.path, from: root.path).replaceAll('\\', '/');
      if (rel.split('/').any((part) => part.startsWith('.'))) continue;
      final stat = await entity.stat();
      final name = p.basename(rel);
      out.add(NoteFile(
        relPath: rel,
        title: await _readTitle(entity, name),
        createdAt: parseStamp(name) ?? stat.modified,
        modified: stat.modified,
        size: stat.size,
      ));
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final order = await readOrder();
    if (order.isEmpty) return out;
    // 拖拽排出来的组内顺序优先；没进过顺序表的新笔记仍然排在本月最上面。
    final rank = <String, int>{};
    order.forEach((key, ids) {
      for (var i = 0; i < ids.length; i++) {
        rank['$key|${ids[i]}'] = i;
      }
    });
    out.sort((a, b) {
      final groupA = monthKeyOf(a.createdAt);
      final groupB = monthKeyOf(b.createdAt);
      if (groupA != groupB) return groupB.compareTo(groupA);
      final ra = rank['$groupA|${a.relPath}'];
      final rb = rank['$groupB|${b.relPath}'];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return 1;
      if (rb != null) return -1;
      return b.createdAt.compareTo(a.createdAt);
    });
    return out;
  }

  // ------------------------------------------------------------ 列表顺序

  /// 用户拖出来的组内顺序：`{"2026-11": ["2026/11/xxx.md", ...]}`。
  ///
  /// 存在库根的 [kOrderFileName]（点文件，扫描 .md 时会跳过）。读不到或者
  /// 内容坏了都只返回空表 —— 顺序坏了顶多回到「时间倒序」，绝不能让
  /// 笔记库打不开。
  Future<Map<String, List<String>>> readOrder() async {
    final root = await notesRoot();
    final file = File(p.join(root.path, kOrderFileName));
    if (!await file.exists()) return <String, List<String>>{};
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return <String, List<String>>{};
      final out = <String, List<String>>{};
      data.forEach((key, value) {
        if (key is String && value is List) {
          out[key] = [
            for (final item in value)
              if (item is String) item,
          ];
        }
      });
      return out;
    } catch (_) {
      return <String, List<String>>{};
    }
  }

  /// 记下某个分组（`2026-11`）的新顺序，其余分组原样保留。
  Future<void> writeOrder(String groupKey, List<String> ids) async {
    final root = await notesRoot();
    final order = await readOrder();
    order[groupKey] = List<String>.from(ids);
    final file = File(p.join(root.path, kOrderFileName));
    await file.parent.create(recursive: true);
    await _writeAtomic(
      file,
      const JsonEncoder.withIndent('  ').convert(order),
    );
  }

  // ---------------------------------------------------------------- 组

  /// 读笔记组清单（库根 [kGroupsFileName]）。
  ///
  /// 组 = 磁盘目录 + 这张清单的并集：目录里放着的 `.md` 自动归一级组，清单
  /// 里可以额外把一篇文章同时挂到好几个组。清单是本机偏好（不同步）。
  Future<NoteGroups> readGroups() async {
    final root = await notesRoot();
    return readGroupsSync(root);
  }

  /// 整张组表写回库根（原子替换）。
  Future<void> writeGroups(NoteGroups groups) async {
    final root = await notesRoot();
    final file = File(p.join(root.path, kGroupsFileName));
    await file.parent.create(recursive: true);
    await _writeAtomic(file, encodeGroups(groups));
  }

  /// 把一篇笔记加进组（多组归属，物理文件不动）。
  Future<void> addToGroup(String group, String relPath) async {
    final name = group.trim();
    if (name.isEmpty) return;
    final groups = await readGroups();
    final next = <String, List<String>>{
      for (final key in groups.names) key: List<String>.of(groups.byGroup[key]!),
    };
    final bucket = next[name] ??= <String>[];
    final path = relPath.replaceAll('\\', '/');
    if (!bucket.contains(path)) {
      bucket.add(path);
      bucket.sort();
    }
    await writeGroups(NoteGroups(next));
  }

  /// 把一篇笔记从某个组里移出（文件不动）。
  Future<void> removeFromGroup(String group, String relPath) async {
    final groups = await readGroups();
    if (!groups.byGroup.containsKey(group)) return;
    final next = <String, List<String>>{
      for (final key in groups.names) key: List<String>.of(groups.byGroup[key]!),
    };
    next[group]!.removeWhere((item) => item == relPath.replaceAll('\\', '/'));
    if (next[group]!.isEmpty) next.remove(group);
    await writeGroups(NoteGroups(next));
  }

  Future<String> read(String relPath) async {
    final file = await noteFileFor(relPath);
    try {
      return await file.readAsString();
    } on FileSystemException catch (e) {
      throw NotesIoException('读不到这篇笔记：${e.osError?.message ?? e.message}');
    }
  }

  // ---------------------------------------------------------------- 写

  /// 原子写入：先写 `<名字>.tmp`，再 rename 覆盖原文件。
  Future<void> write(String relPath, String content) async {
    final file = await noteFileFor(relPath);
    await file.parent.create(recursive: true);
    await _writeAtomic(file, content);
  }

  /// 新建一篇笔记，文件名 = `创建时间 + 标题`，按 年/月 归档。
  Future<NoteFile> create(String title) async {
    final now = DateTime.now();
    final clean = _safeStem(title);
    final folder = '${now.year}/${_two(now.month)}';
    var stem = '${_stamp(now)} $clean';
    var rel = '$folder/$stem.md';
    for (var i = 2; await _exists(rel); i++) {
      rel = '$folder/$stem -$i.md';
    }
    final heading = clean.isEmpty ? '未命名笔记' : clean;
    await write(rel, '# $heading\n\n');
    return NoteFile(
      relPath: rel,
      title: heading,
      createdAt: now,
      modified: now,
      size: utf8.encode('# $heading\n\n').length,
    );
  }

  /// 重命名「文件」（不是改标题行）：同时改 `.assets` 目录名，并把全库
  /// 指向它的 `[[旧名]]` 一起改掉。返回改完之后的笔记。
  Future<NoteFile> renameFile(NoteFile note, String newTitle) async {
    final stem = _safeStem(newTitle);
    if (stem.isEmpty) throw NotesIoException('文件名不能为空');
    final folder = p.dirname(note.relPath).replaceAll('\\', '/');
    final oldStem = _stemOf(note.relPath);
    if (stem == oldStem) return note;
    final stamp = _stamp(note.createdAt);
    final newRel = '$folder/$stamp $stem.md';
    if (await _exists(newRel)) {
      throw NotesIoException('这个文件名已经存在：$stamp $stem.md');
    }
    final root = await notesRoot();
    final from = File(p.join(root.path, note.relPath));
    final to = File(p.join(root.path, newRel));
    try {
      await from.rename(to.path);
      final oldAssets = Directory(p.join(root.path, note.assetsRelPath));
      if (await oldAssets.exists()) {
        await oldAssets.rename(p.join(root.path, '$folder/$stamp $stem.assets'));
      }
    } on FileSystemException catch (e) {
      throw NotesIoException('改名失败：${e.osError?.message ?? e.message}');
    }
    await _syncHeadingToStem(to, oldStem, stem);
    await _rewriteReferences(oldStem, stem);
    final stat = await to.stat();
    return note.copyWith(relPath: newRel, modified: stat.modified, size: stat.size);
  }

  /// 改文件里的标题行（`# 标题`），不动文件名。
  Future<void> setHeading(NoteFile note, String heading) async {
    final text = await read(note.relPath);
    final lines = text.split('\n');
    final value = heading.trim().isEmpty ? '未命名笔记' : heading.trim();
    if (lines.isNotEmpty && lines.first.trimLeft().startsWith('# ')) {
      lines[0] = '# $value';
    } else {
      lines.insert(0, '# $value');
      lines.insert(1, '');
    }
    await write(note.relPath, lines.join('\n'));
  }

  // ---------------------------------------------------------------- 删

  /// 移到 `.trash/<时间>/`，素材目录一起走。
  Future<void> delete(NoteFile note) async {
    final root = await notesRoot();
    final trash = await trashRoot();
    final now = DateTime.now();
    var bucket = Directory(p.join(trash.path, _stamp(now)));
    for (var i = 2; await bucket.exists(); i++) {
      bucket = Directory(p.join(trash.path, '${_stamp(now)} -$i'));
    }
    try {
      await bucket.create(recursive: true);
      final src = File(p.join(root.path, note.relPath));
      await src.rename(p.join(bucket.path, p.basename(note.relPath)));
      final assets = Directory(p.join(root.path, note.assetsRelPath));
      if (await assets.exists()) {
        await assets.rename(p.join(bucket.path, p.basename(note.assetsRelPath)));
      }
    } on FileSystemException catch (e) {
      throw NotesIoException('删除失败：${e.osError?.message ?? e.message}');
    }
  }

  Future<List<TrashEntry>> listTrash() async {
    final trash = await trashRoot();
    final out = <TrashEntry>[];
    await for (final entity in trash.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.md')) continue;
      final rel = p.relative(entity.path, from: trash.path).replaceAll('\\', '/');
      final stat = await entity.stat();
      out.add(TrashEntry(
        relPath: rel,
        movedAt: stat.modified,
        title: await _readTitle(entity, p.basename(rel)),
      ));
    }
    out.sort((a, b) => b.movedAt.compareTo(a.movedAt));
    return out;
  }

  /// 从回收目录恢复一篇笔记（1.45）。
  ///
  /// 落回它本来该在的年/月文件夹（从文件名里的时间戳推），素材目录一起回来；
  /// 同名文件已存在时加「 (2)」。找不到文件时抛 [NotesIoException]。
  Future<NoteFile> restoreTrash(TrashEntry entry) async {
    final root = await notesRoot();
    final trash = await trashRoot();
    final src = File(p.join(trash.path, entry.relPath));
    if (!await src.exists()) {
      throw NotesIoException('回收站里找不到这个文件了：${p.basename(entry.relPath)}');
    }
    final base = p.basename(entry.relPath);
    final stem = base.toLowerCase().endsWith('.md')
        ? base.substring(0, base.length - 3)
        : base;
    final created = parseStamp(base) ?? entry.movedAt;
    final folder = Directory(
      p.join(root.path, '${created.year}', _two(created.month)),
    );
    try {
      await folder.create(recursive: true);
      var name = stem;
      for (var i = 2; await File(p.join(folder.path, '$name.md')).exists(); i++) {
        name = '$stem ($i)';
      }
      final target = p.join(folder.path, '$name.md');
      await src.rename(target);
      // 素材目录就在这篇 .md 旁边（同一个 `.trash/<时间戳>/` 桶里），
      // 名字是「去掉 .md 的路径 + .assets」（NoteFile.assetsRelPath），
      // 不是「文件名 + .assets」——1.45 恢复时写错过一次，这里锁死。
      final assets = Directory(p.join(src.parent.path, '$stem.assets'));
      if (await assets.exists()) {
        await assets.rename(p.join(folder.path, '$name.assets'));
      }
      await _dropEmptyTrashBucket(src.parent);
      final stat = await File(target).stat();
      return NoteFile(
        relPath: p
            .relative(target, from: root.path)
            .replaceAll('\\', '/'),
        title: await _readTitle(File(target), '$name.md'),
        createdAt: created,
        modified: stat.modified,
        size: stat.size,
      );
    } on FileSystemException catch (e) {
      throw NotesIoException('恢复失败：${e.osError?.message ?? e.message}');
    }
  }

  /// 从回收目录彻底删除若干篇笔记（连同素材目录），返回删掉的笔记数。
  Future<int> purgeTrash(Iterable<TrashEntry> entries) async {
    final trash = await trashRoot();
    var count = 0;
    final purgedNames = <String>[];
    for (final entry in entries) {
      final file = File(p.join(trash.path, entry.relPath));
      final name = p.basename(entry.relPath);
      final assetsRel = name.toLowerCase().endsWith('.md')
          ? '${name.substring(0, name.length - 3)}.assets'
          : '$name.assets';
      try {
        if (await file.exists()) {
          await file.delete();
          count++;
          purgedNames.add(name);
        }
        final assets = Directory(p.join(file.parent.path, assetsRel));
        if (await assets.exists()) await assets.delete(recursive: true);
        await _dropEmptyTrashBucket(file.parent);
      } on FileSystemException catch (e) {
        throw NotesIoException('删除失败：${e.osError?.message ?? e.message}');
      }
    }
    if (purgedNames.isNotEmpty) await _queuePurge(purgedNames);
    return count;
  }

  /// 某一批从回收站挪走东西之后，把空掉的那层文件夹一起收掉。
  Future<void> _dropEmptyTrashBucket(Directory bucket) async {
    try {
      if (!await bucket.exists()) return;
      if (await bucket.list(followLinks: false).isEmpty) {
        await bucket.delete();
      }
    } on FileSystemException {
      // 收不掉只是留下一个空文件夹，不影响用户操作。
    }
  }

  /// 清空回收目录，返回删掉的笔记数。
  Future<int> emptyTrash() async {
    final trash = await trashRoot();
    var count = 0;
    final names = <String>[];
    await for (final entity in trash.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
        count++;
        names.add(p.basename(entity.path));
      }
    }
    await trash.delete(recursive: true);
    await trash.create(recursive: true);
    if (names.isNotEmpty) await _queuePurge(names);
    return count;
  }

  /// 把「刚彻底删掉的文件名」记进同步用的暂存清单（1.49）。
  ///
  /// 只写文件名、不带版本号：版本要由 HLC 时钟来盖，那是同步层的事
  /// （见 notes_sync.dart 的 kPurgeQueueFileName 与 scan）。
  Future<void> _queuePurge(List<String> names) async {
    try {
      final root = await notesRoot();
      final file = File(p.join(root.path, kPurgeQueueFileName));
      final pending = <String>{};
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final item in raw) {
            if (item is String && item.isNotEmpty) pending.add(item);
          }
        }
      }
      pending.addAll(names);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(pending.toList()..sort()), flush: true);
      await tmp.rename(file.path);
    } on Object {
      // 暂存失败不能影响「删除」本身：下次同步最多是这台设备的删除没传出去。
    }
  }

  // ---------------------------------------------------------------- 素材

  /// 把一个外部文件复制进 `<笔记>.assets/`，返回放进库里的文件名。
  Future<String> importAsset(NoteFile note, File source) async {
    final dir = await noteAssetsFor(note.id);
    final name = _uniqueAssetName(dir, p.basename(source.path));
    try {
      await source.copy(p.join(dir.path, name));
    } on FileSystemException catch (e) {
      throw NotesIoException('复制素材失败：${e.osError?.message ?? e.message}');
    }
    return name;
  }

  /// 素材文件（不存在返回 null）。
  Future<File?> assetFile(String noteId, String name) async {
    final root = await notesRoot();
    final file = File(p.join(root.path, '$noteId.assets', name));
    return await file.exists() ? file : null;
  }

  /// 一篇笔记的素材表：文件名 → 文件。目录不存在时返回空表（不会顺手创建）。
  Future<Map<String, File>> assetsOf(String noteId) async {
    final root = await notesRoot();
    final dir = Directory(p.join(root.path, '$noteId.assets'));
    if (!await dir.exists()) return <String, File>{};
    final out = <String, File>{};
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) out[p.basename(entity.path)] = entity;
    }
    return out;
  }

  // ---------------------------------------------------------------- 内部

  Future<void> _writeAtomic(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(file.path);
    } on FileSystemException catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件删不掉不影响向用户报错，忽略。
      }
      throw NotesIoException('保存失败：${e.osError?.message ?? e.message}');
    }
  }

  Future<bool> _exists(String relPath) async {
    final file = await noteFileFor(relPath);
    return file.exists();
  }

  /// 改名后把正文第一行 `# 标题` 一起改掉（1.42）。
  ///
  /// 列表里显示的是标题行，不是文件名——只改文件名会出现「改了名但列表没变化」
  /// （用户 1.42 反馈）。仅当标题行正好等于旧名时才改，避免覆盖用户自己写的
  /// 大标题。
  Future<void> _syncHeadingToStem(File file, String oldStem, String newStem) async {
    String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      return;
    }
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.startsWith('# ')) return;
      if (trimmed.substring(2).trim() != oldStem) return;
      lines[i] = '# $newStem';
      try {
        await _writeAtomic(file, lines.join('\n'));
      } on NotesIoException {
        // 标题行没改成，文件已经改好名了：不把整次改名判失败。
      }
      return;
    }
  }

  Future<int> _rewriteReferences(String oldStem, String newStem) async {
    final root = await notesRoot();
    var changed = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.md')) continue;
      final rel = p.relative(entity.path, from: root.path).replaceAll('\\', '/');
      if (rel.split('/').any((part) => part.startsWith('.'))) continue;
      try {
        final text = await entity.readAsString();
        if (!text.contains('[[$oldStem')) continue;
        final next = text.replaceAll('[[$oldStem', '[[$newStem');
        await _writeAtomic(entity, next);
        changed++;
      } on FileSystemException {
        // 单篇读不了就跳过，不阻塞改名。
      }
    }
    return changed;
  }

  Future<String> _readTitle(File file, String fileName) async {
    String text;
    try {
      final raf = await file.open();
      try {
        final length = math.min(await raf.length(), 8192);
        text = utf8.decode(await raf.read(length), allowMalformed: true);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return titleFromFileName(fileName);
    }
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('# ')) return trimmed.substring(2).trim();
      break; // 标题只认文件最前面那段
    }
    return titleFromFileName(fileName);
  }

  String _uniqueAssetName(Directory dir, String rawName) {
    final base = _safeAssetName(rawName);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    var name = base;
    for (var i = 2; File(p.join(dir.path, name)).existsSync(); i++) {
      name = '$stem ($i)$ext';
    }
    return name;
  }
}

// ------------------------------------------------------------------ 纯函数

final RegExp _stampPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})');

/// 从文件名解析创建时间：`2026-11-23 2041 白板复盘.md` → 2026-11-23 20:41。
DateTime? parseStamp(String fileName) {
  final m = _stampPattern.firstMatch(fileName);
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
  );
}

/// 文件名去掉 `.md` 与时间前缀后的部分，也就是 `[[链接]]` 里写的名字。
String titleFromFileName(String fileName) {
  var name = fileName;
  if (name.toLowerCase().endsWith('.md')) {
    name = name.substring(0, name.length - 3);
  }
  final m = _stampPattern.firstMatch(name);
  if (m != null) name = name.substring(m.end).trim();
  return name.isEmpty ? '未命名笔记' : name;
}

/// 库内 id（去掉 `.md`）→ 链接里用的名字。
String linkStemOf(String relPath) => titleFromFileName(p.basename(relPath));

/// `[[链接]]` 用的名字：文件名去掉 `.md` 与时间前缀（`2026-11-23 2041 白板复盘.md`
/// → `白板复盘`）。改名时用它做旧名/新名的比较，不能带时间前缀。
String _stemOf(String relPath) => titleFromFileName(p.basename(relPath));

/// 清掉 Windows / Android 都不允许出现在文件名里的字符。
String _safeStem(String raw) {
  var name = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length > 40) name = name.substring(0, 40).trim();
  return name;
}

/// 素材文件名只清掉真正的路径分隔符和非法字符，保留原后缀。
String _safeAssetName(String raw) {
  final name = p.basename(raw).replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  final trimmed = name.trim();
  return trimmed.isEmpty ? '未命名素材' : trimmed;
}

String _two(int value) => value.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}${_two(t.minute)}';
