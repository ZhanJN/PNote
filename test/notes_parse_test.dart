/// 解析层 + 格式化 + 搜索（1.41）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_format.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_search.dart';
import 'package:pnote/notes/notes_store.dart';

void main() {
  group('解析', () {
    test('标题按顺序收集，引用分成素材和笔记两类', () {
      final doc = parseNoteSource(
        '# 一级\n\n## 二级\n\n正文 ![[图.png]] 和 [[另一篇]]\n\n'
        '再一个 ![[资料.pdf]]\n',
      );
      expect(doc.headings, <String>['一级', '二级']);
      expect(doc.assets, containsAll(<String>['图.png', '资料.pdf']));
      expect(doc.links, <String>['另一篇']);
    });

    test('链接名规范化：去掉 # 之后的部分与 .md 后缀', () {
      expect(normalizeRefKey('白板复盘'), '白板复盘');
      expect(normalizeRefKey('白板复盘#第三步'), '白板复盘');
      expect(normalizeRefKey('2026-11-23 2041 白板复盘.md'), '2026-11-23 2041 白板复盘');
    });

    test('空文本与坏语法都不抛异常', () {
      expect(parseNoteSource('').isEmpty, isTrue);
      final doc = parseNoteSource('# 没闭合的 **粗体\n\n```\n没闭合的代码块');
      expect(doc.nodes, isNotEmpty);
    });

    test('标题带层级与源码偏移，锚点能单独取出来（1.44）', () {
      const source = '# 一\n\n正文\n\n### 三\n';
      final doc = parseNoteSource(source);
      expect(doc.headingItems.length, 2);
      expect(doc.headingItems[0].level, 1);
      expect(doc.headingItems[1].level, 3);
      for (final item in doc.headingItems) {
        expect(source.substring(item.offset).startsWith('#'), isTrue,
            reason: '偏移量应该指向 # 号');
      }
      expect(refAnchor('白板复盘#第三步'), '第三步');
      expect(refAnchor('白板复盘'), isNull);
      expect(refAnchor('白板复盘#'), isNull);
    });

    test('围栏代码块里的 # 不算标题（1.44）', () {
      const source = '# 真标题\n\n```python\n# 这是注释\nprint(1)\n```\n\n## 另一个\n';
      final doc = parseNoteSource(source);
      expect(doc.headings, <String>['真标题', '另一个']);
      expect(doc.headingItems.length, 2);
    });

    test('标题匹配锚点忽略大小写与首尾空格（1.44）', () {
      const heading = NoteHeading(level: 2, text: 'Next Steps', offset: 0);
      expect(heading.matches(' next steps '), isTrue);
      expect(heading.matches('下一步'), isFalse);
    });
  });

  group('格式化', () {
    test('大小', () {
      expect(formatSize(0), '0 B');
      expect(formatSize(1023), '1023 B');
      expect(formatSize(1536), '1.5 KB');
      expect(formatSize(15 * 1024 * 1024), '15 MB');
    });

    test('相对时间', () {
      final now = DateTime(2026, 11, 23, 21, 0);
      expect(formatRelative(now.subtract(const Duration(seconds: 5)), now), '刚刚');
      expect(formatRelative(now.subtract(const Duration(minutes: 12)), now), '12 分钟前');
      expect(formatRelative(now.subtract(const Duration(hours: 3)), now), '3 小时前');
      expect(formatRelative(DateTime(2026, 11, 22, 8), now), '昨天');
      expect(formatRelative(DateTime(2026, 11, 3, 8), now), '11-03');
      expect(formatRelative(DateTime(2025, 3, 4, 8), now), '2025-03-04');
    });

    test('年月分组标题', () {
      expect(formatMonthHeader(DateTime(2026, 11, 23)), '2026 年 11 月');
    });
  });

  group('搜索', () {
    late Directory temp;
    const store = NotesStore();

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('pnote_search_');
      setNotesRootOverride(temp);
    });

    tearDown(() async {
      setNotesRootOverride(null);
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('标题命中排在正文命中前面，正文命中带上下文', () async {
      final titled = await store.create('番茄钟');
      await store.create('别的事');
      final body = await store.create('随手记');
      await store.write(body.relPath, '# 随手记\n\n今天用番茄钟工作了四轮，'
          '明天继续。');

      final notes = await store.list();
      final hits = await searchNotes(notes, '番茄钟');
      expect(hits, hasLength(2));
      expect(hits.first.note.relPath, titled.relPath);
      expect(hits.first.inTitle, isTrue);
      expect(hits.last.inTitle, isFalse);
      expect(hits.last.snippet, contains('番茄钟'));
    });

    test('空关键词不返回任何结果', () async {
      await store.create('随便');
      final notes = await store.list();
      expect(await searchNotes(notes, '   '), isEmpty);
    });
  });
}
