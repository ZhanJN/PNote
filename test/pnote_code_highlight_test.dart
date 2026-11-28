import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pnote/notes/pnote_code_highlight.dart';

const _colors = CodeHighlightColors(
  keyword: Color(0xFF000001),
  string: Color(0xFF000002),
  comment: Color(0xFF000003),
  number: Color(0xFF000004),
);

const _base = TextStyle(fontFamily: 'monospace', fontSize: 13);

List<TextSpan> _highlight(String code, String language) =>
    highlightCode(code, language, style: _base, colors: _colors);

Color? _colorOfWord(List<TextSpan> spans, String word) {
  for (final span in spans) {
    if (span.text == word) {
      return span.style?.color;
    }
  }
  return null;
}

void main() {
  test('着色不会丢字或改字：拼起来等于原代码', () {
    const code = 'void main() {\n  print("hi"); // 注释\n  final n = 42;\n}';
    final spans = _highlight(code, 'dart');
    expect(spans.map((span) => span.text).join(), code);
  });

  test('dart：关键字、字符串、注释、数字各有颜色', () {
    final spans = _highlight('final s = "x"; // note\n', 'dart');
    expect(_colorOfWord(spans, 'final'), _colors.keyword);
    expect(_colorOfWord(spans, '"x"'), _colors.string);
    expect(_colorOfWord(spans, '// note'), _colors.comment);
    final numbers = _highlight('answer 42', 'dart');
    expect(_colorOfWord(numbers, '42'), _colors.number);
  });

  test('# 只在类 Python 的语言里算注释', () {
    final python = _highlight('# 说明\nprint(1)', 'python');
    expect(_colorOfWord(python, '# 说明'), _colors.comment);
    // dart 里 # 不是注释：整行保持正文色。
    final dart = _highlight('# 说明', 'dart');
    expect(dart.any((span) => span.style?.color == _colors.comment), isFalse);
  });

  test('未知语言回落到通用关键字，不崩', () {
    final spans = _highlight('return 1', 'someunknown');
    expect(_colorOfWord(spans, 'return'), _colors.keyword);
    expect(spans.map((span) => span.text).join(), 'return 1');
  });

  test('未闭合的字符串和块注释也能切完', () {
    expect(_highlight('"never closed', 'dart').map((s) => s.text).join(),
        '"never closed');
    expect(_highlight('/* never closed', 'dart').map((s) => s.text).join(),
        '/* never closed');
  });
}
