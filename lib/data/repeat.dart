/// 重复任务（1.34 起，1.35 加自定义）：规则解析/编码、文案、下一期时间、生成 id。
///
/// 为什么规则存 JSON 字符串：1.31 已经预留了 repeat_rule / series_id 两列，
/// 不改 schema；JSON 让规则可以自由扩展（自定义周几、几号、第几个周几、月末、
/// 每年月日），同时仍然是一个普通的字段级 LWW 值，改规则也会同步。
///
/// 设计决定：
///   1. 规则必须挂在有时间的任务上（没有时间就不知道下一期从哪天算）；
///   2. 结束条件三选一：永不 / 次数（含第一期）/ 到某天；
///   3. 下一期的 id 是「series + 频率 + 间隔 + 第几期（+ 自定义部分）」的
///      UUIDv5，两台设备各自点完成会算出同一个 id，同步时不会变成两条；
///   4. 自定义字段只在用户真的改了默认值时才写入 JSON —— 这样 1.34 生成的
///      下一期 id 在 1.35 里仍然对得上，不会因为升级多出一条重复任务。
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'package:pnote/data/due_time.dart';

/// 重复频率。只保留最常用的四种，间隔（每 N 个）单独存。
enum RepeatFreq {
  daily('daily', '天'),
  weekly('weekly', '周'),
  monthly('monthly', '月'),
  yearly('yearly', '年');

  const RepeatFreq(this.wire, this.unit);

  final String wire;

  /// 用在文案里：「每 2 周」。
  final String unit;

  static RepeatFreq? fromWire(Object? name) {
    for (final f in RepeatFreq.values) {
      if (f.wire == name) return f;
    }
    return null;
  }
}

/// 结束条件。
enum RepeatEndType {
  never('never'),
  count('count'),
  until('until');

  const RepeatEndType(this.wire);

  final String wire;

  static RepeatEndType fromWire(Object? name) {
    for (final t in RepeatEndType.values) {
      if (t.wire == name) return t;
    }
    return RepeatEndType.never;
  }
}

/// 每个月按什么算（1.35）。
enum MonthlyMode {
  /// 每月几号（1–31，遇到小月自动夹住）。
  day,

  /// 每月第几个周几（第 1–5 个；没有第 5 个时落在当月最后一个）。
  nthWeekday,

  /// 每月最后一天。
  lastDay,
}

/// 一条重复规则。
///
/// [generated] 表示「已经生成过几期」：第一期是 0，生成第二期后 1……只用来
/// 判断次数上限和算下一期的确定性 id，用户看不到。
class RepeatRule {
  const RepeatRule({
    required this.freq,
    this.interval = 1,
    this.end = RepeatEndType.never,
    this.endCount = 1,
    this.endUntil,
    this.generated = 0,
    this.weekdays = const [],
    this.monthlyMode = MonthlyMode.day,
    this.monthDay,
    this.nth,
    this.nthWeekday,
    this.month,
    this.day,
  });

  final RepeatFreq freq;
  final int interval;
  final RepeatEndType end;

  /// 结束条件为「次数」时：总共出现几期（含第一期）。
  final int endCount;

  /// 结束条件为「到某天」时：最后一期的日期（YYYY-MM-DD，含当天）。
  final String? endUntil;

  final int generated;

  /// 每周的哪几天（1=周一 … 7=周日，已排序去重）。空 = 沿用原来那天。
  final List<int> weekdays;

  /// 每月按什么算；只在 [RepeatFreq.monthly] 时有意义。
  final MonthlyMode monthlyMode;

  /// 每月几号（1–31）。null = 沿用原来那天。
  final int? monthDay;

  /// 每月第几个周几：1–5，-1 表示最后一个。
  final int? nth;

  /// 第几个周几里的「周几」：1=周一 … 7=周日。
  final int? nthWeekday;

  /// 每年的月份（1–12）。null = 沿用原来那个月。
  final int? month;

