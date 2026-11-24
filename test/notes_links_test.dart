/// 链接层（1.43）的纯函数测试：反向链接、断链、字数。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_links.dart';
import 'package:pnote/notes/notes_model.dart';

NoteFile _note(String relPath, String title) => NoteFile(
      relPath: relPath,
      title: title,
      createdAt: DateTime(2026, 11, 23, 20, 41),
      modified: DateTime(2026, 11, 23, 20, 41),
      size: 100,
    );

void main() {
  final whiteboard =
      _note('2026/11/2026-11-23 2041 白板复盘.md', '白板复盘');
  final plan = _note('2026/11/2026-11-23 2105 今天的计划.md', '今天的计划');
  final review = _note('2026/11/2026-11-22 1900 周复盘.md', '周复盘');

  test('反向链接：别的笔记提到 [[白板复盘]] 时能列出来，并统计次数', () {
    final links = backlinksOf(
      notes: [whiteboard, plan, review],
      sources: {
        plan.relPath: '# 今天的计划\n\n先看 [[白板复盘]]，再看 [[白板复盘#要点]]。\n',
        review.relPath: '# 周复盘\n\n本周没看白板。\n',
      },
      selfRelPath: whiteboard.relPath,
      stem: '白板复盘',
    );
    expect(links.length, 1);
    expect(links.first.note.title, '今天的计划');
    expect(links.first.hits, 2, reason: '[[白板复盘#要点]] 的 # 之后不算，仍是同一篇');
  });

  test('反向链接：不把自己算进去，也不把附件引用 ![[x]] 算成引用', () {
    final links = backlinksOf(
      notes: [whiteboard, plan],
      sources: {
        whiteboard.relPath: '# 白板复盘\n\n自我引用 [[白板复盘]]\n',
        plan.relPath: '# 今天的计划\n\n![[白板复盘]]\n',
      },
      selfRelPath: whiteboard.relPath,
      stem: '白板复盘',
    );
    expect(links, isEmpty);
  });

  test('反向链接：命中次数多的排前面', () {
    final links = backlinksOf(
      notes: [whiteboard, plan, review],
      sources: {
        plan.relPath: '[[白板复盘]]\n',
        review.relPath: '[[白板复盘]] [[白板复盘]]\n',
      },
      selfRelPath: whiteboard.relPath,
      stem: '白板复盘',
    );
    expect(links.map((l) => l.note.title).toList(), ['周复盘', '今天的计划']);
  });

  test('断链：列出没有对应笔记的 [[x]]，去重且保持出现顺序', () {
    final broken = brokenLinksOf(
      '# 计划\n\n[[白板复盘]] 和 [[不存在的笔记]]，还有 [[不存在的笔记]] 与 [[另一个断链]]。',
      (stem) => stem == '白板复盘',
    );
    expect(broken, ['不存在的笔记', '另一个断链']);
  });

  test('断链：.md 后缀与 # 锚点不影响判断', () {
    final broken = brokenLinksOf(
      '[[白板复盘.md#小结]]',
      (stem) => stem == '白板复盘',
    );
    expect(broken, isEmpty);
  });

  test('字数：只数非空白字符', () {
    expect(countChars('今天 复盘\n\n- 三件事'), 8);
    expect(countChars(''), 0);
  });
}
