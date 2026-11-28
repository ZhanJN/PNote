import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pnote/ui/notes/pe_editor.dart';

void main() {
  testWidgets('PEditor 能挂载并显示初始文本（1.64）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: PEditor(
              initialText: '# 标题\n\n正文一段',
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PEditor), findsOneWidget);
    expect(find.textContaining('标题', findRichText: true), findsWidgets);
  });
}
