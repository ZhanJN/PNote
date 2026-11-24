import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/tasks/tasks_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 回归测试：改标题对话框在「提交 + 退场动画 + 卡片被销毁」这条时序上是否安全。
///
/// 背景（2026-11-22 用户在真机上遇到的崩溃）：
///   'package:flutter/src/widgets/framework.dart': Failed assertion:
///   line 6286 pos 12: '_dependents.isEmpty': is not true.
/// 成因：旧实现在 showDialog 的 Future 返回后立即 controller.dispose()，
/// 而对话框的退场动画仍在跑、TextField 还挂在树上，销毁顺序被打乱，
/// 连带 rendering/object.dart 的 'attached' 断言一起炸。
/// 现在改成 RenameDialog（表单项不再持有 controller），本测试守住这条时序。
///
/// 注意：testWidgets 跑在 FakeAsync 里，真实的 sqflite 文件 I/O 永远不会自己
/// 完成，所以凡是「等数据库」的地方都必须用 tester.runAsync 放出去。
void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late TaskDao dao;
  late String path;

  setUp(() async {
    path = p.join(
      Directory.systemTemp.path,
      'pnote_ui_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  /// 长内容 + 各种符号，正是用户复现时输入的形态。
  const weirdTitle = '数学作业 ∑∫√ ≈ 100% 【重要】 <b>&amp;</b> '
      '这是一个非常非常长的标题用来触发换行与输入法组词'
      '“引号”‘单引号’#@\$^&*()_+-=[]{}|;:,.<>/?~';

  /// 把控制权交给真实事件循环一小会儿，让 sqflite 的 Future 有机会完成。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }

  /// 1.20 起行尾只有一个「更多」按钮：先点它，再点菜单里的「改标题」。
  Future<void> openRename(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('改标题').last);
    await tester.pumpAndSettle();
  }
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TasksView(dao: dao))));
    await settleIo(tester); // 等 initState 里的 _reload() 读库完成
    await tester.pumpAndSettle();
  }

  Future<List<TaskState>> visible(WidgetTester tester) async =>
      (await tester.runAsync(() => dao.visibleTasks()))!;

  testWidgets('点开改标题 → 输入长文本与符号 → 回车提交：正常改名且不崩',
      (tester) async {
    await tester.runAsync(() => dao.addTask('跑步'));
    await pumpPage(tester);
    expect(find.text('跑步'), findsOneWidget);
    // 行内点击 = 勾选；改标题要点行尾的铅笔按钮（测试同样要点按钮）。

    await openRename(tester);

    await tester.enterText(find.byType(TextFormField), weirdTitle);
    await tester.testTextInput.receiveAction(TextInputAction.done);

    // 只推进到退场动画中间：旧实现就是在这个窗口里 dispose controller 的。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect((await visible(tester)).single.title, weirdTitle);
  });

  testWidgets('提交后立刻销毁整页：不出现 _dependents.isEmpty 断言',
      (tester) async {
    await tester.runAsync(() => dao.addTask('写作业'));
    await pumpPage(tester);

    await openRename(tester);
    await tester.enterText(find.byType(TextFormField), weirdTitle);
    await tester.tap(find.text('保存'));

    // 不等动画结束，直接把整棵树换掉 —— 最容易暴露销毁顺序问题的时序。
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    // 页面没了，但弹窗 pop 之后触发的改名写库还在飞：放它跑完，
    // 否则测试结束时数据库里留着未提交的事务，tearDown 的 close() 会卡死。
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('点取消不改动数据', (tester) async {
    await tester.runAsync(() => dao.addTask('买菜'));
    await pumpPage(tester);

    await openRename(tester);
    await tester.enterText(find.byType(TextFormField), '买菜（改过）');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(tester.takeException(), isNull);
    expect((await visible(tester)).single.title, '买菜');
  });
}
