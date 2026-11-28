library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/markdown_blocks.dart';

void main() {
  test('块解析：标题/列表/待办/引用/代码/分割线/图片', () {
    const source = '# 大标题\n'
        '## 中标题\n'
        '### 小标题\n'
        '\n'
        '正文一段\n'
        '- 无序\n'
        '1. 有序\n'
        '- [x] 已完成\n'
        '- [ ] 没做\n'
        '> 引用\n'
        '```\ncode();\n```\n'
        '---\n'
        '![[图片.png]]\n'
        '| a | b |';
    final blocks = MdBlock.parseBlocks(source);
    expect(blocks.map((b) => b.kind).toList(), [
      MdBlockKind.heading1,
      MdBlockKind.heading2,
      MdBlockKind.heading3,
      MdBlockKind.blank,
      MdBlockKind.paragraph,
      MdBlockKind.bullet,
      MdBlockKind.numbered,
      MdBlockKind.todo,
      MdBlockKind.todo,
      MdBlockKind.quote,
      MdBlockKind.code,
      MdBlockKind.divider,
      MdBlockKind.image,
      MdBlockKind.table,
    ]);
    expect(blocks[7].checked, isTrue);
    expect(blocks[8].checked, isFalse);
    expect(blocks[12].imageName, '图片.png');
  });

  test('解析再编码能原样往返（不改用户格式）', () {
    const samples = [
      '# 标题\n\n正文\n\n- 一\n- 二\n',
      '```dart\nfinal a = 1;\nprint(a);\n```\n',
      '今天\n\n> 引用一句\n\n![[照片.jpg]]\n',
      '| 列1 | 列2 |\n| --- | --- |\n| a | b |\n',
      '',
      '\n\n\n',
    ];
    for (final source in samples) {
      final encoded = MdBlock.encodeBlocks(MdBlock.parseBlocks(source));
      expect(encoded, source, reason: '往返失败：$source');
    }
  });

  test('空文本解析成空列表，编码回空串', () {
    expect(MdBlock.parseBlocks(''), isEmpty);
    expect(MdBlock.encodeBlocks(const []), '');
  });

  test('startsBlock 能识别常见块开头', () {
    expect(MdBlock.startsBlock('# 标题'), isTrue);
    expect(MdBlock.startsBlock('- 列表'), isTrue);
    expect(MdBlock.startsBlock('| a |'), isTrue);
    expect(MdBlock.startsBlock('```'), isTrue);
    expect(MdBlock.startsBlock('普通文字'), isFalse);
  });

  test('连续空行在预览里扩成零宽行，围栏内不动', () {
    expect(expandBlankLines('a\n\nb'), 'a\n\nb');
    final expanded = expandBlankLines('a\n\n\n\nb');
    final lines = expanded.split('\n');
    expect(lines.length, 5);
    expect(lines[2], '\u200B');
    expect(lines[3], '\u200B');

    final fenced = expandBlankLines('```\n\n\n\n```');
    expect(fenced, '```\n\n\n\n```');
  });

  test('1.60 缺空格标题补空格，纯井号行按空行，围栏内不动', () {
    final blocks = MdBlock.parseBlocks('###标题');
    expect(blocks.single.kind, MdBlockKind.heading3);
    final only = MdBlock.parseBlocks('###');
    expect(only.single.kind, MdBlockKind.blank);
    final fenced = normalizeHeadings('```\n###标题\n```');
    expect(fenced, contains('###标题'));
  });

  test('1.60 围栏外的四空格缩进换成不换行空格', () {
    expect(protectIndentedLines('    正文'), '\u00A0\u00A0\u00A0\u00A0正文');
    final fenced = protectIndentedLines('```\n    代码\n```');
    expect(fenced, contains('    代码'));
  });

  test('1.60 有序列表按连续段重新编号', () {
    final blocks = MdBlock.parseBlocks('1. 甲\n1. 乙\n1. 丙');
    final encoded = MdBlock.encodeBlocks(blocks);
    expect(encoded, '1. 甲\n2. 乙\n3. 丙');
  });

  test('1.61 对齐块解析成段落并原样写回', () {
    final blocks = MdBlock.parseBlocks('::: center\n中间一段\n\n:::\n\n后文');
    expect(blocks.first.kind, MdBlockKind.paragraph);
    expect(blocks.first.align, 'center');
    expect(blocks.first.text, '中间一段\n');
    final encoded = MdBlock.encodeBlocks(blocks);
    expect(encoded, contains('::: center'));
    expect(encoded, contains('后文'));
  });

  test('1.61 对齐标记在预览前转成不可见前缀', () {
    final marked = applyAlignmentMarkers('::: right\n靠右\n:::');
    expect(marked, contains('\u2065靠右'));
    expect(marked, isNot(contains(':::')));
  });

  test('1.63 空行不打断有序列表编号', () {
    final blocks = MdBlock.parseBlocks('1. 甲\n\n1. 乙\n\n1. 丙');
    expect(MdBlock.encodeBlocks(blocks), '1. 甲\n\n2. 乙\n\n3. 丙');
  });
}
