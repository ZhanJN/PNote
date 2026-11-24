import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/repeat.dart';
import 'package:pnote/ui/tasks/repeat_dialog.dart';

/// 1.35：窄屏下打开重复对话框、切到「每月 / 月末」并保存，不应溢出或报错。
void main() {
  testWidgets('重复对话框在 360 宽屏幕上不溢出，并能存下「每月月末」', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    RepeatChoice? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showRepeatDialog(
                context,
                hasDue: true,
                due: DateTime(2026, 11, 25),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('每月'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('月末'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result?.rule?.freq, RepeatFreq.monthly);
    expect(result?.rule?.monthlyMode, MonthlyMode.lastDay);
  });
}
