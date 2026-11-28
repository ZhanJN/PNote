import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pnote/ui/notes/pe_editor.dart';

Widget wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: SizedBox(height: 600, child: child)),
  );
}

void main() {
  testWidgets('1.65 跨块选择：从第一段拖到最后一段，中间代码块也一起选中', (tester) async {
    const source = '第一段文字\n\n```dart\nfinal a = 1;\n```\n\n最后一段文字';
    await tester.pumpWidget(
      wrap(PEditor(initialText: source, onChanged: (_) {})),
    );
    await tester.pumpAndSettle();

    final state = tester.state<PEditorState>(find.byType(PEditor));
    final editorState = state.editorState;
    final children = editorState.document.root.children;
    final last = children.length - 1;

    editorState.updateSelectionWithReason(
      Selection(
        start: Position(path: [0], offset: 0),
        end: Position(
          path: [last],
          offset: children[last].delta!.toPlainText().length,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final selection = editorState.selection;
    expect(selection, isNotNull);
    expect(selection!.start.path, [0]);
    expect(selection.end.path, [last]);

    // 选中的内容跨过代码块，复制出来应当是三段文字。
    final text = editorState.getTextInSelection(selection).join('\n');
    expect(text, contains('第一段文字'));
    expect(text, contains('final a = 1;'));
    expect(text, contains('最后一段文字'));
    expect(selection.isSingle, isFalse);
  });

  testWidgets('1.65 手机：长按选中词、出现工具条，往下拖能扩到下一块', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '第一段文字内容\n\n第二段文字内容',
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<PEditorState>(find.byType(PEditor));
    final editorState = state.editorState;

    final richTexts = find.byType(RichText);
    expect(richTexts, findsWidgets);
    final gesture = await tester.startGesture(
      tester.getCenter(richTexts.first),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 50));

    expect(editorState.selection, isNotNull);
    expect(find.byType(MobileToolbar), findsOneWidget);

    // 拖到下面那一块，选区应该跨块扩大。
    final before = editorState.selection!;
    await gesture.moveTo(tester.getCenter(richTexts.last));
    await tester.pump(const Duration(milliseconds: 120));
    final after = editorState.selection!;
    expect(after.start.path, before.start.path);
    expect(after.end.path.length, greaterThanOrEqualTo(before.end.path.length));
    expect(
      after.end.path >= after.start.path,
      isTrue,
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
