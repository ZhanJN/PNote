import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/trash/recycle_bin_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.30：回收站的「全部恢复」与多选（批量恢复 / 批量永久删除）。
///
/// 这里的数据库是真的 sqflite（ffi）：所有碰数据库的 await 都要放进
/// tester.runAsync，否则假时钟下永远等不到；也不要用 pumpAndSettle
/// （见《AI项目移交说明》7.40）。
void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late TaskDao dao;
  late String path;

  setUp(() async {
    path = p.join(
      Directory.systemTemp.path,
      'pnote_recycle_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  /// 给真实数据库的 future 一个机会跑完，再推进几帧。
  ///
  /// 全量测试会并行跑多个文件，机器忙时固定等待可能不够。这里改成
  /// 「反复小步等待 + 检查条件」，条件满足就返回，最坏 30×40 ms。
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
      if (until == null || until()) return;
    }
    await tester.pump();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RecycleBinPage(dao: dao)));
    await settle(tester, until: () => find.text('甲').evaluate().isNotEmpty);
  }

  Future<List<String>> seedTwo(WidgetTester tester) async {
    late List<String> ids;
    await tester.runAsync(() async {
      final a = await dao.addTask('甲');
      final b = await dao.addTask('乙');
      await dao.softDeleteMany([a, b]);
      ids = [a, b];
    });
    await pumpPage(tester);
    return ids;
  }

  Future<Set<String>> visibleIds(WidgetTester tester) async {
    late Set<String> ids;
    await tester.runAsync(() async {
      ids = (await dao.visibleTasks()).map((n) => n.id).toSet();
    });
    return ids;
  }

  Future<int> deletedCount(WidgetTester tester) async {
    late int count;
    await tester.runAsync(() async {
      count = (await dao.deletedTasks()).length;
    });
    return count;
  }

  testWidgets('全部恢复：两条都回到待办，回收站变空', (tester) async {
    final ids = await seedTwo(tester);
    expect(find.text('甲'), findsOneWidget);

    await tester.tap(find.byTooltip('全部恢复'));
    await tester.pump();
    await settle(
      tester,
      until: () => find.text('回收站是空的').evaluate().isNotEmpty,
    );

    expect(find.text('回收站是空的'), findsOneWidget);
    expect(await visibleIds(tester), ids.toSet());
  });

  testWidgets('多选：全选后批量恢复', (tester) async {
    final ids = await seedTwo(tester);
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已选 0 项'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.byTooltip('全选'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('恢复'));
    await tester.pump();
    await settle(
      tester,
      until: () => find.text('回收站是空的').evaluate().isNotEmpty,
    );
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(await visibleIds(tester), ids.toSet());
  });

  testWidgets('多选：批量永久删除要二次确认', (tester) async {
    await seedTwo(tester);
    await tester.tap(find.byTooltip('多选'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('全选'));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, '永久删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('永久删除选中的 2 项？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '永久删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pump();
    await settle(
      tester,
      until: () => find.text('回收站是空的').evaluate().isNotEmpty,
    );
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(await deletedCount(tester), 0);
  });
}
