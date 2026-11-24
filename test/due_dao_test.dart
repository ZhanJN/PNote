import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/payload.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.31 时间字段的数据层测试：落库编码、清除、同步往返、LWW。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_due_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  test('setDue 落库：全天只存日期，精确存带偏移的时刻', () async {
    final dao = await newDao();
    final id = await dao.addTask('交作业');

    await dao.setDue(
      id,
      at: DateTime(2026, 11, 25),
      precision: DuePrecision.date,
    );
    var tasks = await dao.visibleTasks();
    expect(tasks.single.dueValue, '2026-11-25');
    expect(tasks.single.duePrecision, DuePrecision.date.code);

    await dao.setDue(
      id,
      at: DateTime(2026, 11, 25, 18, 30),
      precision: DuePrecision.dateTime,
    );
    tasks = await dao.visibleTasks();
    expect(tasks.single.dueValue, startsWith('2026-11-25T18:30'));
    expect(tasks.single.duePrecision, DuePrecision.dateTime.code);
    expect(dueOf(tasks.single), DateTime(2026, 11, 25, 18, 30));
  });

  test('clearDue 清空时间，任务本身还在', () async {
    final dao = await newDao();
    final id = await dao.addTask('买菜');
    await dao.setDue(
      id,
      at: DateTime(2026, 12, 1),
      precision: DuePrecision.date,
    );
    await dao.clearDue(id);

    final tasks = await dao.visibleTasks();
    expect(tasks.single.title, '买菜');
    expect(tasks.single.dueValue, isNull);
    expect(tasks.single.duePrecision, DuePrecision.none.code);
  });

  test('时间字段随 pnote-sync/7 往返', () async {
    final a = await newDao();
    final b = await newDao();
    final id = await a.addTask('复习数学');
    await a.setDue(
      id,
      at: DateTime(2026, 11, 26, 19, 0),
      precision: DuePrecision.dateTime,
    );
    await a.setRemindLead(id, 15);
    await a.setRepeatRule(id, 'weekly');

    final wire = encodeState(await a.exportState(deviceName: 'A'));
    final decoded = decodeState(wire);
    expect(wire, contains('"proto":"$kProto"'));
    expect(kProto, 'pnote-sync/7');

    await b.applyRemote(decoded);
    final tasks = await b.visibleTasks();
    expect(tasks.single.dueValue, startsWith('2026-11-26T19:00'));
    expect(tasks.single.duePrecision, DuePrecision.dateTime.code);
    expect(tasks.single.remindLead, 15);
    expect(tasks.single.repeatRule, 'weekly');
  });

  test('时间的 LWW：后写入的一方胜', () async {
    final a = await newDao();
    final b = await newDao();
    final id = await a.addTask('同步测试');
    await b.applyRemote(decodeState(encodeState(await a.exportState())));

    await a.setDue(
      id,
      at: DateTime(2026, 11, 27),
      precision: DuePrecision.date,
    );
    await b.setDue(
      id,
      at: DateTime(2026, 11, 28),
      precision: DuePrecision.date,
    );

    await a.applyRemote(decodeState(encodeState(await b.exportState())));
    final tasks = await a.visibleTasks();
    expect(tasks.single.dueValue, '2026-11-28');
  });
}
