import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/tasks/tasks_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.36「完成后自动移入回收站」的回归：
/// 数据层只挑未删除的完成任务；界面层勾完成 → 消失 + 撤销 → 回来且未完成。
void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late TaskDao dao;
  late String path;

  setUp(() async {
    path = p.join(
      Directory.systemTemp.path,
      'pnote_auto_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  /// FakeAsync 里真实 sqflite 的 I/O 不会自己完成，必须 runAsync 放出去。
  Future<void> settleUntil(WidgetTester tester, bool Function() done,
      {int tries = 15}) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump();
      if (done()) return;
    }
  }

  test('completedTaskIds 只收未删除的完成任务，不含组', () async {
    final a = await dao.addTask('甲');
    final b = await dao.addTask('乙');
    await dao.addGroup('组');
    await dao.setDone(a, true);

    expect(await dao.completedTaskIds(), [a]);

    await dao.softDeleteMany([a]);
    expect(await dao.completedTaskIds(), isEmpty);
    expect(b, isNotEmpty); // 乙没完成，本来就不该在里面
  });

  testWidgets('开启自动归档：勾完成即进回收站，撤销后回来且未完成', (tester) async {
    final id = (await tester.runAsync(() => dao.addTask('写作业')))!;
    await tester.runAsync(() => dao.writeSetting('auto_delete_done', '1'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TasksView(dao: dao, onCountChanged: (_) {}),
        ),
      ),
    );
    await settleUntil(tester, () => find.text('写作业').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).first);
    await settleUntil(tester, () => find.text('写作业').evaluate().isEmpty);
    await tester.pumpAndSettle();

    expect(find.text('已完成，移入回收站'), findsOneWidget);
    final deleted = (await tester.runAsync(() => dao.deletedTasks()))!;
    expect(deleted.map((t) => t.id), contains(id));

    await tester.tap(find.text('撤销'));
    await settleUntil(tester, () => find.text('写作业').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    final visible = (await tester.runAsync(() => dao.visibleTasks()))!;
    expect(visible.firstWhere((n) => n.id == id).done, isFalse);
  });
}
