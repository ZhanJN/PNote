import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';

TaskState node({
  String id = 't',
  String? title = '写作业',
  bool done = false,
  bool isGroup = false,
  String? parent,
  String? due,
  int precision = 0,
  double order = 1024,
  int createdAt = 1,
}) {
  final fields = <TaskField, FieldValue>{
    TaskField.title: FieldValue(title ?? '', Hlc(1, 0, 'd')),
    TaskField.done: FieldValue(done ? 1 : 0, Hlc(1, 0, 'd')),
    TaskField.order: FieldValue(order, Hlc(1, 0, 'd')),
    TaskField.parent: FieldValue(parent, Hlc(1, 0, 'd')),
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
///
/// 以前这里硬编码 `+08:00`，在 UTC 的 CI 上 `now` 是本地 10:00 而 due 是
/// 10:25+08:00（= 02:25 UTC），于是「未来 25 分钟」被算成「逾期 1 天」。
/// 用本机偏移生成后，测试与运行环境时区无关（1.50.2）。
String precise(DateTime local) {
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:00'
      '$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}

void main() {
  group('全天任务文案', () {
    final now = at(2026, 11, 23, 10);
    test('今天/明天/后天/一周内', () {
      expect(formatDue(node(due: '2026-11-23', precision: 1), now), '今天');
      expect(formatDue(node(due: '2026-11-24', precision: 1), now), '明天');
      expect(formatDue(node(due: '2026-11-25', precision: 1), now), '后天');
      expect(formatDue(node(due: '2026-11-28', precision: 1), now), '5 天后');
    });
    test('超过一周显示月日，跨年补年份', () {
      expect(formatDue(node(due: '2026-12-01', precision: 1), now), '12月1日');
      expect(
        formatDue(node(due: '2027-01-03', precision: 1), now),
        '2027年1月3日',
      );
    });
    test('逾期只写天数，不带感叹号', () {
      expect(formatDue(node(due: '2026-11-20', precision: 1), now), '逾期 3 天');
    });
  });

  group('精确任务文案', () {
    final now = at(2026, 11, 23, 10);
    test('不足一小时', () {
      expect(
        formatDue(
          node(due: precise(now.add(const Duration(minutes: 25))), precision: 2),
          now,
        ),
        '25 分钟后',
      );
    });
    test('不足一天', () {
      expect(
        formatDue(
          node(due: precise(now.add(const Duration(hours: 3))), precision: 2),
          now,
        ),
        '3 小时后',
      );
    });
    test('一周内补时刻，余数小时不为零写成两天', () {
      expect(
        formatDue(node(due: precise(at(2026, 11, 26, 10)), precision: 2), now),
        '3 天后 10:00',
      );
      expect(
        formatDue(node(due: precise(at(2026, 11, 26, 15)), precision: 2), now),
        '3 天 5 小时后',
      );
    });
    test('超过一周显示日期', () {
      expect(
        formatDue(node(due: precise(at(2026, 12, 5, 9, 30)), precision: 2), now),
        '12月5日',
      );
    });
    test('逾期按整天向上取整，最少一天', () {
      expect(
        formatDue(node(due: precise(at(2026, 11, 23, 9, 30)), precision: 2), now),
        '逾期 1 天',
      );
      expect(
        formatDue(node(due: precise(at(2026, 11, 22, 4)), precision: 2), now),
        '逾期 2 天',
      );
    });
  });

  group('逾期与红点', () {
    final now = at(2026, 11, 23, 10);
    test('全天任务当天不算逾期', () {
      expect(isOverdue(node(due: '2026-11-23', precision: 1), now), isFalse);
      expect(isOverdue(node(due: '2026-11-22', precision: 1), now), isTrue);
    });
    test('红点只在接下来 24 小时', () {
      expect(
        isUrgent(node(due: precise(at(2026, 11, 24, 9)), precision: 2), now),
        isTrue,
      );
      expect(
        isUrgent(node(due: precise(at(2026, 11, 24, 11)), precision: 2), now),
        isFalse,
      );
      expect(
        isUrgent(node(due: precise(at(2026, 11, 23, 9)), precision: 2), now),
        isFalse,
        reason: '逾期不亮红点',
      );
      expect(
        isUrgent(
          node(
            due: precise(at(2026, 11, 23, 20)),
            precision: 2,
            done: true,
          ),
          now,
        ),
        isFalse,
      );
    });
  });

  group('视图切片', () {
    final now = at(2026, 11, 23, 10);
    test('今天与逾期互斥', () {
      final t = node(due: '2026-11-23', precision: 1);
      expect(inSlice(t, TimeSlice.today, now), isTrue);
      expect(inSlice(t, TimeSlice.overdue, now), isFalse);
      final y = node(due: '2026-11-22', precision: 1);
      expect(inSlice(y, TimeSlice.overdue, now), isTrue);
      expect(inSlice(y, TimeSlice.today, now), isFalse);
    });
    test('精确任务过了点就是逾期，不再算今天', () {
      final t = node(due: precise(at(2026, 11, 23, 9)), precision: 2);
      expect(inSlice(t, TimeSlice.overdue, now), isTrue);
      expect(inSlice(t, TimeSlice.today, now), isFalse);
    });
    test('本周是今之后 7 天内，不含今天', () {
      expect(
        inSlice(node(due: '2026-11-24', precision: 1), TimeSlice.week, now),
        isTrue,
      );
      expect(
        inSlice(node(due: '2026-11-30', precision: 1), TimeSlice.week, now),
        isTrue,
      );
      expect(
        inSlice(node(due: '2026-12-01', precision: 1), TimeSlice.week, now),
        isFalse,
      );
      expect(
        inSlice(node(due: '2026-11-23', precision: 1), TimeSlice.week, now),
        isFalse,
      );
    });
    test('没有时间的任务只出现在「全部」', () {
      final t = node();
      for (final s in [TimeSlice.today, TimeSlice.week, TimeSlice.overdue]) {
        expect(inSlice(t, s, now), isFalse);
      }
      expect(inSlice(t, TimeSlice.all, now), isTrue);
    });
  });

  test('筛选保留祖先组', () {
    final now = at(2026, 11, 23, 10);
    final g = node(id: 'g', isGroup: true, title: '学习');
    final t = node(id: 't', parent: 'g', due: '2026-11-23', precision: 1);
    final other = node(id: 'o', parent: 'g', due: '2026-12-09', precision: 1);
    final rows = flattenTree([g, t, other]);
    final kept = filterRows(rows, TimeSlice.today, now).map((r) => r.id).toList();
    expect(kept, ['g', 't']);
  });

  test('今天里精确任务按时刻升序，全天排最后', () {
    final now = at(2026, 11, 23, 1);
    final rows = flattenTree([
      node(id: 'all', due: '2026-11-23', precision: 1),
      node(
        id: 'late',
        due: encodeDueDateTime(at(2026, 11, 23, 18)),
        precision: 2,
      ),
      node(
        id: 'early',
        due: encodeDueDateTime(at(2026, 11, 23, 9)),
        precision: 2,
      ),
    ]);
    final kept = filterRows(rows, TimeSlice.today, now)
        .map((r) => r.id)
        .toList();
    expect(kept, ['early', 'late', 'all']);
  });

  test('编码与解析：日期与带偏移的时刻', () {
    final day = at(2026, 11, 23);
    expect(encodeDueDate(day), '2026-11-23');
    final moment = at(2026, 11, 23, 9, 30);
    final encoded = encodeDueDateTime(moment);
    expect(encoded, contains('2026-11-23T09:30:00'));
    final t = node(due: encoded, precision: 2);
    final parsed = dueOf(t);
    expect(parsed, isNotNull);
    expect(parsed!.toLocal(), moment);
  });

  test('countInSlice：只数任务，不算组', () {
    final now = at(2026, 11, 23, 10);
    final rows = flattenTree([
      node(id: 'g', title: '组', isGroup: true),
      node(id: 'a', parent: 'g', due: '2026-11-21', precision: 1),
      node(id: 'b', parent: 'g', due: '2026-11-23', precision: 1),
      node(id: 'c', due: '2026-11-30', precision: 1),
    ]);
    expect(countInSlice(rows, TimeSlice.overdue, now), 1);
    expect(countInSlice(rows, TimeSlice.today, now), 1);
    expect(countInSlice(rows, TimeSlice.all, now), 3);
  });
}
