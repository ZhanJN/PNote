import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 这些测试用真实的 SQLite 文件（临时目录）跑，验证阶段 1 的持久化与合并落库逻辑。
/// 为什么不用 :memory: —— sqflite 会按路径复用同一个内存库，多个测试互相污染。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_test_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
    );
    paths.add(path);
    return path;
  }

  Future<Database> openDb([String? path]) async {
    final db = await openAppDatabase(overridePath: path ?? nextPath());
    opened.add(db);
    return db;
  }

  Future<TaskDao> newDao() async => TaskDao.attach(await openDb());

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

  test('新建任务后可见，标题与创建时间都写对了', () async {
    final dao = await newDao();
    await dao.addTask('买菜');
    final list = await dao.visibleTasks();
    expect(list.length, 1);
    expect(list.first.title, '买菜');
    expect(list.first.done, isFalse);
    expect(list.first.createdAt, greaterThan(0));
  });

  test('空标题被拒绝', () async {
    final dao = await newDao();
    expect(() => dao.addTask('   '), throwsA(isA<ArgumentError>()));
  });

  test('改标题与勾选都会持久化，并且各自产生版本', () async {
    final dao = await newDao();
    final id = await dao.addTask('跑步');
    await dao.renameTask(id, '跑步 3 公里');
    await dao.setDone(id, true);

    final list = await dao.visibleTasks();
    expect(list.single.title, '跑步 3 公里');
    expect(list.single.done, isTrue);

    final state = await dao.exportState();
    final t = state.tasks[id]!;
    expect(t.fields.keys, containsAll([TaskField.title, TaskField.done]));
    expect(t.fields[TaskField.title]!.hlc.deviceId, dao.clock.deviceId);
  });

  test('删除是墓碑：任务从列表消失，但行与版本都还在', () async {
    final dao = await newDao();
    final id = await dao.addTask('买菜');
    await dao.softDelete(id);

    expect(await dao.visibleTasks(), isEmpty);

    final state = await dao.exportState();
    expect(state.tasks[id]!.isDeleted, isTrue);
    expect(state.tasks[id]!.deletedAt, isNotNull);
  });

  test('重启后设备 ID 与时钟不重置（防止版本回退）', () async {
    final path = nextPath();
    final db = await openDb(path);
    final dao1 = await TaskDao.attach(db);
    final id = await dao1.addTask('一');
    final before = dao1.clock.lastMs;

    // 同一个数据库再 attach 一次，模拟重启。
    final dao2 = await TaskDao.attach(db);
    expect(dao2.clock.deviceId, dao1.clock.deviceId);
    expect(dao2.clock.lastMs, before);

    await dao2.renameTask(id, '一（改）');
    final state = await dao2.exportState();
    expect(state.tasks[id]!.title, '一（改）');
  });

  test('收到对端状态后合并落库：新增、改名、删除都生效', () async {
    final a = await newDao();
    final b = await newDao();

    final id = await a.addTask('跑步');
    await b.applyRemote(await a.exportState());
    expect((await b.visibleTasks()).map((t) => t.title), contains('跑步'));

    await a.renameTask(id, '跑步 5 公里');
    await b.applyRemote(await a.exportState());
    expect((await b.visibleTasks()).single.title, '跑步 5 公里');

    await b.softDelete(id);
    await a.applyRemote(await b.exportState());
    expect(await a.visibleTasks(), isEmpty);
  });

  test('关掉数据库再重开，任务与勾选状态都还在（等于关掉 App 再打开）',
      () async {
    final path = nextPath();
    final db1 = await openDb(path);
    final dao1 = await TaskDao.attach(db1);
    await dao1.addTask('买菜');
    final id = await dao1.addTask('跑步');
    await dao1.setDone(id, true);
    await db1.close();

    final db2 = await openDb(path);
    final dao2 = await TaskDao.attach(db2);
    final list = await dao2.visibleTasks();
    expect(list.map((t) => t.title), ['买菜', '跑步']);
    expect(list.last.done, isTrue);
    expect(list.last.createdAt, greaterThan(0));
  });
}
