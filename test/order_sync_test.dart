import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.39 回归：同步（applyRemote）和导入救回（importBundle）都不能把
/// order_index 冲成 0，否则手动排序会在同步后「回到最底下」。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_ordersync_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
    );
    paths.add(path);
    return path;
  }

  Future<TaskDao> newDao() async {
    final db = await openAppDatabase(overridePath: nextPath());
    opened.add(db);
    return TaskDao.attach(db);
  }

  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    for (final path in paths) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    paths.clear();
  });

  test('自同步（applyRemote）不改变手动顺序', () async {
    final dao = await newDao();
    await dao.addTask('a');
    await dao.addTask('b');
    await dao.addTask('c');
    final before = await dao.visibleTasks();
    await dao.reorderSiblings([
      before[2].id,
      before[0].id,
      before[1].id,
    ]);
    expect(
      (await dao.visibleTasks()).map((t) => t.title),
      ['c', 'a', 'b'],
    );

    await dao.applyRemote(await dao.exportState());

    expect(
      (await dao.visibleTasks()).map((t) => t.title),
      ['c', 'a', 'b'],
    );
  });

  test('导入救回时保留原来的顺序', () async {
    final dao = await newDao();
    await dao.addTask('a');
    await dao.addTask('b');
    final before = await dao.visibleTasks();
    await dao.reorderSiblings([before[1].id, before[0].id]);
    final snapshot = await dao.exportState();
    final b = (await dao.visibleTasks()).first;
    expect(b.title, 'b');

    await dao.purgeTasks([b.id]);
    expect((await dao.visibleTasks()).map((t) => t.title), ['a']);

    await dao.importBundle(snapshot);
    final after = await dao.visibleTasks();
    expect(after.map((t) => t.title), ['b', 'a']);
    expect(after.first.id, b.id);
  });
}
