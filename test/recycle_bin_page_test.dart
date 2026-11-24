import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/trash/recycle_bin_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 回收站页的界面级回归：渲染、恢复、永久删除的确认流程。
///
/// 数据层语义由 test/recycle_bin_test.dart 覆盖；这里只守「点下去会不会崩、
/// 确认框有没有真的拦住、点完列表有没有刷新」。
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
      'pnote_bin_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  /// 让真实的 sqflite I/O 跑完：FakeAsync 里不会自己推进，必须 runAsync。
  ///
  /// 250ms 而不是 120ms：全量测试并行跑 79 条时机器负载高，120ms 偶发不够，
  /// 会出现「单独跑过、全量跑失败」的假失败。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }

  /// 等某个界面变化真的出现。
  ///
  /// 并行跑全量测试时机器负载高，固定等一次 250ms 偶发不够（表现为
  /// 「单跑过、全量失败」）。这里改成有界重试：最多等 12 次，每次 250ms，
  /// 也就是最坏 3 秒；一旦出现就立刻返回，不会拖慢正常情况。
  Future<void> settleUntilFound(WidgetTester tester, Finder finder,
      {int tries = 12}) async {
    for (var i = 0; i < tries; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await settleIo(tester);
    }
  }

  Future<void> pumpBin(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RecycleBinPage(dao: dao)));
    await settleIo(tester); // 等 initState 里的 _reload() 读库完成
    await tester.pumpAndSettle();
  }

  Future<List<TaskState>> deleted(WidgetTester tester) async =>
      (await tester.runAsync(() => dao.deletedTasks()))!;

  testWidgets('空回收站只有标题与空态，没有多余说明文字', (tester) async {
    await pumpBin(tester);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('回收站是空的'), findsOneWidget);
    // 用户要求删掉那段说明文字（1.11），这里锁住它不要偷偷回来。
    expect(find.textContaining('不会自动清理'), findsNothing);
    // 空的时候「清空回收站」是禁用的。
    // 注意：byTooltip 命中的是 Tooltip 包装层，不是 IconButton 本身，
    // 所以要先找到按钮再取 widget。
    final clear = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.delete_sweep_outlined),
        matching: find.byType(IconButton),
      ),
    );
    expect(clear.onPressed, isNull);
  });

  testWidgets('删除的两条按删除时间倒序显示，且标题可读', (tester) async {
    await tester.runAsync(() async {
      await dao.addTask('买菜');
      await dao.addTask('跑步');
      final all = await dao.visibleTasks();
      await dao.softDelete(all.firstWhere((t) => t.title == '买菜').id);
      await dao.softDelete(all.firstWhere((t) => t.title == '跑步').id);
    });
    await pumpBin(tester);

    expect(find.text('买菜'), findsOneWidget);
    expect(find.text('跑步'), findsOneWidget);
    expect(find.textContaining('删除于'), findsNWidgets(2));
    expect(find.text('回收站是空的'), findsNothing);
  });

  testWidgets('点「恢复」后列表刷新，任务回到可见列表', (tester) async {
    await tester.runAsync(() async {
      await dao.addTask('写作业');
      final t = await dao.visibleTasks();
      await dao.softDelete(t.single.id);
    });
    await pumpBin(tester);
    expect(find.text('写作业'), findsOneWidget);

    await tester.tap(find.byTooltip('恢复').first);
    await settleIo(tester);
    await tester.pumpAndSettle();
    await settleUntilFound(tester, find.text('回收站是空的'));

    expect(tester.takeException(), isNull);
    expect(await deleted(tester), isEmpty);
    final visible = (await tester.runAsync(() => dao.visibleTasks()))!;
    expect(visible.single.title, '写作业');
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('永久删除要先确认；点「取消」不会删任何东西', (tester) async {
    await tester.runAsync(() async {
      await dao.addTask('买菜');
      final t = await dao.visibleTasks();
      await dao.softDelete(t.single.id);
    });
    await pumpBin(tester);

    await tester.tap(find.byTooltip('永久删除').first);
    await tester.pumpAndSettle();
    expect(find.text('永久删除？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(tester.takeException(), isNull);
    expect(await deleted(tester), hasLength(1));
  });

  testWidgets('确认永久删除后真正消失，且不再可恢复', (tester) async {
    await tester.runAsync(() async {
      await dao.addTask('买菜');
      final t = await dao.visibleTasks();
      await dao.softDelete(t.single.id);
    });
    await pumpBin(tester);

    await tester.tap(find.byTooltip('永久删除').first);
    await tester.pumpAndSettle();
    // 对话框里的确认按钮文案也是「永久删除」，此时页面上有两个同名 tooltip/文字，
    // 用 FilledButton 定位那个确认按钮。
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '永久删除'),
      ),
    );
    await settleIo(tester);
    await tester.pumpAndSettle();
    await settleUntilFound(tester, find.text('回收站是空的'));

    expect(tester.takeException(), isNull);
    expect(await deleted(tester), isEmpty);
    final state = (await tester.runAsync(() => dao.exportState()))!;
    expect(state.purged, hasLength(1)); // 进了 purged，同步后才能让对方也删
    expect(find.text('回收站是空的'), findsOneWidget);
  });
}