  /// 每年的日（1–31）。null = 沿用原来那天。
  final int? day;

  /// 有自定义部分吗？（决定 id 里要不要带自定义签名）
  bool get hasCustom {
    if (freq == RepeatFreq.weekly && weekdays.isNotEmpty) return true;
    if (freq == RepeatFreq.monthly) {
      if (monthlyMode == MonthlyMode.lastDay) return true;
      if (monthlyMode == MonthlyMode.nthWeekday &&
          nth != null &&
          nthWeekday != null) {
        return true;
      }
      if (monthDay != null) return true;
    }
    if (freq == RepeatFreq.yearly && month != null && day != null) return true;
    return false;
  }

  RepeatRule copyWith({
    RepeatFreq? freq,
    int? interval,
    RepeatEndType? end,
    int? endCount,
    String? endUntil,
    int? generated,
    List<int>? weekdays,
    MonthlyMode? monthlyMode,
    int? monthDay,
    int? nth,
    int? nthWeekday,
    int? month,
    int? day,
  }) =>
      RepeatRule(
        freq: freq ?? this.freq,
        interval: interval ?? this.interval,
        end: end ?? this.end,
        endCount: endCount ?? this.endCount,
        endUntil: endUntil ?? this.endUntil,
        generated: generated ?? this.generated,
        weekdays: weekdays ?? this.weekdays,
        monthlyMode: monthlyMode ?? this.monthlyMode,
        monthDay: monthDay ?? this.monthDay,
        nth: nth ?? this.nth,
        nthWeekday: nthWeekday ?? this.nthWeekday,
        month: month ?? this.month,
        day: day ?? this.day,
      );

  /// 产生下一期之后，下一期身上的规则（generated 加一）。
  RepeatRule advance() => copyWith(generated: generated + 1);

