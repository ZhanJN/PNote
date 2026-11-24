/// 提醒规划（1.37）：把「任务 + 时间 + 提前量」算成一条条待排的通知。
///
/// 这个文件不碰插件、不碰数据库，只做纯计算，方便直接写单元测试
/// （与 due_time.dart 同一思路）。真正调 Android 闹钟的代码在
/// `lib/platform/reminder_service.dart`。
///
/// 三条规则来自用户 1.37 的需求：
///   1. 只提醒「有时间」的任务；提醒时刻 = 任务时间 − 提前量。
///   2. 提前量三层：单条任务 → 所在组 → 全局默认（15 分钟）。
///   3. 已经过去的提醒不补发；完成/删除/清时间后自然不再出现。
library;

import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';

/// 提前量（分钟）。用整数存库，-1 表示「关闭」，null 表示「跟随上一层」。
class ReminderLead {
  const ReminderLead._();

  static const int off = -1;
  static const int onTime = 0;
  static const int five = 5;
  static const int fifteen = 15;
  static const int thirty = 30;
  static const int hour = 60;
  static const int day = 1440;

  /// 菜单里可选的档位（不含「关闭」和「跟随」，那两个由界面单独处理）。
  static const List<int> choices = [onTime, five, fifteen, thirty, hour, day];

  static String label(int minutes) {
    if (minutes == off) return '关闭提醒';
    if (minutes == onTime) return '准时';
    if (minutes == hour) return '提前 1 小时';
    if (minutes == day) return '提前 1 天';
    return '提前 $minutes 分钟';
  }
}

/// 本机的提醒偏好（存 meta 表，不参与同步）。
class ReminderSettings {
  const ReminderSettings({
    this.enabled = true,
    this.defaultLead = ReminderLead.fifteen,
    this.allDayHour = 9,
    this.allDayMinute = 0,
  });

  final bool enabled;
  final int defaultLead;

  /// 全天任务默认在当天的这个时刻提醒。
  final int allDayHour;
  final int allDayMinute;

  String get allDayText =>
      '${allDayHour.toString().padLeft(2, '0')}:'
      '${allDayMinute.toString().padLeft(2, '0')}';
}

/// 一条排好的提醒。id 由任务 id + 提醒时刻算出来，重复排不会叠两条。
class ReminderSpec {
  const ReminderSpec({
    required this.taskId,
    required this.title,
    required this.body,
    required this.at,
    required this.id,
  });

  final String taskId;
  final String title;
  final String body;
  final DateTime at;
  final int id;
}

/// 生效的提前量：单条 → 所在组 → 全局默认。返回 null 表示不提醒。
int? effectiveLead(TaskState task, TaskState? group, int defaultLead) {
  if (task.isGroup) return null;
  final own = task.remindLead;
  if (own != null) return own == ReminderLead.off ? null : own;
  final fromGroup = group?.remindLead;
  if (fromGroup != null) return fromGroup == ReminderLead.off ? null : fromGroup;
  return defaultLead == ReminderLead.off ? null : defaultLead;
}

/// 提醒时刻（本地时间）。全天任务按「当天 [allDayHour]:[allDayMinute]」算。
DateTime? reminderAt(
  TaskState task, {
  required int lead,
  int allDayHour = 9,
  int allDayMinute = 0,
}) {
  final due = dueOf(task);
  if (due == null) return null;
  final base = DuePrecision.fromCode(task.duePrecision) == DuePrecision.date
      ? DateTime(due.year, due.month, due.day, allDayHour, allDayMinute)
      : due;
  return base.subtract(Duration(minutes: lead));
}

/// 算出 [now] 之后、[horizonDays] 天之内的所有提醒，按时间升序。
///
/// 传进来的是 `visibleTasks()` 的整批节点（含组），组只用来解析「组默认」。
List<ReminderSpec> planReminders(
  List<TaskState> nodes, {
  required ReminderSettings settings,
  required DateTime now,
  int horizonDays = 30,
}) {
  if (!settings.enabled) return const [];
  final byId = {for (final n in nodes) n.id: n};
  final horizon = now.add(Duration(days: horizonDays));
  final out = <ReminderSpec>[];
  for (final task in nodes) {
    if (task.isGroup || task.done || task.isDeleted) continue;
    final parent = task.parentId == null ? null : byId[task.parentId];
    final lead = effectiveLead(task, parent, settings.defaultLead);
    if (lead == null) continue;
    final at = reminderAt(
      task,
      lead: lead,
      allDayHour: settings.allDayHour,
      allDayMinute: settings.allDayMinute,
    );
    if (at == null || !at.isAfter(now) || at.isAfter(horizon)) continue;
    out.add(
      ReminderSpec(
        taskId: task.id,
        title: task.title,
        body: '${formatDue(task, now)}到期',
        at: at,
        id: reminderId(task.id, at),
      ),
    );
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// 稳定通知 id：同一任务同一时刻永远算出同一个数。
int reminderId(String taskId, DateTime at) {
  const int prime = 16777619;
  var hash = 2166136261;
  for (final code in '$taskId|${at.millisecondsSinceEpoch}'.codeUnits) {
    hash ^= code;
    hash = (hash * prime) & 0xFFFFFFFF;
  }
  final id = hash & 0x7FFFFFFF;
  return id == 0 ? 1 : id;
}
