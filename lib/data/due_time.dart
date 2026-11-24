/// 时间系统（1.31）：时间值的解析/编码、文案、逾期与红点、视图切片。
///
/// 为什么单独一个纯函数文件：时间规则全是「给定 now + 任务 → 一个结果」，
/// 可以脱离数据库和 Widget 直接测（项目说明 7.16）。UI 只负责把结果画出来。
///
/// 三条硬规则（来自用户 1.31 的需求）：
///   1. 逾期是中性等待：不加感叹号、不累计拖延、不用红色。
///   2. 唯一的红色是「任务时间落在接下来 24 小时内」的高饱和红点。
///   3. 同一任务不能同时出现在「今天」和「逾期」—— 切片互斥。
library;

import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';

/// 时间精度。0 = 没设时间，1 = 只到日（全天），2 = 到分钟（精确）。
enum DuePrecision {
  none(0),
  date(1),
  dateTime(2);

  const DuePrecision(this.code);

  final int code;

  static DuePrecision fromCode(int? code) => switch (code) {
        1 => DuePrecision.date,
        2 => DuePrecision.dateTime,
        _ => DuePrecision.none,
      };
}

/// 列表上方的视图切片。它们只是「看同一批数据的角度」，不是分组、不落库。
enum TimeSlice {
  all('全部'),
  today('今天'),
  week('本周'),
  overdue('逾期');

  const TimeSlice(this.label);

  final String label;
}

