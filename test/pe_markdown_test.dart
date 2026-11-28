import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pnote/notes/pe_code_block.dart';
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

    test('四个空格缩进的段落不会被当成代码块（中文笔记常见写法）', () {
      const source = '# 日记\n\n    第一段缩进\n\n    第二段缩进\n';
      final doc = peDocumentFromMarkdown(source);
      final types = <String>[];
      void visit(Node node) {
        types.add(node.type);
        for (final child in node.children) {
          visit(child);
        }
      }

      visit(doc.root);
      expect(types.where((type) => type == 'code'), isEmpty);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('    第一段缩进'));
      expect(out, contains('    第二段缩进'));
      expect(out, isNot(contains('```')));
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

    test('正文中间的 ![[素材名]] 拆成图片行，文字不丢', () {
      const source = '正文 ![[图.png]] 和 [[另一篇]]';
      final doc = peDocumentFromMarkdown(
        source,
        resolveImage: (name) => 'C:\\素材\\$name',
      );
      final images = <Node>[];
      final texts = <String>[];
      void visit(Node node) {
        if (node.type == ImageBlockKeys.type) {
          images.add(node);
        }
        final delta = node.delta;
        if (delta != null) {
          texts.add(delta.toPlainText());
        }
        for (final child in node.children) {
          visit(child);
        }
      }

      visit(doc.root);
      expect(images, hasLength(1));
      expect(texts.join('\n'), contains('正文'));
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('![[图.png]]'));
      expect(out, contains('[[另一篇]]'));
      expect(out, contains('正文'));
    });
  });

  group('PEditor 笔记引用（1.65，不做数据迁移）', () {
    List<String> noteHrefs(Document document) {
      final hrefs = <String>[];
      void visit(Node node) {
        final delta = node.delta;
        if (delta != null) {
          for (final operation in delta) {
            if (operation is TextInsert) {
              final href = operation.attributes?[AppFlowyRichTextKeys.href];
              if (href is String) hrefs.add(href);
            }
          }
        }
        for (final child in node.children) {
          visit(child);
        }
      }

      visit(document.root);
      return hrefs;
    }

    test('行内的 [[名字]] 变成链接，导出仍写 [[名字]]', () {
      const source = '引用一下 [[买菜清单]] 和 [[读书#要点]]。';
      final doc = peDocumentFromMarkdown(source);
      final hrefs = noteHrefs(doc);
      expect(hrefs, hasLength(2));
      expect(hrefs.first, startsWith(kPnoteNoteScheme));
      expect(peMarkdownFromDocument(doc), source);
    });

    test('单独成行的 [[名字]] 往返不丢', () {
      const source = '[[读书笔记]]';
      final doc = peDocumentFromMarkdown(source);
      expect(noteHrefs(doc), hasLength(1));
      expect(peMarkdownFromDocument(doc), source);
    });

    test('普通网页链接保持原样', () {
      const source = '看 [官网](https://example.com) 就行';
      final doc = peDocumentFromMarkdown(source);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('https://example.com'));
      expect(out, contains('官网'));
      expect(out, isNot(contains(kPnoteNoteScheme)));
    });

    test('peNoteRefRaw 与 peNoteRefHref 互转', () {
      final href = peNoteRefHref('[[读书#要点]]');
      expect(href, startsWith(kPnoteNoteScheme));
      expect(peNoteRefRaw(href), '[[读书#要点]]');
      expect(peNoteRefRaw('https://example.com'), isNull);
    });
  });

  group('PEditor 代码块（1.65，不做数据迁移）', () {
    test('围栏代码解析成代码块节点，带语言，导出与原串一致', () {
      const source = '```dart\nvoid main() {\n  print("hi");\n}\n```';
      final doc = peDocumentFromMarkdown(source);
      final node = doc.root.children.first;
      expect(node.type, PnoteCodeBlockKeys.type);
      expect(pnoteCodeLanguage(node), 'dart');
      expect(pnoteCodeText(node), 'void main() {\n  print("hi");\n}');
      expect(peMarkdownFromDocument(doc), source);
    });

    test('没有语言的围栏也能往返', () {
      const source = '```\nplain text\nline 2\n```';
      final doc = peDocumentFromMarkdown(source);
      final node = doc.root.children.first;
      expect(node.type, PnoteCodeBlockKeys.type);
      expect(pnoteCodeLanguage(node), '');
      expect(peMarkdownFromDocument(doc), source);
    });

    test('围栏里的 ![[图.png]] 与 [[引用]] 不被当成图片/笔记引用改写', () {
      const source = '```text\n![[图.png]]\n[[引用]]\n[x](pnote:note:abc)\n```';
      final doc = peDocumentFromMarkdown(source);
      final node = doc.root.children.first;
      expect(pnoteCodeText(node), contains('![[图.png]]'));
      expect(pnoteCodeText(node), contains('[[引用]]'));
      final out = peMarkdownFromDocument(doc);
      expect(out, source);
    });

    test('代码块前后的普通段落照旧', () {
      const source = '前一段\n\n```python\nprint(1)\n```\n\n后一段';
      final doc = peDocumentFromMarkdown(source);
      expect(doc.root.children.length, 3);
      expect(doc.root.children[1].type, PnoteCodeBlockKeys.type);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('前一段'));
      expect(out, contains('```python'));
      expect(out, contains('print(1)'));
      expect(out, contains('后一段'));
    });
  });

  group('PEditor 表格（1.65，不做数据迁移）', () {
    test('管道表格解析成 table 节点，单元格文字与导出都保留', () {
      const source = '| 姓名 | 年龄 |\n| --- | --- |\n| 张三 | 20 |\n| 李四 | 30 |';
      final doc = peDocumentFromMarkdown(source);
      final node = doc.root.children.first;
      expect(node.type, TableBlockKeys.type);
      expect(node.attributes[TableBlockKeys.colsLen], 2);
      // 上游把表头也当成普通的一行数据：表头 + 2 行正文 = 3 行。
      expect(node.attributes[TableBlockKeys.rowsLen], 3);
      expect(node.children.length, 6);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('姓名'));
      expect(out, contains('张三'));
      expect(out, contains('李四'));
      expect(out, contains('|-|-|'));
    });

    test('表格里的 [[引用]] 不被改写，导出仍是原文', () {
      const source = '| 笔记 | 备注 |\n| --- | --- |\n| [[读书]] | 好 |';
      final doc = peDocumentFromMarkdown(source);
      final out = peMarkdownFromDocument(doc);
      expect(out, contains('[[读书]]'));
      expect(out, isNot(contains(kPnoteNoteScheme)));
    });
  });
}
