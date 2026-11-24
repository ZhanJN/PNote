/// 链接层（1.43 第二步第一块）：反向链接、断链、字数统计。
///
/// 只有两个纯函数 + 一个数据类：输入是「已经读出来的源码」，不读磁盘、
/// 不碰 UI，方便单测（跟 merge.dart 一个风格）。
library;

import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_model.dart';

/// 一条反向链接：哪篇笔记引用了目标笔记，引用了多少次。
class Backlink {
  const Backlink({required this.note, required this.hits});

  final NoteFile note;

  /// 这篇笔记里出现了几次 `[[目标]]`（`![[目标]]` 算附件引用，不计）。
  final int hits;
}

/// 找出引用了 [stem] 的所有笔记（按命中次数从多到少、再按标题排序）。
///
/// [sources] 是 `relPath -> 源码`；缺某篇的源码时跳过它（宁可少列，不猜）。
List<Backlink> backlinksOf({
  required List<NoteFile> notes,
  required Map<String, String> sources,
  required String selfRelPath,
  required String stem,
}) {
  final key = stem.trim();
  if (key.isEmpty) return const <Backlink>[];
  final result = <Backlink>[];
  for (final note in notes) {
    if (note.relPath == selfRelPath) continue;
    final text = sources[note.relPath];
    if (text == null || !text.contains('[[')) continue;
    var hits = 0;
    for (final match in kRefPattern.allMatches(text)) {
      if (match.group(1) == '!') continue;
      if (normalizeRefKey(match.group(2)!) == key) hits++;
    }
    if (hits > 0) result.add(Backlink(note: note, hits: hits));
  }
  result.sort((a, b) {
    final byHits = b.hits.compareTo(a.hits);
    if (byHits != 0) return byHits;
    return a.note.title.compareTo(b.note.title);
  });
  return result;
}

/// 断链：文档里引用了、但库里没有的笔记名（按首次出现顺序、已去重）。
List<String> brokenLinksOf(String source, bool Function(String stem) hasNote) {
  final seen = <String>{};
  final broken = <String>[];
  for (final match in kRefPattern.allMatches(source)) {
    if (match.group(1) == '!') continue;
    final key = normalizeRefKey(match.group(2)!);
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    if (!hasNote(key)) broken.add(key);
  }
  return broken;
}

/// 字数：去掉空白字符后的字符数（中文按字算、英文按字母算，不做分词）。
int countChars(String text) => text.replaceAll(RegExp(r'\s'), '').length;
