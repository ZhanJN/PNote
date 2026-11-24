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
