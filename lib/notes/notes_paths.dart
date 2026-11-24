/// 笔记库的位置（1.41 起，1.42 改到 exe 旁边）。
///
/// 电脑：`pnote.exe 所在目录\PNote笔记库`（1.42 起）——把整个 PNote 文件夹
/// 拷走，笔记跟着走；资源管理器里能直接看到、用记事本打开。第一次启动时如果
/// 旧的 `文档\PNote笔记库` 里有笔记，会自动搬一批过来（见 [_adoptLegacy]）。
/// 手机：App 私有文档目录下的 `PNote笔记库`（用户选的是 A 方案：零权限、
/// 最稳；想拿出去用 USB 拷贝或整个目录复制，见项目说明 8.12）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 笔记库最外层目录名。用中文，因为这是用户会看到的东西。
const String kNotesFolderName = 'PNote笔记库';

/// 「刚刚在回收站里彻底删掉了这些」的暂存文件名（库根下，1.49）。
///
/// 为什么先暂存：文件层不该知道 HLC，而「彻底删除」要带一个版本号才能在
/// 两端判先后。所以删除动作只把文件名记在这里，等同步层给它们盖时间戳、
/// 写进 `.sync.json` 的 `purged`，再把暂存文件删掉（见 notes_sync.dart）。
const String kPurgeQueueFileName = '.purge.json';

Directory? _overrideRoot;
Directory? _cachedRoot;
bool _legacyChecked = false;

/// 测试用：把笔记库指到一个临时目录；传 null 恢复默认。
void setNotesRootOverride(Directory? dir) {
  _overrideRoot = dir;
  _cachedRoot = null;
  _legacyChecked = false;
}

/// 当前笔记本体目录（不存在会创建）。
Future<Directory> notesRoot() async {
  final override = _overrideRoot;
  if (override != null) {
    // 测试目录：用同步 IO 保证创建，避免 testWidgets 的 FakeAsync 里
    // 一个 `await exists()` 永远等不到真实事件循环（7.40 的老坑）。
    if (!override.existsSync()) override.createSync(recursive: true);
    return override;
  }
  final cached = _cachedRoot;
  if (cached != null && await cached.exists()) return cached;
  final dir = await _resolveDefaultRoot();
  await _ensureDir(dir);
  _cachedRoot = dir;
  return dir;
}

/// 电脑端：exe 旁边的 `PNote笔记库`；手机（和 exe 不可写的电脑）：
/// 私有文档目录下的同名目录。
///
/// 只有 exe 叫 `pnote` 时才用 exe 目录——`flutter test` 的 exe 是 dart.exe，
/// 不拦一下就会把库建进 Flutter SDK 里（1.42 修）。
Future<Directory> _resolveDefaultRoot() async {
  final besideExe = _dirBesideExe();
  if (besideExe != null && await _canCreate(besideExe)) {
    if (!_legacyChecked) {
      _legacyChecked = true;
      await _adoptLegacy(besideExe);
    }
    return besideExe;
  }
  final base = await getApplicationDocumentsDirectory();
  return Directory(p.join(base.path, kNotesFolderName));
}

Directory? _dirBesideExe() {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return null;
  final exe = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(exe).toLowerCase() != 'pnote') return null;
  return Directory(notesFolderForExecutable(exe));
}

/// exe 路径 → 笔记库目录（纯函数，方便测试）。
///
/// 正式版是 `…\PNote_V2\pc\pnote.exe`：库放在 **PNote_V2 文件夹根下**
/// （`…\PNote_V2\PNote笔记库`），这样刷新 `pc\` 里的程序不会把笔记一起
/// 覆盖掉。exe 不在 `pc` 里时（比如 `flutter run` 的构建输出），就放在
/// exe 自己旁边。
String notesFolderForExecutable(String exePath) {
  final exeDir = p.dirname(exePath);
  final parent = p.basename(exeDir).toLowerCase() == 'pc' ? p.dirname(exeDir) : exeDir;
  return p.join(parent, kNotesFolderName);
}

Future<bool> _canCreate(Directory dir) async {
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 第一次在 exe 旁边建库时，把旧的 `文档\PNote笔记库` 里的笔记搬过来。
///
/// 只在「新库还没有任何 .md」时搬；搬是复制不是移动（旧目录原样留着，
/// 用户确认没问题后可以自己删）。任何一步失败都只是少搬几篇，绝不阻塞启动。
Future<void> _adoptLegacy(Directory newRoot) async {
  try {
    if (_hasMarkdown(newRoot)) return;
    final base = await getApplicationDocumentsDirectory();
    final legacy = Directory(p.join(base.path, kNotesFolderName));
    if (p.equals(p.absolute(legacy.path), p.absolute(newRoot.path))) return;
    if (!legacy.existsSync() || !_hasMarkdown(legacy)) return;
    _copyTree(legacy, newRoot);
  } on Object {
    // 搬家是锦上添花，失败不影响 App 起来（此后用户看到的空库就是真相）。
  }
}

bool _hasMarkdown(Directory dir) {
  final found = <bool>[false];
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (found.first) break;
      if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
        final rel = p.relative(entity.path, from: dir.path);
        if (rel.split(Platform.pathSeparator).any((s) => s.startsWith('.'))) {
          continue;
        }
        found[0] = true;
      }
    }
  } on FileSystemException {
    return false;
  }
  return found.first;
}

void _copyTree(Directory from, Directory to) {
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(entity.path, from: from.path);
    final target = p.join(to.path, rel);
    try {
      if (entity is File) {
        final out = File(target);
        out.parent.createSync(recursive: true);
        if (!out.existsSync()) entity.copySync(target);
      } else if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      }
    } on FileSystemException {
      // 单个文件失败跳过。
    }
  }
}

/// 库内相对路径 → 绝对路径。拒绝 `..` 跳出库根。
Future<File> noteFileFor(String relPath) async {
  final root = await notesRoot();
  final file = File(nativePathIn(root, relPath));
  _guardInside(root, file.path);
  return file;
}

/// 库内相对路径（统一用 `/` 存，见 NotesStore.list）→ **本机分隔符**的绝对路径。
///
/// 1.46.1 修：`p.join` 只会在拼接处用本机分隔符，`relPath` 里剩下的 `/` 会原样
/// 保留（`…\2026/11/x.md`）。文件 API 不在乎，但 `explorer.exe /select,` 会在
/// 遇到 `/` 时把后面的片段当开关，于是退回「桌面」并选中「文档」——用户看到
/// 的就是「在文件夹中显示却打开了桌面」。所以交给 shell 之前必须 normalize。
String nativePathIn(Directory root, String relPath) {
  return p.normalize(p.join(root.path, relPath));
}


/// 素材目录 → 绝对路径（不存在时创建）。
Future<Directory> noteAssetsFor(String relPath) async {
  final root = await notesRoot();
  final dir = Directory(p.join(root.path, '$relPath.assets'));
  _guardInside(root, dir.path);
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// 回收目录。
Future<Directory> trashRoot() async {
  final root = await notesRoot();
  final dir = Directory(p.join(root.path, '.trash'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

void _guardInside(Directory root, String path) {
  final rootPath = p.normalize(root.absolute.path);
  final target = p.normalize(p.absolute(path));
  if (!p.isWithin(rootPath, target) && target != rootPath) {
    throw FileSystemException('路径不在笔记库内', path);
  }
}

Future<void> _ensureDir(Directory dir) async {
  if (!await dir.exists()) await dir.create(recursive: true);
}
