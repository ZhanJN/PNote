/// 渲染层测试（1.41）：确认各块都能画出来，缺失素材有明确提示。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_render.dart';

Widget _wrap(NoteDoc doc, {bool Function(String)? hasNote}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: NoteRender(
          doc: doc,
          hasNote: hasNote ?? (_) => false,
          openNote: (_) {},
        ),
      ),
    ),
  );
}

TextSpan? _findSpan(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text) return span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = _findSpan(child, text);
      if (found != null) return found;
    }
  }
  return null;
}

void main() {
  testWidgets('标题、加粗、列表、代码块、表格都能渲染', (tester) async {
    final doc = parseNoteSource(
      '# 大标题\n\n**加粗**和*斜体*\n\n- 第一项\n- 第二项\n\n'
      '```dart\nvar a = 1;\n```\n\n| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n',
    );
    await tester.pumpWidget(_wrap(doc));

    expect(find.textContaining('大标题'), findsOneWidget);
    expect(find.textContaining('加粗'), findsOneWidget);
    expect(find.textContaining('第一项'), findsOneWidget);
    expect(find.textContaining('var a = 1;'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
  });

  testWidgets('引用缺失时有明确提示，不会静默吞掉', (tester) async {
    final doc = parseNoteSource('看这张 ![[不存在的图.png]]\n\n再看 [[不存在的笔记]]\n');
    await tester.pumpWidget(_wrap(doc));

    expect(find.textContaining('缺图'), findsOneWidget);
    expect(find.textContaining('不存在的笔记'), findsOneWidget);
  });

  testWidgets('1.61 预览里的 ==高亮== 有底色且不显示标记', (tester) async {
    await tester.pumpWidget(_wrap(parseNoteSource('这是 ==重点== 文字')));
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    final span = _findSpan(rich.text, '重点');
    expect(span, isNotNull);
    expect(span!.style?.backgroundColor, isNotNull);
    expect(find.textContaining('=='), findsNothing);
  });

  testWidgets('1.61 ::: center 在预览里居中且不显示标记', (tester) async {
    final doc = parseNoteSource('::: center\n中间一段\n:::', keepBlankLines: true);
    await tester.pumpWidget(_wrap(doc));
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    expect(rich.textAlign, TextAlign.center);
    expect(find.textContaining(':::'), findsNothing);
    expect(find.textContaining('中间一段'), findsOneWidget);
  });

  testWidgets('空笔记给出空态文案', (tester) async {
    await tester.pumpWidget(_wrap(parseNoteSource('')));
    expect(find.text('（空笔记）'), findsOneWidget);
  });

  testWidgets('链接命中已知笔记时用主题色渲染（不报错即可）', (tester) async {
    final doc = parseNoteSource('见 [[白板复盘]]');
    await tester.pumpWidget(_wrap(doc, hasNote: (stem) => stem == '白板复盘'));
    expect(find.textContaining('白板复盘'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('带锚点的链接显示成「笔记 › 要点」（1.44）', (tester) async {
    final doc = parseNoteSource('见 [[白板复盘#第三步]]');
    await tester.pumpWidget(_wrap(doc, hasNote: (stem) => stem == '白板复盘'));
    expect(find.textContaining('白板复盘 › 第三步'), findsOneWidget);
  });
}
