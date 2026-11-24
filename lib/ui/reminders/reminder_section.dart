/// 设置页里的「提醒」一节（1.37，仅 Android 显示）。
///
/// 这里只放本机偏好与权限检查；具体的“什么时候响”由
/// `ReminderService` + `data/reminder.dart` 负责，二者都不依赖这个 Widget。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/reminder.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/platform/reminder_service.dart';

class ReminderSection extends StatefulWidget {
  const ReminderSection({super.key, required this.dao});

  final TaskDao dao;

  /// 只有 Android 有这个设置；桌面端整节隐藏。
  static bool get supported => ReminderService.instance.supported;

  @override
  State<ReminderSection> createState() => _ReminderSectionState();
}

class _ReminderSectionState extends State<ReminderSection> {
  final ReminderService _service = ReminderService.instance;
  ReminderSettings? _settings;
  bool? _notify;
  bool? _exact;

  bool get _visible => _service.supported;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_visible) return;
    final settings = await _service.readSettings(widget.dao);
    final notify = await _service.notificationsEnabled();
    final exact = await _service.exactAlarmsAllowed();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _notify = notify;
      _exact = exact;
    });
  }

  Future<void> _save({bool? enabled, int? lead, String? allDay}) async {
    await _service.writeSettings(
      widget.dao,
      enabled: enabled,
      defaultLead: lead,
      allDayTime: allDay,
    );
    if (enabled == false) await _service.cancelAll();
    await _load();
  }

  Future<void> _pickLead() async {
    final current = _settings?.defaultLead ?? ReminderLead.fifteen;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) {
        var selected = current;
        return StatefulBuilder(
          builder: (ctx, setInner) => AlertDialog(
            title: const Text('默认提前多久提醒'),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    if (v != null) setInner(() => selected = v);
                  },
                  child: Column(
                    children: [
                      for (final lead in ReminderLead.choices)
                        RadioListTile<int>(
                          value: lead,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(ReminderLead.label(lead)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null) await _save(lead: picked);
  }

  Future<void> _pickAllDayTime() async {
    final s = _settings;
    if (s == null) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: s.allDayHour, minute: s.allDayMinute),
      helpText: '全天任务在这一刻提醒',
    );
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    await _save(allDay: text);
  }

  Future<void> _fixNotifications() async {
    await _service.requestNotifications();
    final ok = await _service.notificationsEnabled();
    if (!mounted) return;
    if (!ok) {
      await _service.openSystemSettings();
    }
    await _load();
  }

  Future<void> _fixExact() async {
    await _service.requestExactAlarms();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final s = _settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            '提醒',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('开启提醒'),
                subtitle: const Text('到点由手机通知你；电脑不会弹'),
                value: s?.enabled ?? false,
                onChanged: s == null
                    ? null
                    : (v) async {
                        await _save(enabled: v);
                        if (v) await _fixNotifications();
                      },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('默认提前量'),
                subtitle: const Text('任务和组上没单独设置时用它'),
                trailing: Text(
                  ReminderLead.label(s?.defaultLead ?? ReminderLead.fifteen),
                ),
                onTap: s == null ? null : _pickLead,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: const Text('全天任务的提醒时间'),
                subtitle: const Text('只到日期的任务，在这一刻提醒'),
                trailing: Text(s?.allDayText ?? '09:00'),
                onTap: s == null ? null : _pickAllDayTime,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: const Text('通知权限'),
                subtitle: Text(_notify == true ? '已允许' : '未允许，点这里去开启'),
                trailing: Icon(
                  _notify == true ? Icons.check_circle : Icons.error_outline,
                  color: _notify == true
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                onTap: _fixNotifications,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.alarm_on_outlined),
                title: const Text('精确闹钟'),
                subtitle: Text(
                  _exact == true ? '已允许，能准点响' : '未允许，可能会晚几分钟',
                ),
                trailing: Icon(
                  _exact == true ? Icons.check_circle : Icons.error_outline,
                  color: _exact == true
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                onTap: _fixExact,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(
            '小米/红米请在系统设置里给 PNote 开「自启动」和「省电无限制」，'
            '否则深度休眠时提醒可能延迟。App 被强行停止后，需要再打开一次。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
