import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/reminder.dart';
import 'package:pnote/sync/hlc.dart';

TaskState node({
  String id = 't',
  String? title = '写作业',
  bool done = false,
  bool isGroup = false,
  String? parent,
  String? due,
  int precision = 0,
  int? remindLead,
  double order = 1024,
  int createdAt = 1,
}) {
  final fields = <TaskField, FieldValue>{
    TaskField.title: FieldValue(title ?? '', Hlc(1, 0, 'd')),
    TaskField.done: FieldValue(done ? 1 : 0, Hlc(1, 0, 'd')),
    TaskField.order: FieldValue(order, Hlc(1, 0, 'd')),
    TaskField.parent: FieldValue(parent, Hlc(1, 0, 'd')),
    if (remindLead != null)
      TaskField.remindLead: FieldValue(remindLead, Hlc(1, 0, 'd')),
    if (due != null) TaskField.due: FieldValue(due, Hlc(1, 0, 'd')),
    if (due != null)
      TaskField.duePrecision: FieldValue(precision, Hlc(1, 0, 'd')),
  };
  return TaskState(
    id: id,
    createdAt: createdAt,
    fields: fields,
    kind: isGroup ? TaskKind.group : TaskKind.task,
  );
}

DateTime at(int y, int m, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, m, d, h, mi);

String two(int v) => v.toString().padLeft(2, '0');

/// 把「本机时间」写成生产同格式的 due 字符串（带本机时区偏移）。
/// 硬编码 `+08:00` 在 UTC 的 CI 上会把未来时刻算成过去（1.50.2）。
String precise(DateTime local) {
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:00'
      '$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}

void main() {
  group('提前量三层继承', () {
    test('单条 > 组 > 全局', () {
      final group = node(id: 'g', isGroup: true, remindLead: 30);
      expect(effectiveLead(node(remindLead: 5), group, 15), 5);
      expect(effectiveLead(node(), group, 15), 30);
      expect(effectiveLead(node(), null, 15), 15);
    });

    test('关闭档位各层都生效', () {
      final group = node(id: 'g', isGroup: true, remindLead: -1);
      expect(effectiveLead(node(), group, 15), isNull);
      expect(effectiveLead(node(remindLead: -1), null, 15), isNull);
      expect(effectiveLead(node(), null, -1), isNull);
    });

    test('组本身不提醒', () {
      expect(
        effectiveLead(node(isGroup: true, remindLead: 15), null, 15),
        isNull,
      );
    });
  });

  group('提醒时刻', () {
    test('全天任务按当天 9:00 再减提前量', () {
      final t = node(due: '2026-11-24', precision: 1);
      expect(
        reminderAt(t, lead: 15, allDayHour: 9, allDayMinute: 0),
        at(2026, 11, 24, 8, 45),
      );
      expect(
        reminderAt(t, lead: 0, allDayHour: 8, allDayMinute: 30),
        at(2026, 11, 24, 8, 30),
      );
    });

    test('精确任务按时刻减提前量', () {
      final t = node(due: precise(at(2026, 11, 23, 14)), precision: 2);
      expect(
        reminderAt(t, lead: 60),
        at(2026, 11, 23, 13),
      );
    });

    test('没时间的任务没有提醒时刻', () {
      expect(reminderAt(node(), lead: 15), isNull);
    });
  });

  group('排班', () {
    const settings = ReminderSettings();

    test('跳过完成/删除/组/无时间/已过期', () {
      final now = at(2026, 11, 23, 10);
      final specs = planReminders(
        [
          node(id: 'ok', due: precise(at(2026, 11, 23, 14)), precision: 2),
          node(id: 'done', done: true, due: precise(at(2026, 11, 23, 14))),
          node(id: 'group', isGroup: true, due: precise(at(2026, 11, 23, 14))),
          node(id: 'nodue'),
          // 今早 9:00 的全天任务，提前 15 分钟已在过去，不补发。
          node(id: 'past', due: '2026-11-23', precision: 1),
        ],
        settings: settings,
        now: now,
      );
      expect(specs.map((s) => s.taskId), ['ok']);
    });

    test('用组默认提前量，并按时间升序', () {
      final now = at(2026, 11, 23, 10);
      final specs = planReminders(
        [
          node(id: 'g', isGroup: true, remindLead: 60),
          node(
            id: 'a',
            parent: 'g',
            due: precise(at(2026, 11, 23, 15)),
            precision: 2,
          ),
          node(id: 'b', due: precise(at(2026, 11, 23, 14)), precision: 2),
        ],
        settings: settings,
        now: now,
      );
      expect(specs.map((s) => s.taskId), ['b', 'a']);
      expect(specs.last.at.hour, 14);
    });

    test('超出 30 天不排', () {
      final specs = planReminders(
        [node(id: 'far', due: '2027-02-01', precision: 1)],
        settings: settings,
        now: at(2026, 11, 23, 10),
      );
      expect(specs, isEmpty);
    });

    test('通知正文用任务文案', () {
      final specs = planReminders(
        [node(due: precise(at(2026, 11, 23, 14)), precision: 2)],
        settings: settings,
        now: at(2026, 11, 23, 10),
      );
      expect(specs.single.body, '4 小时后到期');
    });

    test('总开关关闭就不排', () {
      final specs = planReminders(
        [node(due: precise(at(2026, 11, 23, 14)), precision: 2)],
        settings: const ReminderSettings(enabled: false),
        now: at(2026, 11, 23, 10),
      );
      expect(specs, isEmpty);
    });
  });

  group('通知 id 与文案', () {
    test('同一任务同一时刻 id 稳定，不同时刻不同', () {
      final t = at(2026, 11, 23, 13, 45);
      expect(reminderId('t1', t), reminderId('t1', t));
      expect(reminderId('t1', t), isNot(reminderId('t2', t)));
      final later = t.add(const Duration(minutes: 1));
      expect(reminderId('t1', t), isNot(reminderId('t1', later)));
      expect(reminderId('t1', t), greaterThan(0));
    });

    test('档位文案', () {
      expect(ReminderLead.label(0), '准时');
      expect(ReminderLead.label(15), '提前 15 分钟');
      expect(ReminderLead.label(60), '提前 1 小时');
      expect(ReminderLead.label(1440), '提前 1 天');
      expect(ReminderLead.label(-1), '关闭提醒');
    });
  });
}
