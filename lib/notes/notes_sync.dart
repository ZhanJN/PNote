/// 笔记同步的「文件那一侧」：扫库打版本、读字节、落远端改动。
///
/// 设计取舍（写进《PNote项目说明》8.12 与 ADR-044/045）：
///   - 版本是**按文件**记的，存在库根的 `.sync.json` 里；笔记本身仍然是
///     干净的 Markdown，不带任何同步标记 —— 拷走整库，别的编辑器照样能开。
///   - 版本用 HLC（和任务共用同一个时钟，存在 meta 表里），不用文件修改时间：
///     墙钟可以被用户改、两台机器会漂移，拿它判先后会出现「昨天的覆盖今天」。
///   - 判断「内容有没有变」用内容指纹（FNV-1a 64），不看时间：只要字节没变，
///     版本就不动，同步时也不会重复发送。
///   - 冲突按用户 2026-11-24 的选择处理：**后改的覆盖先改的**（版本大者胜）。
///     若两边都改过，输的那份不会留副本 —— 这是用户明确要的简单行为。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/notes_channel.dart';
import 'package:pnote/notes/notes_paths.dart';

/// 同步元信息文件名（库根下）。带点开头，扫库时会被跳过。
const String kSyncStateFileName = '.sync.json';

/// 单个文件的大小上限：超过就不同步（防止一个视频把整次同步拖死）。
// 1.56：附件单文件上限从 4 MB 提到 32 MB —— 手机拍的照片常常 5–15 MB，
// 以前会被静默跳过，用户看到的就是「图片没同步过去」。报文本身按 1 MB
// 分帧（kBlobChunkBytes），所以放大上限不会撑爆单帧。
const int kMaxSyncFileBytes = 32 * 1024 * 1024;

