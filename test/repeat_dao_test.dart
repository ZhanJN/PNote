import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/repeat.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/payload.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.34 重复任务的数据层测试：完成生成下一期、结束条件、幂等、同步。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_repeat_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
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

  RepeatRule daily({int generated = 0, RepeatEndType end = RepeatEndType.never,
      int endCount = 1, String? endUntil}) =>
      RepeatRule(
        freq: RepeatFreq.daily,
        end: end,
        endCount: endCount,
        endUntil: endUntil,
        generated: generated,
      );

  test('勾选完成会生成下一期：同一 series、时间往后一天、规则跟着走', () async {
    final dao = await newDao();
    final id = await dao.addTask('背单词');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(id, daily());

    final nextId = await dao.completeRepeating(id);
    expect(nextId, isNotNull);

    final tasks = await dao.visibleTasks();
    expect(tasks.length, 2);
    final old = tasks.firstWhere((t) => t.id == id);
    final next = tasks.firstWhere((t) => t.id == nextId);
    expect(old.done, isTrue);
    expect(next.done, isFalse);
    expect(next.title, '背单词');
    expect(next.dueValue, '2026-11-25');
    expect(next.seriesId, id); // 第一次设置重复时 series 就是它自己
    expect(next.repeatRule, isNotNull);
    expect(parseRepeatRule(next.repeatRule)!.generated, 1);
  });

  test('下一期留在原来的组里', () async {
    final dao = await newDao();
    final gid = await dao.addGroup('学习');
    final id = await dao.addTask('写作业', parentId: gid);
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(id, daily());

    await dao.completeRepeating(id);
    final tasks = await dao.visibleTasks();
    final next = tasks.firstWhere((t) => !t.isGroup && !t.done);
    expect(next.parentId, gid);
  });

  test('取消完成再勾一次：不会生成第二条一样的下一期', () async {
    final dao = await newDao();
    final id = await dao.addTask('跑步');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(id, daily());

    await dao.setDone(id, true);
    await dao.setDone(id, false);
    await dao.setDone(id, true);

    final tasks = await dao.visibleTasks();
    final unfinished = tasks.where((t) => !t.done).toList();
    expect(unfinished.length, 1);
  });

  test('次数结束：共 3 期，第 3 期完成后不再生成', () async {
    final dao = await newDao();
    var id = await dao.addTask('喝水');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(
      id,
      daily(end: RepeatEndType.count, endCount: 3),
    );

    id = (await dao.completeRepeating(id))!;
    id = (await dao.completeRepeating(id))!;
    final last = await dao.completeRepeating(id);
    expect(last, isNull);

    final tasks = await dao.visibleTasks();
    expect(tasks.length, 3);
    expect(tasks.where((t) => !t.done), isEmpty);
  });

  test('到某天结束：下一期超过截止日就不再生成', () async {
    final dao = await newDao();
    var id = await dao.addTask('值日');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(
      id,
      daily(end: RepeatEndType.until, endUntil: '2026-11-26'),
    );

    id = (await dao.completeRepeating(id))!; // 11-25
    id = (await dao.completeRepeating(id))!; // 11-26
    final last = await dao.completeRepeating(id);
    expect(last, isNull);
    final tasks = await dao.visibleTasks();
    expect(tasks.length, 3);
    expect(tasks.every((t) => t.done), isTrue);
  });

  test('没有时间的任务不能设置重复', () async {
    final dao = await newDao();
    final id = await dao.addTask('没有时间的任务');
    expect(
      () => dao.setRepeat(id, daily()),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('清空时间会一起清掉重复规则', () async {
    final dao = await newDao();
    final id = await dao.addTask('日历');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(id, daily());
    await dao.clearDue(id);

    final tasks = await dao.visibleTasks();
    expect(tasks.single.repeatRule, isNull);
    expect(tasks.single.seriesId, id); // series 不删，历史还能串起来
  });

  test('非重复任务勾选完成，行为与以前一样', () async {
    final dao = await newDao();
    final id = await dao.addTask('普通任务');
    await dao.setDone(id, true);
    final tasks = await dao.visibleTasks();
    expect(tasks.length, 1);
    expect(tasks.single.done, isTrue);
  });

  test('重复规则与 series 随 pnote-sync/6 同步到另一台设备', () async {
    final a = await newDao();
    final b = await newDao();
    final id = await a.addTask('练琴');
    await a.setDue(id, at: DateTime(2026, 11, 24, 19, 0),
        precision: DuePrecision.dateTime);
    await a.setRepeat(
      id,
      daily(end: RepeatEndType.count, endCount: 5),
    );
    await a.completeRepeating(id);

    await b.applyRemote(decodeState(encodeState(await a.exportState())));
    final tasks = await b.visibleTasks();
    expect(tasks.length, 2);
    final next = tasks.firstWhere((t) => !t.done);
    expect(next.seriesId, id);
    expect(parseRepeatRule(next.repeatRule)!.endCount, 5);
    expect(dueOf(next), DateTime(2026, 11, 25, 19, 0));
  });

  test('两台设备各自完成同一期，合并后仍只有一条下一期', () async {
    final a = await newDao();
    final b = await newDao();
    final id = await a.addTask('同步重复');
    await a.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await a.setRepeat(id, daily());
    await b.applyRemote(decodeState(encodeState(await a.exportState())));

    final nextA = await a.completeRepeating(id);
    final nextB = await b.completeRepeating(id);
    expect(nextA, nextB);

    await a.applyRemote(decodeState(encodeState(await b.exportState())));
    final tasks = await a.visibleTasks();
    expect(tasks.length, 2);
    expect(tasks.where((t) => !t.done).length, 1);
  });

  test('同步后任务类型仍是任务（kind 不被下一步生成弄丢）', () async {
    final dao = await newDao();
    final id = await dao.addTask('类型检查');
    await dao.setDue(id, at: DateTime(2026, 11, 24), precision: DuePrecision.date);
    await dao.setRepeat(id, daily());
    await dao.completeRepeating(id);
    final tasks = await dao.visibleTasks();
    expect(tasks.every((t) => t.kind == TaskKind.task), isTrue);
  });

  test('1.35 自定义每周：下一期落在指定的周几', () async {
    final dao = await newDao();
    final id = await dao.addTask('周五例会');
    await dao.setDue(id, at: DateTime(2026, 11, 25), precision: DuePrecision.date);
    await dao.setRepeat(
      id,
      const RepeatRule(freq: RepeatFreq.weekly, weekdays: [5]),
    );
    final nextId = await dao.completeRepeating(id);
    final tasks = await dao.visibleTasks();
    final next = tasks.firstWhere((t) => t.id == nextId);
    expect(next.dueValue, '2026-11-27');
  });
}
