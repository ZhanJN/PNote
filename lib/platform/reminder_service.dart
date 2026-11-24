/// 手机端提醒的“总开关 + 排班”（1.37）。
///
/// 为什么单独放在 platform/：它依赖 Android 插件，不能在数据层 import，
/// 也不能让 sync/ 依赖它（架构铁律：data 不 import Flutter）。
/// 桌面端（Windows）直接跳过 —— 用户明确要求「电脑不需要通知」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:pnote/data/models.dart';
import 'package:pnote/data/reminder.dart';
import 'package:pnote/data/task_dao.dart';

class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _broken = false;
  bool _syncing = false;

  /// 只有 Android 才有提醒；测试跑在 Windows 上也会走到这里，直接跳过。
  bool get supported => !kIsWeb && Platform.isAndroid;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<bool> _ensureInit() async {
    if (_ready) return true;
    if (_broken || !supported) return false;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
      return true;
    } catch (e) {
      _broken = true;
      debugPrint('[remind] init failed: $e');
      return false;
    }
  }

  /// 读本机偏好。没写过的键用默认值（开启、提前 15 分钟、全天 09:00）。
  Future<ReminderSettings> readSettings(TaskDao dao) async {
    final enabled = (await dao.readSetting('notify_enabled')) != '0';
    final lead =
        int.tryParse(await dao.readSetting('remind_default_lead') ?? '') ??
        ReminderLead.fifteen;
    final raw = await dao.readSetting('all_day_remind_time') ?? '09:00';
    final parts = raw.split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return ReminderSettings(
      enabled: enabled,
      defaultLead: lead,
      allDayHour: (hour ?? 9).clamp(0, 23),
      allDayMinute: (minute ?? 0).clamp(0, 59),
    );
  }

  Future<void> writeSettings(
    TaskDao dao, {
    bool? enabled,
    int? defaultLead,
    String? allDayTime,
  }) async {
    if (enabled != null) {
      await dao.writeSetting('notify_enabled', enabled ? '1' : '0');
    }
    if (defaultLead != null) {
      await dao.writeSetting('remind_default_lead', '$defaultLead');
    }
    if (allDayTime != null) {
      await dao.writeSetting('all_day_remind_time', allDayTime);
    }
  }

  /// 每次列表刷新（含同步、导入、启动）后调用：重算未来 30 天，多退少补。
  Future<void> syncFrom(List<TaskState> nodes, TaskDao dao) async {
    if (!supported || _syncing) return;
    _syncing = true;
    try {
      if (!await _ensureInit()) return;
      final settings = await readSettings(dao);
      if (!settings.enabled) {
        await _plugin.cancelAllPendingNotifications();
        return;
      }
      await _askPermissionOnce(dao);
      final specs = planReminders(
        nodes,
        settings: settings,
        now: DateTime.now(),
      );
      await _plugin.cancelAllPendingNotifications();
      if (specs.isEmpty) return;
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'pnote_reminders',
          '任务提醒',
          channelDescription: '任务到点提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      for (final spec in specs) {
        await _schedule(spec, details);
      }
    } catch (e) {
      debugPrint('[remind] sync failed: $e');
    } finally {
      _syncing = false;
    }
  }

  Future<void> _schedule(ReminderSpec spec, NotificationDetails details) async {
    final date = tz.TZDateTime.from(spec.at, tz.UTC);
    try {
      await _plugin.zonedSchedule(
        id: spec.id,
        title: spec.title,
        body: spec.body,
        scheduledDate: date,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: spec.taskId,
      );
    } on PlatformException {
      // 没有「精确闹钟」权限时退回不精确模式：可能晚几分钟，但不会不响。
      await _plugin.zonedSchedule(
        id: spec.id,
        title: spec.title,
        body: spec.body,
        scheduledDate: date,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: spec.taskId,
      );
    }
  }

  /// 第一次开启时问一次通知权限；之后由设置页里的按钮手动再问。
  Future<void> _askPermissionOnce(TaskDao dao) async {
    final asked = await dao.readSetting('notify_perm_asked') == '1';
    final enabled = await _android?.areNotificationsEnabled();
    if (asked || enabled == true) return;
    await dao.writeSetting('notify_perm_asked', '1');
    await _android?.requestNotificationsPermission();
  }

  Future<bool> notificationsEnabled() async =>
      (await _android?.areNotificationsEnabled()) ?? false;

  Future<bool> exactAlarmsAllowed() async =>
      (await _android?.canScheduleExactNotifications()) ?? false;

  Future<bool?> requestNotifications() async =>
      _android?.requestNotificationsPermission();

  Future<bool?> requestExactAlarms() async =>
      _android?.requestExactAlarmsPermission();

  Future<bool?> openSystemSettings() => _plugin.openAppNotificationSettings();

  Future<void> cancelAll() async {
    if (!supported) return;
    if (!await _ensureInit()) return;
    await _plugin.cancelAllPendingNotifications();
  }
}