  /// 允许再生成一期吗？[nextDue] 是「下一期该在什么时候」。
  bool allows(DateTime nextDue) {
    return switch (end) {
      RepeatEndType.never => true,
      // generated 已经生成过几期；再生成一期后总期数是 generated + 2。
      RepeatEndType.count => generated + 2 <= endCount,
      // 「到某天为止」含当天：按日期比，不按时刻比。
      RepeatEndType.until => _untilDay() == null ||
          !_dayOf(nextDue).isAfter(_untilDay()!),
    };
  }

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  DateTime? _untilDay() {
    final raw = endUntil;
    if (raw == null) return null;
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  Map<String, Object?> toJson() => {
        'freq': freq.wire,
        'n': interval,
        'end': end.wire,
        if (end == RepeatEndType.count) 'count': endCount,
        if (end == RepeatEndType.until && endUntil != null) 'until': endUntil,
        if (generated > 0) 'gen': generated,
        if (freq == RepeatFreq.weekly && weekdays.isNotEmpty) 'wd': weekdays,
        if (freq == RepeatFreq.monthly) ...{
          if (monthlyMode == MonthlyMode.lastDay) 'last': true,
          if (monthlyMode != MonthlyMode.lastDay && monthDay != null)
            'md': monthDay,
          if (monthlyMode == MonthlyMode.nthWeekday &&
              nth != null &&
              nthWeekday != null) ...{
            'nth': nth,
            'nthd': nthWeekday,
          },
        },
        if (freq == RepeatFreq.yearly && month != null && day != null) ...{
          'm': month,
          'd': day,
        },
      };

  factory RepeatRule.fromJson(Map<String, Object?> json) {
    final freq = RepeatFreq.fromWire(json['freq']);
    if (freq == null) throw const FormatException('未知重复频率');
    final interval = (json['n'] as num?)?.toInt() ?? 1;
    final end = RepeatEndType.fromWire(json['end']);
    final count = (json['count'] as num?)?.toInt() ?? 1;
    final until = json['until'];
    final generated = (json['gen'] as num?)?.toInt() ?? 0;

    var weekdays = <int>[];
    if (freq == RepeatFreq.weekly) {
      final raw = json['wd'];
      if (raw is List) {
        weekdays = {
          for (final e in raw)
            if (e is num && e.toInt() >= 1 && e.toInt() <= 7) e.toInt(),
        }.toList()
          ..sort();
      }
    }

    var monthlyMode = MonthlyMode.day;
    int? monthDay;
    int? nth;
    int? nthWeekday;
    if (freq == RepeatFreq.monthly) {
      if (json['last'] == true) {
        monthlyMode = MonthlyMode.lastDay;
      } else if (json['nth'] is num && json['nthd'] is num) {
        final n = (json['nth'] as num).toInt();
        final wd = (json['nthd'] as num).toInt();
        if ((n >= 1 && n <= 5) || n == -1) {
          if (wd >= 1 && wd <= 7) {
            monthlyMode = MonthlyMode.nthWeekday;
            nth = n;
            nthWeekday = wd;
          }
        }
      }
      if (monthlyMode == MonthlyMode.day && json['md'] is num) {
        final d = (json['md'] as num).toInt();
        if (d >= 1 && d <= 31) monthDay = d;
      }
    }

    int? month;
    int? day;
    if (freq == RepeatFreq.yearly) {
      final m = (json['m'] as num?)?.toInt();
      final d = (json['d'] as num?)?.toInt();
      if (m != null && m >= 1 && m <= 12 && d != null && d >= 1 && d <= 31) {
        month = m;
        day = d;
      }
    }

    return RepeatRule(
      freq: freq,
      interval: interval < 1 ? 1 : interval,
      end: end,
      endCount: count < 1 ? 1 : count,
      endUntil: until is String ? until : null,
      generated: generated < 0 ? 0 : generated,
      weekdays: weekdays,
      monthlyMode: monthlyMode,
      monthDay: monthDay,
      nth: nth,
      nthWeekday: nthWeekday,
      month: month,
      day: day,
    );
  }
}

/// 解析数据库里的规则原文。坏数据一律当「不是重复任务」，不让它把列表拖垮。
RepeatRule? parseRepeatRule(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return RepeatRule.fromJson(Map<String, Object?>.from(decoded));
  } catch (_) {
    return null;
  }
}

String encodeRepeatRule(RepeatRule rule) => jsonEncode(rule.toJson());

const List<String> kWeekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// 规则文案：「每天」「每 2 周」「每周一、三、五」「每月 15 号」
/// 「每月最后一个周五」「每年 3 月 14 日」。
String describeRepeat(RepeatRule rule) {
  final interval = rule.interval;

  switch (rule.freq) {
    case RepeatFreq.daily:
      return interval <= 1 ? '每天' : '每 $interval 天';

    case RepeatFreq.weekly:
      if (rule.weekdays.isEmpty) {
        return interval <= 1 ? '每周' : '每 $interval 周';
      }
      final days = rule.weekdays.map((d) => kWeekdayNames[d - 1]).join('、');
      if (rule.weekdays.length == 7) {
        return interval <= 1 ? '每天' : '每 $interval 周的每天';
      }
      return interval <= 1 ? '每周$days' : '每 $interval 周的周$days';

    case RepeatFreq.monthly:
      final prefix = interval <= 1 ? '每月' : '每 $interval 个月的';
      final suffix = switch (rule.monthlyMode) {
        MonthlyMode.lastDay => '最后一天',
        MonthlyMode.nthWeekday => rule.nth == -1
            ? '最后一个周${kWeekdayNames[(rule.nthWeekday ?? 1) - 1]}'
            : '第${_cnNumber(rule.nth ?? 1)}个周'
                '${kWeekdayNames[(rule.nthWeekday ?? 1) - 1]}',
        MonthlyMode.day => rule.monthDay == null
            ? ''
            : ' ${rule.monthDay} 号',
      };
      if (suffix.isEmpty) {
        return interval <= 1 ? '每月' : '每 $interval 个月';
      }
      return interval <= 1 ? '每月$suffix' : '$prefix$suffix';

    case RepeatFreq.yearly:
      final prefix = interval <= 1 ? '每年' : '每 $interval 年的';
      if (rule.month == null || rule.day == null) {
        return interval <= 1 ? '每年' : '每 $interval 年';
      }
      final date = '${rule.month} 月 ${rule.day} 日';
      return interval <= 1 ? '每年 $date' : '$prefix $date';
  }
}

