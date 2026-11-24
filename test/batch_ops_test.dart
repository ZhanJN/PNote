import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.29 多选批量操作的数据层测试：批量删除、批量移入、同层上移/下移。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_batch_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  Future<List<String>> ids(TaskDao dao) async =>
      (await dao.visibleTasks()).map((n) => n.id).toList();

  test('批量删除任务：一条事务里全部写墓碑', () async {
    final dao = await newDao();
    final a = await dao.addTask('A');
    final b = await dao.addTask('B');
    final c = await dao.addTask('C');
    await dao.softDeleteMany([a, c]);
    expect(await ids(dao), [b]);
    final gone = (await dao.deletedTasks()).map((t) => t.id).toSet();
    expect(gone, containsAll(<String>[a, c]));
  });

  test('批量删除组（不连带）：内容上移到组原来的位置，组进回收站', () async {
    final dao = await newDao();
    final top = await dao.addTask('顶层任务');
    final g = await dao.addGroup('学习');
    final t1 = await dao.addTask('数学', parentId: g);
    final t2 = await dao.addTask('物理', parentId: g);
    await dao.softDeleteMany([g]);
    final list = await dao.visibleTasks();
    expect(list.map((n) => n.id).toSet(), {top, t1, t2});
    expect(list.firstWhere((n) => n.id == t1).parentId, isNull);
    expect(list.firstWhere((n) => n.id == t2).parentId, isNull);
    expect((await dao.deletedTasks()).map((t) => t.id), contains(g));
  });

  test('批量删除「组 + 组内任务」：两条路都进回收站，不留孤儿', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习');
    final t = await dao.addTask('数学', parentId: g);
    await dao.softDeleteMany([g, t]);
    expect(await dao.visibleTasks(), isEmpty);
    final gone = (await dao.deletedTasks()).map((t) => t.id).toSet();
    expect(gone, containsAll(<String>[g, t]));
  });

  test('批量移入：同层选中按顺序追加到目标组末尾', () async {
    final dao = await newDao();
    final a = await dao.addTask('A');
    final b = await dao.addTask('B');
    final g = await dao.addGroup('学习');
    await dao.moveManyToParent([a, b], g);
    final list = await dao.visibleTasks();
    expect(list.map((n) => n.id).toSet(), {g, a, b});
    expect(list.firstWhere((n) => n.id == a).parentId, g);
    expect(list.firstWhere((n) => n.id == b).parentId, g);
    expect((await dao.visibleTasks()).firstWhere((n) => n.id == a).order,
        lessThan(list.firstWhere((n) => n.id == b).order));
  });

  test('批量移入跨层：拒绝并给中文原因', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习');
    final top = await dao.addTask('顶层');
    final inner = await dao.addTask('组内', parentId: g);
    await expectLater(
      dao.moveManyToParent([top, inner], g),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('同一个层次'),
        ),
      ),
    );
  });

  test('批量上移：整块挪一格，选中项之间保持相对顺序', () async {
    final dao = await newDao();
    final a = await dao.addTask('A');
    final b = await dao.addTask('B');
    final c = await dao.addTask('C');
    final d = await dao.addTask('D');
    await dao.nudgeMany([c, d], -1);
    expect(await ids(dao), [a, c, d, b]);
  });

  test('批量下移：从下往上换，不会来回打转', () async {
    final dao = await newDao();
    final a = await dao.addTask('A');
    final b = await dao.addTask('B');
    final c = await dao.addTask('C');
    final d = await dao.addTask('D');
    await dao.nudgeMany([a, b], 1);
    expect(await ids(dao), [c, a, b, d]);
  });

  test('批量上移跨层：拒绝', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习');
    final top = await dao.addTask('顶层');
    final inner = await dao.addTask('组内', parentId: g);
    await expectLater(
      dao.nudgeMany([top, inner], -1),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('批量恢复组 + 组内任务：先父后子，子任务还挂在原组下', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习');
    final t = await dao.addTask('数学', parentId: g);
    // 先删任务、再删组：删组时可见列表里没有子任务，所以不会把它上移，
    // 回收站里就同时留着「删掉的组」和「还指着它的子任务」。
    await dao.softDeleteMany([t]);
    await dao.softDeleteMany([g]);
    expect(await dao.visibleTasks(), isEmpty);

    await dao.restoreMany([t, g]);
    final list = await dao.visibleTasks();
    expect(list.map((n) => n.id).toSet(), {g, t});
    expect(list.firstWhere((n) => n.id == t).parentId, g);
    expect((await dao.deletedTasks()), isEmpty);
  });

  test('批量恢复时父组不在本批（仍是墓碑）：子任务退回顶层', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习');
    final t = await dao.addTask('数学', parentId: g);
    await dao.softDeleteMany([g, t]);

    await dao.restoreMany([t]);
    final list = await dao.visibleTasks();
    expect(list.map((n) => n.id), [t]);
    expect(list.single.parentId, isNull);
    expect((await dao.deletedTasks()).map((n) => n.id), contains(g));
  });

  test('批量恢复忽略不在回收站的 id', () async {
    final dao = await newDao();
    final alive = await dao.addTask('活着');
    final gone = await dao.addTask('删了');
    await dao.softDeleteMany([gone]);

    await dao.restoreMany([alive, gone, 'not-exist']);
    expect((await dao.visibleTasks()).map((n) => n.id).toSet(), {alive, gone});
  });
}