/// 内容指纹：FNV-1a 64 位，转成 16 位十六进制。
///
/// 不用 sha256 是为了不引入 crypto 依赖；这里只需要「变了没有」，
/// 不需要抗碰撞强度的密码学保证。
String fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b & 0xff;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class NotesSync {
  NotesSync({
    required this.clock,
    required this.persistClock,
    this.rootOf,
  });

  final HlcClock clock;

  /// 笔记库根的取法；默认用 notesRoot()。测试里注入两个临时库，
  /// 好让「两台设备」在同一个进程里互相同步。
  final Future<Directory> Function()? rootOf;

  /// 推进过时钟之后要写回数据库（能跟任务共用同一个 meta 键）。
  final Future<void> Function() persistClock;

  Future<Directory> _root() async => rootOf?.call() ?? notesRoot();

  Future<File> _stateFile() async {
    final root = await _root();
    return File(p.join(root.path, kSyncStateFileName));
  }

  /// 读元信息；文件不存在、坏掉、类型不对都返回空状态（绝不让同步崩掉）。
  Future<NotesSyncState> readState() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) return const NotesSyncState();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return const NotesSyncState();
      final map = Map<String, Object?>.from(raw);

      final files = <String, NoteVersion>{};
      final filesRaw = map['files'];
      if (filesRaw is Map) {
        for (final entry in filesRaw.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || value is! Map) continue;
          try {
            files[key] = NoteVersion.fromJson(Map<String, Object?>.from(value));
          } on FormatException {
            continue;
          }
        }
      }

      final deleted = <String, Hlc>{};
      final deletedRaw = map['deleted'];
      if (deletedRaw is Map) {
        for (final entry in deletedRaw.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || value is! Map) continue;
          try {
            deleted[key] = Hlc.fromJson(Map<String, Object?>.from(value));
          } on FormatException {
            continue;
          }
        }
      }

      final purged = <String, Hlc>{};
      final purgedRaw = map['purged'];
      if (purgedRaw is Map) {
        for (final entry in purgedRaw.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || value is! Map) continue;
          try {
            purged[key] = Hlc.fromJson(Map<String, Object?>.from(value));
          } on FormatException {
            continue;
          }
        }
      }
      return NotesSyncState(files: files, deleted: deleted, purged: purged);
    } on Object {
      return const NotesSyncState();
    }
  }

  Future<void> _writeState(NotesSyncState state) async {
    final file = await _stateFile();
    final body = <String, Object?>{
      'files': {
        for (final entry in state.files.entries) entry.key: entry.value.toJson(),
      },
      'deleted': {
        for (final entry in state.deleted.entries) entry.key: entry.value.toJson(),
      },
      'purged': {
        for (final entry in state.purged.entries) entry.key: entry.value.toJson(),
      },
    };
    final text = const JsonEncoder.withIndent('  ').convert(body);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }

  /// 扫一遍库：内容变了的文件打一个新版本，删掉的文件留一条墓碑。
  ///
  /// 这是同步的「准备动作」：先让磁盘现状和元信息对齐，之后报文的比较才有意义。
  Future<NotesSyncState> scan() async {
    final root = await _root();
    final previous = await readState();
    final nextFiles = <String, NoteVersion>{};
    final present = <String>{};
    var ticked = false;

    for (final file in _walk(root)) {
      final rel = _relPath(root, file);
      present.add(rel);
      final bytes = await file.readAsBytes();
      final sha = fnv1a64(bytes);
      final old = previous.files[rel];
      if (old != null && old.sha == sha) {
        nextFiles[rel] = old;
        continue;
      }
      nextFiles[rel] = NoteVersion(
        hlc: clock.send(),
        sha: sha,
        size: bytes.length,
      );
      ticked = true;
    }

    final nextDeleted = <String, Hlc>{...previous.deleted};
    for (final entry in previous.files.entries) {
      if (present.contains(entry.key)) continue;
      // 曾经同步过、现在磁盘上没了 → 是本地删除，留墓碑把删除传出去。
      nextDeleted[entry.key] = clock.send();
      ticked = true;
    }
    for (final entry in nextFiles.entries) {
      nextDeleted.remove(entry.key);
    }

    // 「彻底删除」的暂存：给每个文件名盖一个版本，写成 purged 记录（1.49）。
    final nextPurged = <String, Hlc>{...previous.purged};
    final queued = await _takePurgeQueue(root);
    for (final name in queued) {
      nextPurged[name] = clock.send();
      nextDeleted.removeWhere((rel, _) => _nameOf(rel) == name);
      nextFiles.removeWhere((rel, _) => _nameOf(rel) == name);
      ticked = true;
    }
    // 同名的文件又出现（比如从备份里救回来）→ 撤销彻底的删除记录。
    for (final rel in present) {
      nextPurged.remove(_nameOf(rel));
    }

    final state = NotesSyncState(
      files: nextFiles,
      deleted: nextDeleted,
      purged: nextPurged,
    );
    await _writeState(state);
    if (ticked) await persistClock();
    return state;
  }

  /// 读若干路径的字节，用于发给对端。
  ///
  /// 超过上限或读不到的文件直接跳过（跳过数量由调用方统计）；
  /// 这里不抛异常，免得一个权限问题毁掉整趟同步。
  Future<List<NoteBlob>> readBlobs(List<String> paths) async {
    final root = await _root();
    final state = await readState();
    final out = <NoteBlob>[];
    for (final rel in paths) {
      final version = state.files[rel];
      if (version == null) continue;
      if (version.size > kMaxSyncFileBytes) continue;
      final file = File(_absPath(root, rel));
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      if (bytes.length > kMaxSyncFileBytes) continue;
      out.add(NoteBlob(
        path: rel,
        hlc: version.hlc,
        sha: fnv1a64(bytes),
        bytes: bytes,
      ));
    }
    return out;
  }

  /// 落对端的删除与内容。规则：版本大者胜；本机更新的不动。
  Future<NotesApplyReport> apply(
    NotesSyncState remote,
    List<NoteBlob> blobs,
  ) async {
    final root = await _root();
    final local = await readState();
    final maxRemote = remote.maxHlc;
    var received = false;
    if (maxRemote != null) {
      clock.receive(maxRemote);
      received = true;
    }

    final files = <String, NoteVersion>{...local.files};
    final deleted = <String, Hlc>{...local.deleted};
    final purged = <String, Hlc>{...local.purged};
    var deletedCount = 0;
    var purgedCount = 0;
    var written = 0;
    var skippedOld = 0;

    // 0. 彻底删除：对端清空过回收站，同名的那篇连正文、素材、回收站副本一起抹掉。
    for (final entry in remote.purged.entries) {
      final name = entry.key;
      final stamp = entry.value;
      final mine = purged[name];
      if (mine != null && !(stamp > mine)) continue;
      purgedCount += await _eraseByName(root, name);
      files.removeWhere((rel, _) => _nameOf(rel) == name);
      deleted.removeWhere((rel, _) => _nameOf(rel) == name);
      purged[name] = stamp;
    }

    // 1. 删除：远端墓碑比本机版本新才真的删，且只挪进 .trash，能人工找回。
    for (final entry in remote.deleted.entries) {
      final rel = entry.key;
      final tomb = entry.value;
      if (purged[_nameOf(rel)] != null) continue; // 已经彻底删了，别再进回收站
      final mine = files[rel];
      if (mine != null && !(tomb > mine.hlc)) continue;
      final existingTomb = deleted[rel];
      if (existingTomb != null && existingTomb > tomb) continue;
      final abs = File(_absPath(root, rel));
      if (await abs.exists()) {
        await _moveToTrash(root, rel, abs);
        deletedCount++;
      }
      files.remove(rel);
      deleted[rel] = tomb;
    }

    // 2. 内容：远端版本更大就覆盖本地。
    for (final blob in blobs) {
      if (purged[_nameOf(blob.path)] != null) continue; // 别把删掉的拉回来
      final mine = files[blob.path];
      if (mine != null && mine.hlc > blob.hlc) {
        skippedOld++;
        continue;
      }
      if (mine != null && mine.hlc == blob.hlc && mine.sha == blob.sha) {
        deleted.remove(blob.path);
        continue;
      }
      final target = File(_absPath(root, blob.path));
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(blob.bytes, flush: true);
      await tmp.rename(target.path);
      files[blob.path] = NoteVersion(
        hlc: blob.hlc,
        sha: fnv1a64(blob.bytes),
        size: blob.bytes.length,
      );
      deleted.remove(blob.path);
      written++;
    }

    await _writeState(
      NotesSyncState(files: files, deleted: deleted, purged: purged),
    );
    if (received || written > 0 || deletedCount > 0 || purgedCount > 0) {
      await persistClock();
    }
    return NotesApplyReport(
      written: written,
      deleted: deletedCount,
      purged: purgedCount,
      skippedOld: skippedOld,
    );
  }

  /// 给传输层用的四个动作。
  NotesChannel toChannel() => NotesChannel(
        describe: scan,
        read: readBlobs,
        apply: apply,
        persistClock: persistClock,
      );

  // --- 文件系统小工具 ---------------------------------------------------

  Iterable<File> _walk(Directory root) sync* {
    if (!root.existsSync()) return;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = _relPath(root, entity);
      if (_isIgnored(rel)) continue;
      yield entity;
    }
  }

  bool _isIgnored(String rel) {
    if (rel.startsWith('.trash/')) return true;
    final name = p.posix.basename(rel);
    if (name == kSyncStateFileName || name == '.order.json') return true;
    if (name == kPurgeQueueFileName) return true; // 彻底删除的暂存清单
    // 1.54：组清单（含每篇归属、折叠、手动顺序）随笔记同步，整文件按
    // HLC 后写者胜——组数据很小，不为此再拆字段级合并。
    if (name.endsWith('.tmp')) return true; // 原子写的中间文件
    return false;
  }

  String _relPath(Directory root, File file) =>
      p.relative(file.path, from: root.path).replaceAll('\\', '/');

  /// 路径 → 文件名（同步路径一律 `/` 分隔）。
  String _nameOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// 取走「刚在回收站里彻底删掉」的暂存清单，并把文件删掉。
  ///
  /// 读完就删：即使这一趟同步没成功，这些名字也已经变成 `purged` 记录
  /// 留在 `.sync.json` 里了，不会丢。
  Future<List<String>> _takePurgeQueue(Directory root) async {
    final file = File(p.join(root.path, kPurgeQueueFileName));
    if (!await file.exists()) return const [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return const [];
      final out = <String>[
        for (final item in raw)
          if (item is String && item.isNotEmpty) item,
      ];
      await file.delete();
      return out;
    } on Object {
      return const [];
    }
  }

  /// 按文件名把一篇笔记彻底抹掉：正文、素材目录、以及回收站里的同名副本。
  ///
  /// 返回「真正删掉了几份正文」——素材与回收站副本不计入，界面上那个数字
  /// 表达的是「几篇笔记」。
  Future<int> _eraseByName(Directory root, String name) async {
    var articles = 0;
    final stem = name.toLowerCase().endsWith('.md')
        ? name.substring(0, name.length - 3)
        : name;

    for (final abs in _pathsMatching(root, name)) {
      final file = File(abs);
      try {
        if (await file.exists()) {
          await file.delete();
          if (name.toLowerCase().endsWith('.md')) articles++;
        }
      } on FileSystemException {
        // 删不掉就跳过：不因为一个文件卡住整趟同步。
      }
    }
    // 素材目录可能还留在「年/月」下（正文已经被删或被挪走了），单独收一遍。
    await _eraseAssetDirs(root, '$stem.assets');
    return articles;
  }

  /// 删掉库里所有名为 [dirName] 的目录（素材目录，可能同时存在回收站副本）。
  Future<void> _eraseAssetDirs(Directory root, String dirName) async {
    if (!root.existsSync()) return;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path) != dirName) continue;
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // 忽略
      }
    }
  }

  /// 库内（含 `.trash/`）所有文件名等于 [name] 的文件的绝对路径。
  List<String> _pathsMatching(Directory root, String name) {
    final out = <String>[];
    if (!root.existsSync()) return out;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (p.basename(entity.path) != name) continue;
      out.add(entity.path);
    }
    return out;
  }

  String _absPath(Directory root, String rel) =>
      p.normalize(p.join(root.path, rel));

  /// 远端把它删了：移到 `.trash/<时间戳>/` 下，和本机删除一样能找回。
  Future<void> _moveToTrash(Directory root, String rel, File file) async {
    final stamp = _trashStamp();
    var bucket = p.normalize(p.join(root.path, '.trash', stamp));
    var attempt = 2;
    while (Directory(bucket).existsSync()) {
      bucket = p.normalize(p.join(root.path, '.trash', '$stamp -$attempt'));
      attempt++;
    }
    final target = File(p.normalize(p.join(bucket, rel.replaceAll('/', p.separator))));
    try {
      await target.parent.create(recursive: true);
      await file.rename(target.path);
    } on Object {
      // 挪不动就直接删：同步的目标是两端一致，不能因为一个文件卡住整趟。
      try {
        await file.delete();
      } on Object {
        // 忽略
      }
    }
  }

  String _trashStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}${two(now.minute)}';
  }
}