String _cnNumber(int n) =>
    const ['', '一', '二', '三', '四', '五'][n.clamp(0, 5)];

/// 结束条件文案，给对话框和任务行用；永不结束返回 null。
String? describeRepeatEnd(RepeatRule rule) {
  return switch (rule.end) {
    RepeatEndType.never => null,
    RepeatEndType.count => '共 ${rule.endCount} 期',
    RepeatEndType.until => '到 ${rule.endUntil ?? '—'} 为止',
  };
}

/// 按规则算下一期的时间（保留原来的时刻）。算不出来返回 null。
DateTime? nextDueAfter(DateTime due, RepeatRule rule) {
  final n = rule.interval < 1 ? 1 : rule.interval;
  return switch (rule.freq) {
    RepeatFreq.daily => _addDays(due, n),
    RepeatFreq.weekly => rule.weekdays.isEmpty
        ? _addDays(due, 7 * n)
        : _nextWeekday(due, n, rule.weekdays),
    RepeatFreq.monthly => switch (rule.monthlyMode) {
        MonthlyMode.lastDay => _monthDayOf(due, n, null, lastDay: true),
        MonthlyMode.nthWeekday =>
          _monthDayOf(due, n, null, nth: rule.nth, nthWeekday: rule.nthWeekday),
        MonthlyMode.day => rule.monthDay == null
            ? _addMonths(due, n)
            : _monthDayOf(due, n, rule.monthDay),
      },
    RepeatFreq.yearly => (rule.month != null && rule.day != null)
        ? _yearMonthDay(due, n, rule.month!, rule.day!)
        : _addYears(due, n),
  };
}

DateTime _addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days, d.hour, d.minute);

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// 加月份要夹住月末：1 月 31 日 + 1 个月 = 2 月 28/29 日，而不是 3 月 3 日。
DateTime _addMonths(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day.clamp(1, lastDay), d.hour, d.minute);
}

/// 每周自定义：从 due 的下一周开始找，周间隔要能被 interval 整除。
DateTime _nextWeekday(DateTime due, int interval, List<int> weekdays) {
  final wanted = weekdays.toSet();
  final baseMonday = _dayOf(due).subtract(Duration(days: due.weekday - 1));
  for (var i = 1; i <= 400; i++) {
    final candidate = _dayOf(due).add(Duration(days: i));
    final weeks = candidate.difference(baseMonday).inDays ~/ 7;
    if (weeks % interval == 0 && wanted.contains(candidate.weekday)) {
      return DateTime(candidate.year, candidate.month, candidate.day, due.hour,
          due.minute);
    }
  }
  return _addDays(due, 7 * interval);
}

