import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/ui/settings/account_dialog.dart';

/// 1.52：从「公开同步」切回来时，不能把原来的账号名弄丢。
///
/// 打开对话框时应预填上次的私有账号名；点「保存」就切回去。
void main() {
  Future<void> open(
    WidgetTester tester, {
    required String current,
    required String lastPrivate,
    required void Function(String?) onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(await showAccountDialog(
                  context,
                  current: current,
                  lastPrivate: lastPrivate,
                ));
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('当前是公开同步：预填上次的私有名，直接保存就切回去', (tester) async {
    String? result;
    await open(
      tester,
      current: kPublicAccount,
      lastPrivate: '学习小组',
      onResult: (v) => result = v,
    );

    expect(find.widgetWithText(TextField, '学习小组'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(result, '学习小组');
  });

  testWidgets('点「公开同步」会出风险提示，保存的是公开同步', (tester) async {
    String? result;
    await open(
      tester,
      current: '学习小组',
      lastPrivate: '学习小组',
      onResult: (v) => result = v,
    );

    await tester.tap(find.text(kPublicAccount));
    await tester.pump();
    expect(find.textContaining('任何也选了这个名字'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(result, kPublicAccount);
  });
}
