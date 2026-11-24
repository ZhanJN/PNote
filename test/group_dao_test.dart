import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// M12 分组的数据层测试：建组、挂任务、移动、两种删除、恢复、折叠同步、迁移。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_group_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  test('建组 + 在组里建任务：父子关系和级数都对', () async {
    final dao = await newDao();
    final g = await dao.addGroup('学习', color: 2);
    final t = await dao.addTask('写作业', parentId: g);
    final list = await dao.visibleTasks();
    expect(list.map((n) => n.id).toList(), [g, t]);
    final group = list.firstWhere((n) => n.id == g);
    final task = list.firstWhere((n) => n.id == t);
    expect(group.isGroup, isTrue);
    expect(group.color, 2);
    expect(task.parentId, g);
    expect(task.isGroup, isFalse);
  });

  test('二级组能建；三级组与「挂到任务下」会被拒绝', () async {
    final dao = await newDao();
    final g = await dao.addGroup('一级');
    final g2 = await dao.addGroup('二级', parentId: g);
    expect((await dao.visibleTasks()).firstWhere((n) => n.id == g2).parentId, g);

    await expectLater(
      dao.addGroup('三级', parentId: g2),
      throwsArgumentError,
      reason: '最多两级',
    );
    final t = await dao.addTask('任务');
    await expectLater(dao.addGroup('组', parentId: t), throwsArgumentError);
  });

  test('moveToParent：只改父节点，标题/创建时间/勾选状态都不动', () async {
    final dao = await newDao();
    final g = await dao.addGroup('组');
    final t = await dao.addTask('任务');
    await dao.setDone(t, true);
    final before = (await dao.visibleTasks()).firstWhere((n) => n.id == t);

    await dao.moveToParent(t, g);
    final after = (await dao.visibleTasks()).firstWhere((n) => n.id == t);
    expect(after.parentId, g);
    expect(after.title, '任务');
    expect(after.done, isTrue);
    expect(after.createdAt, before.createdAt, reason: '移动绝不能清空日期');
    expect(after.order, greaterThan(0), reason: '追加到新同级末尾');
  });

  test('带子组的组不能移进另一个组（会变三级）', () async {
    final dao = await newDao();
    final a = await dao.addGroup('A');
    await dao.addGroup('A1', parentId: a);
    final b = await dao.addGroup('B');
    await expectLater(dao.moveToParent(a, b), throwsArgumentError);
  });

  test('拖拽重排只在同一级里改 order', () async {
    final dao = await newDao();
    final g = await dao.addGroup('组');
    final t1 = await dao.addTask('一', parentId: g);
    final t2 = await dao.addTask('二', parentId: g);
    await dao.reorderSiblings([t2, t1]);
    final kids = (await dao.visibleTasks()).where((n) => n.parentId == g);
    expect(kids.map((n) => n.title).toList(), ['二', '一']);
  });

  test('删组默认不连带：内容上移到上一层，组进回收站', () async {
    final dao = await newDao();
    final g = await dao.addGroup('组');
    final t = await dao.addTask('任务', parentId: g);

    await dao.deleteGroup(g);
    final visible = await dao.visibleTasks();
    expect(visible.map((n) => n.id).toList(), [t]);
    expect(visible.single.parentId, isNull, reason: '内容上移到顶层');
    final deleted = await dao.deletedTasks();
    expect(deleted.map((n) => n.id).toList(), [g]);
  });

  test('删组连带：组和里面的内容一起进回收站', () async {
    final dao = await newDao();
    final g = await dao.addGroup('组');
    final g1 = await dao.addGroup('子组', parentId: g);
    final t = await dao.addTask('任务', parentId: g1);

    await dao.deleteGroup(g, cascade: true);
    expect(await dao.visibleTasks(), isEmpty);
    final deleted = await dao.deletedTasks();
    expect(deleted.map((n) => n.id).toSet(), {g, g1, t});
  });

  test('恢复孤儿组：父组已经不在了 → 自动变成一级，不丢', () async {
    final dao = await newDao();
    final a = await dao.addGroup('A');
    final b = await dao.addGroup('B', parentId: a);
    await dao.deleteGroup(a, cascade: true); // b 也进回收站

    await dao.restoreTask(b);
    final visible = await dao.visibleTasks();
    final restored = visible.firstWhere((n) => n.id == b);
    expect(restored.parentId, isNull, reason: '父组没了就上浮，不能恢复成孤儿');
    expect(restored.isGroup, isTrue);
  });

  test('折叠状态是带版本的可同步字段；组也有颜色版本', () async {
    final dao = await newDao();
    final g = await dao.addGroup('组', color: 3);
    await dao.setGroupCollapsed(g, true);
    await dao.setGroupColor(g, 5);

    final state = await dao.exportState(deviceName: '本机');
    final group = state.tasks[g]!;
    expect(group.kind, TaskKind.group);
    expect(group.collapsed, isTrue);
    expect(group.color, 5);
    expect(group.fields.containsKey(TaskField.collapsed), isTrue);
    expect(group.fields.containsKey(TaskField.color), isTrue);
  });

  test('4 -> 5 迁移：老库补列，老任务一律一级任务、没有组', () async {
    final path = nextPath();
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE tasks (
              id          TEXT PRIMARY KEY NOT NULL,
              title       TEXT NOT NULL DEFAULT '',
              done        INTEGER NOT NULL DEFAULT 0,
              deleted_at  INTEGER,
              created_at  INTEGER NOT NULL,
              order_index REAL NOT NULL DEFAULT 0
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
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
          );
          await db.execute('''
            CREATE TABLE purged (
              id TEXT PRIMARY KEY NOT NULL,
              hlc_ms INTEGER NOT NULL,
              hlc_c INTEGER NOT NULL,
              device_id TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_tasks_visible ON tasks (deleted_at, order_index)',
          );
        },
      ),
    );
    await old.insert('tasks', {
      'id': 'old1',
      'title': '老任务',
      'done': 0,
      'created_at': 1700000000000,
      'order_index': 1700000000000.0,
    });
    await old.insert('field_versions', {
      'task_id': 'old1',
      'field': 'title',
      'hlc_ms': 1700000000000,
      'hlc_c': 0,
      'device_id': 'legacy',
    });
    await old.close();

    final db = await openAppDatabase(overridePath: path);
    opened.add(db);
    final dao = await TaskDao.attach(db);
    final list = await dao.visibleTasks();
    expect(list.single.title, '老任务');
    expect(list.single.isGroup, isFalse, reason: '老数据没有组');
    expect(list.single.parentId, isNull, reason: '老数据一律一级');
    expect(list.single.collapsed, isFalse);
    expect(list.single.color, 0);
  });
}
