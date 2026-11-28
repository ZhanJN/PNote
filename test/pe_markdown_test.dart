import 'package:flutter_test/flutter_test.dart';

import 'package:pnote/notes/pe_markdown.dart';

void main() {
  group('PEditor Markdown 往返（1.64 地基）', () {
    test('标题与段落', () {
      final doc = peDocumentFromMarkdown('# 标题\n\n正文一段');
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('# 标题'));
      expect(out, contains('正文一段'));
    });

    test('列表与待办', () {
      const source = '- 甲\n- 乙\n\n1. 一\n2. 二\n\n- [ ] 没做\n- [x] 做了';
      final out = peMarkdownFromDocument(peDocumentFromMarkdown(source));
      expect(out, contains('甲'));
      expect(out, contains('乙'));
      expect(out, contains('1. 一'));
      expect(out, contains('2. 二'));
      expect(out.replaceAll(' ', ''), contains('-[]没做'));
      expect(out.replaceAll(' ', ''), contains('-[x]做了'));
    });

    test('代码围栏不丢内容（1.64 fork 补丁）', () {
      const source = '```dart\nfinal a = 1;\nprint(a);\n```';
      final out = peMarkdownFromDocument(peDocumentFromMarkdown(source));
      expect(out, contains('```dart'));
      expect(out, contains('final a = 1;'));
      expect(out, contains('print(a);'));
      expect(out, contains('```'));
    });

    test('有序列表按连续项重新编号', () {
      const source = '1. 甲\n2. 乙\n3. 丙';
      final out = peMarkdownFromDocument(peDocumentFromMarkdown(source));
      expect(out, contains('1. 甲'));
      expect(out, contains('2. 乙'));
      expect(out, contains('3. 丙'));
    });

    test('引用与分割线', () {
      const source = '> 一句引用\n\n上面\n\n---\n\n下面';
      final out = peMarkdownFromDocument(peDocumentFromMarkdown(source));
      expect(out, contains('> 一句引用'));
      expect(out, contains('---'));
      expect(out, contains('上面'));
      expect(out, contains('下面'));
    });

    test('空文本得到可编辑的空文档', () {
      final doc = peDocumentFromMarkdown('   ');
      expect(doc.root.children.length, greaterThan(0));
      expect(peMarkdownFromDocument(doc).trim(), isEmpty);
    });
  });

  group('PEditor 图片（1.65，不做数据迁移）', () {
    test('独立成行的 ![[素材名]] 往返不丢', () {
      const source = '上面\n\n![[照片.png]]\n\n下面';
      final doc = peDocumentFromMarkdown(source);
      final image = doc.root.children.where(
        (node) => node.type == 'image',
      );
      expect(image, isNotEmpty);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('![[照片.png]]'));
      expect(out, contains('上面'));
      expect(out, contains('下面'));
    });

    test('素材名换成绝对路径后仍导出 ![[素材名]]', () {
      const source = '![[照片 01.png]]';
      final doc = peDocumentFromMarkdown(
        source,
        resolveImage: (name) => 'D:/笔记库/2026/01/x.assets/$name',
      );
      final node = doc.root.children.firstWhere((n) => n.type == 'image');
      expect(node.attributes['url'], contains('照片 01.png'));
      expect(node.attributes['url'], startsWith('D:/'));
      final out = peMarkdownFromDocument(doc);
      expect(out.trim(), '![[照片 01.png]]');
    });

    test('找不到素材时保留名字，不吞行', () {
      const source = '![[不存在.png]]';
      final doc = peDocumentFromMarkdown(source, resolveImage: (name) => null);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('![[不存在.png]]'));
    });

    test('网络图片保持原样', () {
      const source = '![](https://example.com/a.png)';
      final doc = peDocumentFromMarkdown(source);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('https://example.com/a.png'));
      expect(out, isNot(contains('![[')));
    });

    test('正文中间的 ![[素材名]] 留成文字不丢内容', () {
      const source = '正文 ![[图.png]] 和 [[另一篇]]';
      final doc = peDocumentFromMarkdown(source);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('正文'));
      expect(out, contains('![[图.png]]'));
      expect(out, contains('[[另一篇]]'));
    });
  });
}