/// 每月：几号 / 第几个周几 / 月末。先看本月里「严格晚于 due」的那一天，
/// 没有再跳到下一个月（加月份时夹住月末）。
DateTime _monthDayOf(
  DateTime due,
  int months,
  int? monthDay, {
  bool lastDay = false,
  int? nth,
  int? nthWeekday,
}) {
  final same = _monthPattern(due.year, due.month, due, monthDay,
      lastDay: lastDay, nth: nth, nthWeekday: nthWeekday);
  if (same.isAfter(due)) return same;

  final total = due.year * 12 + (due.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  return _monthPattern(year, month, due, monthDay,
      lastDay: lastDay, nth: nth, nthWeekday: nthWeekday);
}

DateTime _monthPattern(
  int year,
  int month,
  DateTime due,
  int? monthDay, {
  bool lastDay = false,
  int? nth,
  int? nthWeekday,
}) {
  final last = DateTime(year, month + 1, 0).day;

  if (lastDay) {
    return DateTime(year, month, last, due.hour, due.minute);
  }
  if (nth != null && nthWeekday != null) {
    final first = DateTime(year, month, 1);
    if (nth == -1) {
      final lastWeekday = DateTime(year, month, last).weekday;
      final day = last - ((lastWeekday - nthWeekday) % 7);
      return DateTime(year, month, day, due.hour, due.minute);
    }
    var day = 1 + ((nthWeekday - first.weekday) % 7) + 7 * (nth - 1);
    if (day > last) {
      // 没有第 5 个：落在当月最后一个同周几。
      final lastWeekday = DateTime(year, month, last).weekday;
      day = last - ((lastWeekday - nthWeekday) % 7);
    }
    return DateTime(year, month, day, due.hour, due.minute);
  }

  final target = (monthDay ?? due.day).clamp(1, last);
  return DateTime(year, month, target, due.hour, due.minute);
}

/// 每年固定月日；先看今年，今年那天已过（或就是今天）才跳到下一年。
/// 2 月 29 日遇到平年落到 2 月 28 日。
DateTime _yearMonthDay(DateTime due, int years, int month, int day) {
  final thisYear = _makeDate(due.year, month, day, due);
  if (thisYear.isAfter(due)) return thisYear;
  return _makeDate(due.year + years, month, day, due);
}

DateTime _makeDate(int year, int month, int day, DateTime due) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day.clamp(1, last), due.hour, due.minute);
}

/// 加年份同理：2 月 29 日 + 1 年 = 2 月 28 日。
DateTime _addYears(DateTime d, int years) {
  final year = d.year + years;
  final lastDay = DateTime(year, d.month + 1, 0).day;
  return DateTime(year, d.month, d.day.clamp(1, lastDay), d.hour, d.minute);
}

/// 下一期的确定性 id：同一个 series、同一个频率/间隔/自定义部分/「第几期」，
/// 在哪台设备上算出来都一样。
///
/// 这样两台设备都点了同一条任务的「完成」，各自生成的下一期会合并成一条
/// （UA 里 id 相同 → 字段级合并），而不是变成两条重复任务。
String occurrenceId(String seriesId, RepeatRule nextRule) {
  final extra = _customKey(nextRule);
  final name = 'pnote-occ:${nextRule.freq.wire}:'
      '${nextRule.interval}:${nextRule.generated}$extra';
  try {
    return const Uuid().v5(seriesId, name);
  } on FormatException {
    // series 不是合法 UUID（理论上不会发生）时退化成 v4，至少不会崩。
    return const Uuid().v4();
  }
}

/// 自定义部分的稳定签名；没有自定义时返回空串（保证 1.34 的 id 继续对得上）。
String _customKey(RepeatRule rule) {
  if (rule.freq == RepeatFreq.weekly && rule.weekdays.isNotEmpty) {
    return ':wd=${rule.weekdays.join('.')}';
  }
  if (rule.freq == RepeatFreq.monthly) {
    if (rule.monthlyMode == MonthlyMode.lastDay) return ':last';
    if (rule.monthlyMode == MonthlyMode.nthWeekday &&
        rule.nth != null &&
        rule.nthWeekday != null) {
      return ':nth=${rule.nth}@${rule.nthWeekday}';
    }
    if (rule.monthDay != null) return ':md=${rule.monthDay}';
  }
  if (rule.freq == RepeatFreq.yearly && rule.month != null && rule.day != null) {
    return ':y=${rule.month}-${rule.day}';
  }
  return '';
}

/// 把「下一期的时间」按任务原来的精度编码回数据库字符串。
String encodeNextDue(DateTime nextDue, DuePrecision precision) =>
    precision == DuePrecision.dateTime
        ? encodeDueDateTime(nextDue)
        : encodeDueDate(nextDue);
