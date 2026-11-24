/// 搜索层：内存扫描，不建库、不留索引文件（1.41 第一步）。
///
/// 库按 2000 篇算，全量读一遍也就几十毫秒到一两秒，所以先不用 SQLite 倒排。
/// 等真的卡了再上 notes/links/terms 三表（见项目说明 8.12 第二步）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';

/// 一条搜索命中。
class NoteHit {
  const NoteHit({
    required this.note,
    required this.snippet,
    required this.inTitle,
  });

  final NoteFile note;

  /// 命中位置前后各约 30 字，换行压成空格。
  final String snippet;

  /// 是否命中标题（命中标题的排在前面）。
  final bool inTitle;
}

/// 返回上限，防止输入一个字母就把整个库刷屏。
const int kSearchHitLimit = 50;

/// 在 [notes] 里搜 [query]（不区分大小写）。
///
/// 传了 [notes] 就不重新扫目录——界面已经有列表，直接用。
Future<List<NoteHit>> searchNotes(
  List<NoteFile> notes,
  String query,
) async {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <NoteHit>[];

  final root = await notesRoot();
  final hits = <NoteHit>[];
  for (final note in notes) {
    final titleHit = note.title.toLowerCase().contains(needle);
    final file = File(p.join(root.path, note.relPath));
    String snippet = '';
    var bodyHit = false;
    if (!titleHit) {
      try {
        final text = await file.readAsString();
        bodyHit = text.toLowerCase().contains(needle);
        if (bodyHit) snippet = _snippetAround(text, needle);
      } on FileSystemException {
        continue;
      }
    }
    if (!titleHit && !bodyHit) continue;
    hits.add(NoteHit(note: note, snippet: snippet, inTitle: titleHit));
    if (hits.length >= kSearchHitLimit) break;
  }
  hits.sort((a, b) {
    if (a.inTitle != b.inTitle) return a.inTitle ? -1 : 1;
    return b.note.createdAt.compareTo(a.note.createdAt);
  });
  return hits;
}

String _snippetAround(String text, String needle) {
  final index = text.toLowerCase().indexOf(needle);
  if (index < 0) return '';
  final start = index - 30 < 0 ? 0 : index - 30;
  final end = index + needle.length + 30 > text.length
      ? text.length
      : index + needle.length + 30;
  final raw = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  return '$prefix$raw$suffix';
}

/// 校验源码是不是能按 UTF-8 读（导入素材前用一下，防止把二进制当文本）。
bool looksLikeUtf8Text(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}
