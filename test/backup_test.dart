import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/backup.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 导出 / 导入：文件格式往返、坏文件被拒、导入走合并语义（不冲掉新数据）。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_backup_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  test('导出的内容能被原样读回来（含墓碑与永久删除记录）', () async {
    final dao = await newDao();
    final keep = await dao.addTask('留着');
    final gone = await dao.addTask('删掉');
    await dao.softDelete(gone);
    final purged = await dao.addTask('彻底删掉');
    await dao.softDelete(purged);
    await dao.purgeTasks([purged]);

    final state = await dao.exportState(deviceName: '电脑');
    final restored = decodeBundle(encodeBundle(state, exportedAt: DateTime(2026)));

    expect(restored.deviceId, state.deviceId);
    expect(restored.deviceName, '电脑');
    expect(restored.tasks.keys.toSet(), state.tasks.keys.toSet());
    expect(restored.tasks[keep]!.title, '留着');
    expect(restored.tasks[gone]!.isDeleted, isTrue, reason: '墓碑要一起备份');
    expect(restored.purged, contains(purged));
    expect(restored.tasks.containsKey(purged), isFalse);
  });

  test('不是 JSON / 不是我们的文件 / 结构不对，都给出可读的中文错误', () async {
    expect(
      () => decodeBundle('这不是 json'),
      throwsA(isA<BackupException>().having(
        (e) => e.message,
        'message',
        contains('不是合法的 JSON'),
      )),
    );
    expect(
      () => decodeBundle(jsonEncode({'proto': 'something-else'})),
      throwsA(isA<BackupException>().having(
        (e) => e.message,
        'message',
        contains('不是 PNote 的备份文件'),
      )),
    );
    expect(
      () => decodeBundle(jsonEncode({
        'proto': kBundleProto,
        'deviceId': 'dev-1',
        'tasks': 'oops',
      })),
      throwsA(isA<BackupException>()),
    );
  });

  test('导入是合并：本机新加的任务不会被旧备份冲掉', () async {
    final source = await newDao();
    await source.addTask('备份里的任务');
    final bundle = encodeBundle(await source.exportState());

    final target = await newDao();
    await target.addTask('备份之后新加的');
    await target.applyRemote(decodeBundle(bundle));

    final titles = (await target.visibleTasks()).map((t) => t.title).toSet();
    expect(titles, containsAll(<String>['备份里的任务', '备份之后新加的']));
    // 幂等：再导入一次什么都不变。
    final stats = await target.applyRemote(decodeBundle(bundle));
    expect(stats.isNoop, isTrue);
    expect((await target.visibleTasks()).length, 2);
  });

  test('导入之后继续同步，两台设备状态一致', () async {
    final source = await newDao();
    await source.addTask('甲');
    await source.addTask('乙');
    final bundle = encodeBundle(await source.exportState());

    final phone = await newDao();
    await phone.applyRemote(decodeBundle(bundle));

    final pc = await newDao();
    await pc.applyRemote(await phone.exportState());
    expect(
      (await pc.visibleTasks()).map((t) => t.title).toSet(),
      <String>{'甲', '乙'},
    );
  });

  test('建议文件名带时间戳，且以 .json 结尾', () {
    final name = suggestedBackupName(now: DateTime(2026, 11, 22, 14, 30, 5));
    expect(name, 'pnote-backup-20261122-143005.json');
  });

  // 缺陷回归：用户「删光之后导入备份」时提示「没有发现新内容」。
  // 根因是墓碑（deleted_at）也是带版本的字段，而且比备份里的标题/勾选更晚，
  // 纯合并会一条都不改 —— 于是导入看起来什么都没做。
  test('删光之后导入备份：任务会被恢复，而不是「没有新内容」', () async {
    final dao = await newDao();
    await dao.addTask('买菜');
    await dao.addTask('跑步');
    final bundle = encodeBundle(await dao.exportState());

    for (final task in await dao.visibleTasks()) {
      await dao.softDelete(task.id);
    }
    expect(await dao.visibleTasks(), isEmpty);

    final outcome = await dao.importBundle(decodeBundle(bundle));

    expect(outcome.isNoop, isFalse);
    expect(outcome.restored, 2);
    expect(
      (await dao.visibleTasks()).map((t) => t.title).toSet(),
      <String>{'买菜', '跑步'},
    );
  });

  test('同一份备份连导两次：第二次是「没有新内容」（幂等）', () async {
    final dao = await newDao();
    await dao.addTask('买菜');
    final bundle = encodeBundle(await dao.exportState());

    for (final task in await dao.visibleTasks()) {
      await dao.softDelete(task.id);
    }
    await dao.importBundle(decodeBundle(bundle));

    final second = await dao.importBundle(decodeBundle(bundle));
    expect(second.isNoop, isTrue);
    expect((await dao.visibleTasks()).length, 1);
  });

  // 1.11 起：永久删除是「带版本的事件」，导入时用更新的版本把它压过，
  // 所以清空回收站之后导入备份仍然能救回来（用户的明确要求）。
  test('永久删除过的任务，导入备份仍然能救回来', () async {
    final dao = await newDao();
    await dao.addTask('买菜');
    final bundle = encodeBundle(await dao.exportState());

    final task = (await dao.visibleTasks()).single;
    await dao.softDelete(task.id);
    await dao.purgeTasks(<String>[task.id]);
    expect(await dao.visibleTasks(), isEmpty);
    expect((await dao.exportState()).purged, contains(task.id));

    final outcome = await dao.importBundle(decodeBundle(bundle));
    expect(outcome.revived, 1);
    expect(
      (await dao.visibleTasks()).map((t) => t.title).toList(),
      <String>['买菜'],
    );
    // 清除记录作废了，否则下一轮同步又会把它删掉。
    expect((await dao.exportState()).purged, isEmpty);
  });

  test('备份里就是删除状态的任务，导入不会把它复活', () async {
    final source = await newDao();
    await source.addTask('留着');
    await source.addTask('删掉');
    final keep = (await source.visibleTasks()).firstWhere((t) => t.title == '留着');
    final gone = (await source.visibleTasks()).firstWhere((t) => t.title == '删掉');
    await source.softDelete(gone.id);
    final bundle = encodeBundle(await source.exportState());

    final target = await newDao();
    await target.importBundle(decodeBundle(bundle));

    final titles = (await target.visibleTasks()).map((t) => t.title).toList();
    expect(titles, <String>['留着']);
    expect(keep.id, isNotEmpty);
  });
}
