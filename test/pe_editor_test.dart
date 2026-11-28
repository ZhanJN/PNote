import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pnote/ui/notes/pe_editor.dart';

void main() {
  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? ThemeData.dark(),
      home: Scaffold(body: SizedBox(height: 600, child: child)),
    );
  }

  testWidgets('PEditor 能挂载并显示初始文本（1.64）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '# 标题\n\n正文一段',
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PEditor), findsOneWidget);
    expect(find.textContaining('标题', findRichText: true), findsWidgets);
  });

  testWidgets('1.64.1 深色主题下编辑文字用 onSurface（不是写死白色）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(initialText: '正文', onChanged: (_) {}),
        theme: ThemeData.dark(),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    final config = editor.editorStyle.textStyleConfiguration;
    expect(config.text.color, ThemeData.dark().colorScheme.onSurface);
    expect(config.bold.color, ThemeData.dark().colorScheme.onSurface);
  });

  testWidgets('1.64.2 浅色主题下编辑文字是深色 onSurface', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(initialText: '正文', onChanged: (_) {}),
        theme: ThemeData.light(),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    final config = editor.editorStyle.textStyleConfiguration;
    final light = ThemeData.light().colorScheme;
    expect(config.text.color, light.onSurface);
    expect(config.text.color, isNot(Colors.white));
    expect(config.code.backgroundColor!.a, greaterThan(0));
  });

  testWidgets('1.64.1 手机宽度下出现 MobileToolbar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      wrap(PEditor(initialText: '正文', onChanged: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MobileToolbar), findsOneWidget);
  });

  testWidgets('1.64.1 图片节点后自动补一个空段落', (tester) async {
    await tester.pumpWidget(
      wrap(PEditor(initialText: '正文', onChanged: (_) {})),
    );
    await tester.pumpAndSettle();
    final state = tester.state<PEditorState>(find.byType(PEditor));
    final editorState = state.editorState;
    final transaction = editorState.transaction
      ..insertNode(
        [editorState.document.root.children.length],
        imageNode(url: 'https://example.com/x.png'),
      );
    await editorState.apply(transaction);
    await tester.pump(const Duration(milliseconds: 300));
    expect(editorState.document.root.children.last.type, 'paragraph');
  });
}
