import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/repeat.dart';
import 'package:uuid/uuid.dart';

/// 1.34/1.35 重复规则的纯函数测试：解析、文案、下一期、结束条件、确定性 id。
void main() {
  RepeatRule rule({
    RepeatFreq freq = RepeatFreq.daily,
    int interval = 1,
    RepeatEndType end = RepeatEndType.never,
    int endCount = 1,
    String? endUntil,
    int generated = 0,
    List<int> weekdays = const [],
    MonthlyMode monthlyMode = MonthlyMode.day,
    int? monthDay,
    int? nth,
    int? nthWeekday,
    int? month,
    int? day,
  }) =>
      RepeatRule(
        freq: freq,
        interval: interval,
        end: end,
        endCount: endCount,
        endUntil: endUntil,
        generated: generated,
        weekdays: weekdays,
        monthlyMode: monthlyMode,
        monthDay: monthDay,
        nth: nth,
        nthWeekday: nthWeekday,
        month: month,
        day: day,
      );

  test('规则编码/解析往返（次数、日期、已生成期数）', () {
    final a = rule(
      freq: RepeatFreq.weekly,
      interval: 2,
      end: RepeatEndType.count,
      endCount: 5,
      generated: 3,
    );
    final b = parseRepeatRule(encodeRepeatRule(a))!;
    expect(b.freq, RepeatFreq.weekly);
    expect(b.interval, 2);
    expect(b.end, RepeatEndType.count);
    expect(b.endCount, 5);
    expect(b.generated, 3);

    final c = rule(freq: RepeatFreq.monthly, end: RepeatEndType.until, endUntil: '2027-01-31');
    final d = parseRepeatRule(encodeRepeatRule(c))!;
    expect(d.end, RepeatEndType.until);
    expect(d.endUntil, '2027-01-31');
  });

  test('坏数据当「不重复」，不抛异常', () {
    expect(parseRepeatRule(null), isNull);
    expect(parseRepeatRule(''), isNull);
    expect(parseRepeatRule('不是 JSON'), isNull);
    expect(parseRepeatRule('{"freq":"every-hour"}'), isNull);
    expect(parseRepeatRule('[]'), isNull);
  });

  test('文案：每天 / 每 2 周 / 每月 / 每年，以及结束条件', () {
    expect(describeRepeat(rule()), '每天');
    expect(describeRepeat(rule(freq: RepeatFreq.weekly, interval: 2)), '每 2 周');
    expect(describeRepeat(rule(freq: RepeatFreq.monthly)), '每月');
    expect(describeRepeat(rule(freq: RepeatFreq.yearly)), '每年');
    expect(describeRepeatEnd(rule()), isNull);
    expect(
      describeRepeatEnd(rule(end: RepeatEndType.count, endCount: 3)),
      '共 3 期',
    );
    expect(
      describeRepeatEnd(rule(end: RepeatEndType.until, endUntil: '2027-01-31')),
      '到 2027-01-31 为止',
    );
  });

  test('下一期：每天/每周/每 2 周，保留原来的时刻', () {
    final due = DateTime(2026, 11, 24, 9, 30);
    expect(nextDueAfter(due, rule()), DateTime(2026, 11, 25, 9, 30));
    expect(
      nextDueAfter(due, rule(freq: RepeatFreq.weekly)),
      DateTime(2026, 12, 1, 9, 30),
    );
    expect(
      nextDueAfter(due, rule(freq: RepeatFreq.weekly, interval: 2)),
      DateTime(2026, 12, 8, 9, 30),
    );
  });

  test('下一期：月末与闰日会被夹住，不会溢出到下个月', () {
    expect(
      nextDueAfter(DateTime(2026, 1, 31), rule(freq: RepeatFreq.monthly)),
      DateTime(2026, 2, 28),
    );
    expect(
      nextDueAfter(DateTime(2024, 1, 31), rule(freq: RepeatFreq.monthly)),
      DateTime(2024, 2, 29),
    );
    expect(
      nextDueAfter(DateTime(2024, 2, 29), rule(freq: RepeatFreq.yearly)),
      DateTime(2025, 2, 28),
    );
  });

  test('结束条件：次数（含第一期）与截止日期', () {
    final nextDue = DateTime(2026, 11, 25);
    // 第 1 期完成时 generated=0：还能生成（总期数 0+2=2 ≤ 3）。
    expect(
      rule(end: RepeatEndType.count, endCount: 3).allows(nextDue),
      isTrue,
    );
    // generated=1（已在第 2 期）：再生成第 3 期仍允许。
    expect(
      rule(end: RepeatEndType.count, endCount: 3, generated: 1).allows(nextDue),
      isTrue,
    );
    // generated=2（已在第 3 期）：再生成就第 4 期了，不允许。
    expect(
      rule(end: RepeatEndType.count, endCount: 3, generated: 2).allows(nextDue),
      isFalse,
    );

    final untilRule = rule(end: RepeatEndType.until, endUntil: '2026-11-26');
    expect(untilRule.allows(DateTime(2026, 11, 26, 23, 59)), isTrue);
    expect(untilRule.allows(DateTime(2026, 11, 27)), isFalse);
    expect(untilRule.allows(DateTime(2026, 11, 30)), isFalse);
  });

  test('下一期的 id 是确定性的：同 series 同期数一样，两台设备算出来相同', () {
    final a = rule(generated: 1);
    final b = rule(generated: 1);
    expect(occurrenceId('3f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', a),
        occurrenceId('3f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', b));
    expect(
      occurrenceId('3f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', a),
      isNot(occurrenceId(
        '3f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
        rule(generated: 2),
      )),
    );
  });

  test('下一期按原精度编码：全天只到日期，精确带偏移', () {
    expect(
      encodeNextDue(DateTime(2026, 11, 25), DuePrecision.date),
      '2026-11-25',
    );
    expect(
      encodeNextDue(DateTime(2026, 11, 25, 9, 30), DuePrecision.dateTime),
      startsWith('2026-11-25T09:30'),
    );
  });

  test('1.35 每周多选：按周几找下一期，并支持每 N 周', () {
    final due = DateTime(2026, 11, 24, 9, 30); // 周二
    expect(
      nextDueAfter(due, rule(freq: RepeatFreq.weekly, weekdays: [1, 3, 5])),
      DateTime(2026, 11, 25, 9, 30), // 本周三
    );
    expect(
      nextDueAfter(
        DateTime(2026, 11, 27, 9, 30), // 周五
        rule(freq: RepeatFreq.weekly, weekdays: [1, 3, 5]),
      ),
      DateTime(2026, 11, 30, 9, 30), // 下周一
    );
    expect(
      nextDueAfter(
        DateTime(2026, 11, 25, 9, 30), // 周三
        rule(freq: RepeatFreq.weekly, interval: 2, weekdays: [1]),
      ),
      DateTime(2026, 12, 7, 9, 30), // 隔一周的周一
    );
  });

  test('1.35 每月：几号 / 第几个周几 / 月末（本月还没过就用本月）', () {
    expect(
      nextDueAfter(
        DateTime(2026, 11, 10, 8),
        rule(freq: RepeatFreq.monthly, monthDay: 15),
      ),
      DateTime(2026, 11, 15, 8),
    );
    expect(
      nextDueAfter(
        DateTime(2026, 11, 20, 8),
        rule(freq: RepeatFreq.monthly, monthDay: 15),
      ),
      DateTime(2026, 12, 15, 8),
    );
    expect(
      nextDueAfter(
        DateTime(2026, 1, 31),
        rule(freq: RepeatFreq.monthly, monthDay: 31),
      ),
      DateTime(2026, 2, 28),
    );
    // 2026-12-01 是周二 → 第二个周二 = 12-08。
    expect(
      nextDueAfter(
        DateTime(2026, 11, 10, 20),
        rule(
          freq: RepeatFreq.monthly,
          monthlyMode: MonthlyMode.nthWeekday,
          nth: 2,
          nthWeekday: 2,
        ),
      ),
      DateTime(2026, 12, 8, 20),
    );
    expect(
      nextDueAfter(
        DateTime(2026, 11, 30),
        rule(freq: RepeatFreq.monthly, monthlyMode: MonthlyMode.lastDay),
      ),
      DateTime(2026, 12, 31),
    );
  });

  test('1.35 每年固定月日；2 月 29 日落平年', () {
    expect(
      nextDueAfter(
        DateTime(2026, 3, 14, 9),
        rule(freq: RepeatFreq.yearly, month: 3, day: 14),
      ),
      DateTime(2027, 3, 14, 9),
    );
    expect(
      nextDueAfter(
        DateTime(2024, 2, 29),
        rule(freq: RepeatFreq.yearly, month: 2, day: 29),
      ),
      DateTime(2025, 2, 28),
    );
    expect(
      nextDueAfter(
        DateTime(2026, 1, 5),
        rule(freq: RepeatFreq.yearly, month: 12, day: 25),
      ),
      DateTime(2026, 12, 25),
    );
  });

  test('1.35 自定义规则编码/解析往返，旧的规则仍能解析', () {
    final weekly = rule(freq: RepeatFreq.weekly, weekdays: [1, 3, 5]);
    final w = parseRepeatRule(encodeRepeatRule(weekly))!;
    expect(w.weekdays, [1, 3, 5]);

    final nth = rule(
      freq: RepeatFreq.monthly,
      monthlyMode: MonthlyMode.nthWeekday,
      nth: -1,
      nthWeekday: 5,
    );
    final n = parseRepeatRule(encodeRepeatRule(nth))!;
    expect(n.monthlyMode, MonthlyMode.nthWeekday);
    expect(n.nth, -1);
    expect(n.nthWeekday, 5);

    final yearly = rule(freq: RepeatFreq.yearly, month: 2, day: 29);
    final y = parseRepeatRule(encodeRepeatRule(yearly))!;
    expect(y.month, 2);
    expect(y.day, 29);

    final old = parseRepeatRule('{"freq":"weekly","n":2,"end":"never"}')!;
    expect(old.weekdays, isEmpty);
    expect(old.monthlyMode, MonthlyMode.day);
  });

  test('1.35 文案：周几集合、几号、第几个周几、每年月日', () {
    expect(
      describeRepeat(rule(freq: RepeatFreq.weekly, weekdays: [1, 3, 5])),
      '每周一、三、五',
    );
    expect(
      describeRepeat(
          rule(freq: RepeatFreq.weekly, interval: 2, weekdays: [1, 3])),
      '每 2 周的周一、三',
    );
    expect(
      describeRepeat(rule(freq: RepeatFreq.monthly, monthDay: 15)),
      '每月 15 号',
    );
    expect(
      describeRepeat(
          rule(freq: RepeatFreq.monthly, monthlyMode: MonthlyMode.lastDay)),
      '每月最后一天',
    );
    expect(
      describeRepeat(rule(
        freq: RepeatFreq.monthly,
        monthlyMode: MonthlyMode.nthWeekday,
        nth: 2,
        nthWeekday: 2,
      )),
      '每月第二个周二',
    );
    expect(
      describeRepeat(rule(freq: RepeatFreq.yearly, month: 3, day: 14)),
      '每年 3 月 14 日',
    );
  });

  test('1.35 自定义部分进 id：不同周几不会撞 id，旧规则 id 保持不变', () {
    const series = '3f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
    final plain = rule(freq: RepeatFreq.weekly);
    expect(
      occurrenceId(series, plain),
      Uuid().v5(series, 'pnote-occ:weekly:1:0'),
    );
    final mon = rule(freq: RepeatFreq.weekly, weekdays: [1]);
    final fri = rule(freq: RepeatFreq.weekly, weekdays: [5]);
    expect(occurrenceId(series, mon), isNot(occurrenceId(series, fri)));
    expect(occurrenceId(series, mon), isNot(occurrenceId(series, plain)));
  });
}
