import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/backup.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/merge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 「永久删除」是一条**带版本的事件**（1.11）：
///   - 清除比任务新 → 任务被删掉，两端一致；
///   - 任务比清除新（导入备份救回来）→ 任务胜、清除记录作废，两端一致。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_purgever_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  SyncState stateWith({
    required String deviceId,
    required String taskId,
    required int fieldMs,
    Map<String, Hlc> purged = const {},
  }) {
    return SyncState(
      deviceId: deviceId,
      deviceName: deviceId,
      tasks: {
        taskId: TaskState(
          id: taskId,
          createdAt: 1000,
          fields: {
            TaskField.title: FieldValue('任务', Hlc(fieldMs, 0, deviceId)),
            TaskField.done: FieldValue(0, Hlc(fieldMs, 0, deviceId)),
          },
        ),
      },
      purged: purged,
    );
  }

  test('清除比任务新：任务被清除，清除记录留下', () {
    final task = stateWith(deviceId: 'a', taskId: 't1', fieldMs: 1000);
    final other = SyncState(
      deviceId: 'b',
      deviceName: 'b',
      tasks: {},
      purged: {'t1': const Hlc(2000, 0, 'b')},
    );

    final out = mergeStates(task, other);
    expect(out.merged.tasks.containsKey('t1'), isFalse);
    expect(out.merged.purged['t1']?.ms, 2000);
    expect(out.stats.deletedTasks, 1);
  });

  test('任务比清除新（恢复）：任务胜，清除记录作废', () {
    final restored = stateWith(deviceId: 'a', taskId: 't1', fieldMs: 5000);
    final other = SyncState(
      deviceId: 'b',
      deviceName: 'b',
      tasks: {},
      purged: {'t1': const Hlc(3000, 0, 'b')},
    );

    final out = mergeStates(restored, other);
    expect(out.merged.tasks.containsKey('t1'), isTrue);
    expect(out.merged.purged, isEmpty, reason: '清除被更新的任务压过，必须作废');
  });

  test('合并可交换：谁先谁后结果一样', () {
    final restored = stateWith(deviceId: 'a', taskId: 't1', fieldMs: 5000);
    final purger = SyncState(
      deviceId: 'b',
      deviceName: 'b',
      tasks: {},
      purged: {'t1': const Hlc(3000, 0, 'b')},
    );

    final ab = mergeStates(restored, purger).merged;
    final ba = mergeStates(purger, restored).merged;
    expect(ab.tasks.keys.toSet(), ba.tasks.keys.toSet());
    expect(ab.purged.keys.toSet(), ba.purged.keys.toSet());
  });

  test('一台永久删除、另一台导入备份救回：同步后两端都复活', () async {
    final a = await newDao();
    final b = await newDao();

    final id = await a.addTask('买菜');
    final backup = encodeBundle(await a.exportState());

    // 先让 b 也拥有这条任务。
    await b.applyRemote(await a.exportState());
    expect((await b.visibleTasks()).length, 1);

    // a 彻底删掉它，并把「清除记录」传给 b。
    await a.softDelete(id);
    await a.purgeTasks([id]);
    await b.applyRemote(await a.exportState());
    expect(await a.visibleTasks(), isEmpty);
    expect(await b.visibleTasks(), isEmpty);

    // a 用备份把任务救回来（新版本号压过清除记录）。
    final outcome = await a.importBundle(decodeBundle(backup));
    expect(outcome.revived, 1);
    expect((await a.visibleTasks()).length, 1);

    // 双向同步之后，b 那边也应该复活。
    await b.applyRemote(await a.exportState());
    await a.applyRemote(await b.exportState());
    expect((await a.visibleTasks()).map((t) => t.title).toList(), ['买菜']);
    expect((await b.visibleTasks()).map((t) => t.title).toList(), ['买菜']);
    expect((await a.exportState()).purged, isEmpty);
    expect((await b.exportState()).purged, isEmpty);
  });
}