/// 任务的时间值（本地时间）。全天任务返回当天 00:00；没有时间返回 null。
DateTime? dueOf(TaskState task) {
  final raw = task.dueValue;
  if (raw == null || raw.isEmpty) return null;
  final precision = DuePrecision.fromCode(task.duePrecision);
  if (precision == DuePrecision.none) return null;
  if (precision == DuePrecision.date) {
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
  // 精确时间存的是带偏移的 ISO：DateTime.parse 会把偏移换算成 UTC，
  // 再 toLocal() 就是本机时区下的同一时刻（跨时区展示才对）。
  final parsed = DateTime.tryParse(raw);
  return parsed?.toLocal();
}

/// 全天任务存当地日期（不带时区），避免「跨时区变成前一天」。
String encodeDueDate(DateTime local) {
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 精确时间存「原始时区」：本机时刻 + 当时偏移（如 +08:00）。
/// 这样另一台设备拿到的仍是同一个瞬间，展示时再换成本机时区。
String encodeDueDateTime(DateTime local) {
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final total = offset.inMinutes.abs();
  final oh = (total ~/ 60).toString().padLeft(2, '0');
  final om = (total % 60).toString().padLeft(2, '0');
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$y-$mo-${d}T$h:$mi:00$sign$oh:$om';
}

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// 有没有逾期。全天任务按「日期」比，精确任务按「时刻」比。
bool isOverdue(TaskState task, DateTime now) {
  if (task.isGroup) return false;
  final due = dueOf(task);
  if (due == null) return false;
  final precision = DuePrecision.fromCode(task.duePrecision);
  if (precision == DuePrecision.date) {
    return _dayOf(due).isBefore(_dayOf(now));
  }
  return due.isBefore(now);
}

/// 是否落在接下来 24 小时内 —— 唯一允许亮红点的条件。
/// 已逾期的不亮（逾期是中性等待）；已完成的不亮。
bool isUrgent(TaskState task, DateTime now) {
  if (task.isGroup || task.done) return false;
  final due = dueOf(task);
  if (due == null) return false;
  final left = due.difference(now);
  return left >= Duration.zero && left <= const Duration(hours: 24);
}

/// 是否属于某个视图切片。切片互斥由这里的判定顺序保证：
/// 逾期 → 今天（未过点）→ 本周（今之后 7 天内）→ 全部。
bool inSlice(TaskState task, TimeSlice slice, DateTime now) {
  if (task.isGroup) return false;
  final due = dueOf(task);
  if (slice == TimeSlice.all) return true;
  if (due == null) return false;
  final precision = DuePrecision.fromCode(task.duePrecision);
  final today = _dayOf(now);

  if (precision == DuePrecision.date) {
    final dueDay = _dayOf(due);
    final diff = dueDay.difference(today).inDays;
    return switch (slice) {
      TimeSlice.overdue => diff < 0,
      TimeSlice.today => diff == 0,
      TimeSlice.week => diff > 0 && diff <= 7,
      TimeSlice.all => true,
    };
  }

  if (slice == TimeSlice.overdue) return due.isBefore(now);
  if (slice == TimeSlice.today) {
    return !due.isBefore(now) && _dayOf(due) == today;
  }
  if (slice == TimeSlice.week) {
    final diff = _dayOf(due).difference(today).inDays;
    return diff > 0 && diff <= 7;
  }
  return true;
}

/// 把「今天 / 本周 / 逾期」应用到已经摊平的行上：
/// 留下匹配的任务，并保留它们的祖先组（否则任务会突然变成孤儿一级行）。
/// 空组仍然显示（组本身也是一个视角，计数照算）。
List<NodeRow> filterRows(List<NodeRow> rows, TimeSlice slice, DateTime now) {
  if (slice == TimeSlice.all) return rows;
  final byId = {for (final r in rows) r.id: r};
  final keepTasks = <String>{};
  final keepGroups = <String>{};
  for (final row in rows) {
    if (row.isGroup) continue;
    if (!inSlice(row.node, slice, now)) continue;
    keepTasks.add(row.id);
    var parentId = row.node.parentId;
    var guard = 0;
    while (parentId != null && guard < 4) {
      keepGroups.add(parentId);
      parentId = byId[parentId]?.node.parentId;
      guard++;
    }
  }
  return _sortByTime([
    for (final row in rows)
      if (row.isGroup
          ? keepGroups.contains(row.id)
          : keepTasks.contains(row.id))
        row,
  ], slice);
}

/// 某个切片里有几条任务（1.38：给「逾期」标签显示数字）。
int countInSlice(List<NodeRow> rows, TimeSlice slice, DateTime now) {
  var count = 0;
  for (final row in rows) {
    if (row.isGroup) continue;
    if (inSlice(row.node, slice, now)) count++;
  }
  return count;
}
/// 「今天 / 本周」里，同一层的精确任务按时刻升序，全天任务排在最后。
/// 组的相对位置不动，只重排同一层里的任务槽位——这样树结构不会被拆散。
List<NodeRow> _sortByTime(List<NodeRow> rows, TimeSlice slice) {
  if (slice != TimeSlice.today && slice != TimeSlice.week) return rows;

  final byParent = <String?, List<NodeRow>>{};
  for (final row in rows) {
    byParent.putIfAbsent(row.node.parentId, () => []).add(row);
  }

  final sortedTasks = <String, List<NodeRow>>{};
  for (final entry in byParent.entries) {
    final tasks = entry.value.where((r) => !r.isGroup).toList()
      ..sort(_compareByTime);
    sortedTasks[entry.key.toString()] = tasks;
  }

  final cursor = <String, int>{};
  final out = <NodeRow>[];
  for (final row in rows) {
    if (row.isGroup) {
      out.add(row);
      continue;
    }
    final key = row.node.parentId.toString();
    final index = cursor[key] ?? 0;
    cursor[key] = index + 1;
    out.add(sortedTasks[key]![index]);
  }
  return out;
}

int _compareByTime(NodeRow a, NodeRow b) {
  final pa = DuePrecision.fromCode(a.node.duePrecision);
  final pb = DuePrecision.fromCode(b.node.duePrecision);
  if (pa != pb) return pa == DuePrecision.dateTime ? -1 : 1;
  final da = dueOf(a.node);
  final db = dueOf(b.node);
  if (da != null && db != null && da != db) return da.compareTo(db);
  return 0;
}

/// 时间文案。所有分支都从「绝对时长」出发，不写「还剩」「赶快」这类催促词。
String formatDue(TaskState task, DateTime now) {
  final due = dueOf(task);
  if (due == null) return '';
  final precision = DuePrecision.fromCode(task.duePrecision);
  final today = _dayOf(now);

  if (isOverdue(task, now)) {
    final int days;
    if (precision == DuePrecision.date) {
      days = today.difference(_dayOf(due)).inDays;
    } else {
      final hours = now.difference(due).inHours;
      days = (hours / 24).ceil().clamp(1, 1 << 20);
    }
    return '逾期 $days 天';
  }

  if (precision == DuePrecision.date) {
    final dueDay = _dayOf(due);
    final diff = dueDay.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == 2) return '后天';
    if (diff > 2 && diff < 7) return '$diff 天后';
    return _formatDate(dueDay, today);
  }

  final left = due.difference(now);
  if (left.inMinutes < 60) {
    final minutes = left.inMinutes < 1 ? 1 : left.inMinutes;
    return '$minutes 分钟后';
  }
  if (left.inHours < 24) {
    return '${left.inHours + (left.inMinutes % 60 > 0 ? 1 : 0)} 小时后';
  }
  if (left.inDays < 7) {
    final days = left.inDays;
    final hours = left.inHours % 24;
    if (hours > 0) return '$days 天 $hours 小时后';
    return '$days 天后 ${_hhmm(due)}';
  }
  return _formatDate(_dayOf(due), today);
}

/// 日期文案：同年只写月日，跨年补年份（用户 1.31 特别要求的「年级时间」）。
String _formatDate(DateTime day, DateTime today) {
  if (day.year == today.year) return '${day.month}月${day.day}日';
  return '${day.year}年${day.month}月${day.day}日';
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
