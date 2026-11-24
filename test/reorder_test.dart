import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.20 拖拽排序的数据层测试：顺序值怎么生成、怎么重排、怎么参与同步。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_order_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  List<String> titles(List<TaskState> list) => [for (final t in list) t.title];

  test('新任务排到最后，顺序值按步长递增', () async {
    final dao = await newDao();
    await dao.addTask('A');
    await dao.addTask('B');
    await dao.addTask('C');
    final list = await dao.visibleTasks();
    expect(titles(list), ['A', 'B', 'C']);
    expect(list[1].order - list[0].order, kOrderStep);
    expect(list[2].order - list[1].order, kOrderStep);
  });

  test('拖到最前面 / 最后面，列表顺序立刻变', () async {
    final dao = await newDao();
    for (final t in ['A', 'B', 'C']) {
      await dao.addTask(t);
    }
    var list = await dao.visibleTasks();

    await dao.moveTaskToIndex(list[2].id, 0);
    list = await dao.visibleTasks();
    expect(titles(list), ['C', 'A', 'B']);

    await dao.moveTaskToIndex(list[0].id, 2);
    list = await dao.visibleTasks();
    expect(titles(list), ['A', 'B', 'C']);
  });

  test('插到中间：位置越界会被夹住，顺序不重复', () async {
    final dao = await newDao();
    for (final t in ['A', 'B', 'C', 'D']) {
      await dao.addTask(t);
    }
    var list = await dao.visibleTasks();
    await dao.moveTaskToIndex(list[3].id, 99); // 越界 → 夹到最后（仍是最后）
    list = await dao.visibleTasks();
    expect(titles(list), ['A', 'B', 'C', 'D']);

    await dao.moveTaskToIndex(list[3].id, 1);
    list = await dao.visibleTasks();
    expect(titles(list), ['A', 'D', 'B', 'C']);
    final orders = [for (final t in list) t.order];
    expect(orders.toSet().length, orders.length, reason: '顺序值不应重复');
  });

  test('顺序是带版本的可合并字段：导出状态里能看到 order', () async {
    final dao = await newDao();
    await dao.addTask('A');
    final state = await dao.exportState(deviceName: '本机');
    final task = state.tasks.values.single;
    expect(task.fields.containsKey(TaskField.order), isTrue);
    expect(task.order, greaterThan(0));
  });

  test('3 -> 4 迁移：老库升级后顺序值等于 created_at，且补了 order 版本行', () async {
    final path = nextPath();
    // 手工造一个 v3 结构的库（没有 order_index 列）。
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE tasks (
              id         TEXT PRIMARY KEY NOT NULL,
              title      TEXT NOT NULL DEFAULT '',
              done       INTEGER NOT NULL DEFAULT 0,
              deleted_at INTEGER,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE field_versions (
              task_id   TEXT NOT NULL,
              field     TEXT NOT NULL,
              hlc_ms    INTEGER NOT NULL,
              hlc_c     INTEGER NOT NULL,
              device_id TEXT NOT NULL,
              PRIMARY KEY (task_id, field)
            )
          ''');
          await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
          await db.execute('''
            CREATE TABLE purged (
              id TEXT PRIMARY KEY NOT NULL,
              hlc_ms INTEGER NOT NULL,
              hlc_c INTEGER NOT NULL,
              device_id TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await old.insert('tasks', {
      'id': 't1',
      'title': '老任务',
      'done': 0,
      'created_at': 1700000000000,
    });
    await old.insert('field_versions', {
      'task_id': 't1',
      'field': 'title',
      'hlc_ms': 1700000000000,
      'hlc_c': 0,
      'device_id': 'legacy',
    });
    await old.close();

    // 用当前版本打开 → 触发 3 -> 4 迁移。
    final db = await openAppDatabase(overridePath: path);
    opened.add(db);
    final dao = await TaskDao.attach(db);
    final list = await dao.visibleTasks();
    expect(list.single.title, '老任务');
    expect(list.single.order, 1700000000000);
    final versions = await db.query(
      'field_versions',
      where: 'task_id = ? AND field = ?',
      whereArgs: ['t1', 'order'],
    );
    expect(versions.length, 1, reason: '迁移要补 order 的版本行');
    expect(versions.single['device_id'], 'legacy');
  });
}
