/// 笔记的「文件形态」模型（1.41 笔记系统第一步）。
///
/// 真相永远是磁盘上的 Markdown 文件：这里只把路径、标题、时间读出来给界面用，
/// 不保存任何只有本 App 才能解释的状态。删掉整个 App，笔记仍然是可读文本。
/// 见项目说明 8.12、ADR-033。
library;

import 'package:path/path.dart' as p;

/// 一篇笔记。
///
/// [relPath] 是相对笔记库根目录的路径，例如
/// `2026/11/2026-11-23 2041 白板复盘.md`。
class NoteFile {
  const NoteFile({
    required this.relPath,
    required this.title,
    required this.createdAt,
    required this.modified,
    required this.size,
    this.preview = '',
  });

  final String relPath;

  /// 文件第一行 `# 标题`；没有标题行时用文件名去掉时间前缀。
  final String title;

  /// 从文件名解析出的创建时间（文件名就是时间，天然有序）。
  final DateTime createdAt;
  final DateTime modified;
  final int size;

  /// 1.59：标题下方的一行正文预览（标题行之后第一段非空文字）。
  /// 列表关闭预览时为空串，不读正文。
  final String preview;

  /// 去掉 `.md` 的库内路径。素材目录名 = `<id>.assets`。
  String get id =>
      relPath.endsWith('.md') ? relPath.substring(0, relPath.length - 3) : relPath;

  String get assetsRelPath => '$id.assets';

  String get fileName => p.basename(relPath);

  /// 所在目录的库内相对路径，统一用 `/`，方便分组显示。
  String get folderRelPath => p.dirname(relPath).replaceAll('\\', '/');

  NoteFile copyWith({String? relPath, String? title, DateTime? modified, int? size}) {
    return NoteFile(
      relPath: relPath ?? this.relPath,
      title: title ?? this.title,
      createdAt: createdAt,
      modified: modified ?? this.modified,
      size: size ?? this.size,
      preview: preview,
    );
  }
}

/// 回收目录（`.trash`）里的一项。仍然是普通文件，只是换了位置。
class TrashEntry {
  const TrashEntry({
    required this.relPath,
    required this.movedAt,
    required this.title,
  });

  /// 相对 `.trash` 的路径，例如 `2026-11-23 2140 白板复盘/...md`。
  final String relPath;
  final DateTime movedAt;
  final String title;
}
