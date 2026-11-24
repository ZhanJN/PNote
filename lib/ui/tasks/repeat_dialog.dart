import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/repeat.dart';

/// 对话框的返回值：`rule == null` 表示「不重复」（清除规则）。
class RepeatChoice {
  const RepeatChoice(this.rule);

  final RepeatRule? rule;
}

/// 设置/修改重复规则（1.34；1.35 加自定义）。
///
/// 用户填：多久一次、间隔几个、自定义部分（每周哪几天 / 每月几号或第几个
/// 周几或月末 / 每年月日）、什么时候结束。
/// 「下一期从哪天算」永远沿用任务原来的时间（[hasDue] 为 false 时不允许保存），
/// [due] 用来给自定义控件一个合理的默认值。
Future<RepeatChoice?> showRepeatDialog(
  BuildContext context, {
  RepeatRule? current,
  required bool hasDue,
  DateTime? due,
}) {
  return showDialog<RepeatChoice>(
    context: context,
    builder: (_) => _RepeatDialog(current: current, hasDue: hasDue, due: due),
  );
}

class _RepeatDialog extends StatefulWidget {
  const _RepeatDialog({
    required this.current,
    required this.hasDue,
    required this.due,
  });

  final RepeatRule? current;
  final bool hasDue;
  final DateTime? due;

  @override
  State<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends State<_RepeatDialog> {
  late RepeatFreq _freq;
  late int _interval;
  late RepeatEndType _end;
  late int _count;
  late DateTime? _until;

  late Set<int> _weekdays;
  late MonthlyMode _monthlyMode;
  late int _monthDay;
  late int _nth;
  late int _nthWeekday;
  late int _month;
  late int _yearDay;

  DateTime get _dueDefault => widget.due ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final rule = widget.current;
    final due = _dueDefault;
    _freq = rule?.freq ?? RepeatFreq.daily;
    _interval = rule?.interval ?? 1;
    _end = rule?.end ?? RepeatEndType.never;
    _count = rule?.endCount ?? 3;
    _until = _parseDay(rule?.endUntil);

    _weekdays = rule != null && rule.weekdays.isNotEmpty
        ? rule.weekdays.toSet()
        : {due.weekday};
    _monthlyMode = rule?.monthlyMode ?? MonthlyMode.day;
    _monthDay = rule?.monthDay ?? due.day;
    _nth = rule?.nth ?? 1;
    _nthWeekday = rule?.nthWeekday ?? due.weekday;
    _month = rule?.month ?? due.month;
    _yearDay = rule?.day ?? due.day;
  }

  static DateTime? _parseDay(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  String _untilText(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = _freq.unit;

    return AlertDialog(
      title: const Text('重复'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.hasDue)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '先给任务设置时间，才能设置重复。',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              Text('多久一次', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in RepeatFreq.values)
                    ChoiceChip(
                      label: Text(switch (f) {
                        RepeatFreq.daily => '每天',
                        RepeatFreq.weekly => '每周',
                        RepeatFreq.monthly => '每月',
                        RepeatFreq.yearly => '每年',
                      }),
                      selected: _freq == f,
                      onSelected: (_) => setState(() => _freq = f),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('间隔', style: theme.textTheme.labelLarge),
                  IconButton(
                    tooltip: '减少间隔',
                    onPressed: _interval > 1
                        ? () => setState(() => _interval -= 1)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('每 $_interval $unit'),
                  IconButton(
                    tooltip: '增加间隔',
                    onPressed: _interval < 12
                        ? () => setState(() => _interval += 1)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              if (_freq != RepeatFreq.daily) ...[
                const Divider(),
                ..._customSection(theme),
              ],
              const Divider(),
              Text('什么时候结束', style: theme.textTheme.labelLarge),
              // Flutter 3.32 起 RadioListTile 的 groupValue/onChanged 被弃用，
              // 选中值交给外层 RadioGroup（与设置页同一套写法）。
              RadioGroup<RepeatEndType>(
                groupValue: _end,
                onChanged: (v) {
                  if (v != null) setState(() => _end = v);
                },
                child: Column(
                  children: [
                    const RadioListTile<RepeatEndType>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: RepeatEndType.never,
                      title: Text('永不结束'),
                    ),
                    RadioListTile<RepeatEndType>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: RepeatEndType.count,
                      title: Row(
                        children: [
                          const Text('共'),
                          IconButton(
                            tooltip: '减少期数',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                            onPressed: _count > 1
                                ? () => setState(() => _count -= 1)
                                : null,
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 18),
                          ),
                          Text('$_count 期'),
                          IconButton(
                            tooltip: '增加期数',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                            onPressed: _count < 999
                                ? () => setState(() => _count += 1)
                                : null,
                            icon: const Icon(Icons.add_circle_outline, size: 18),
                          ),
                        ],
                      ),
                      subtitle: const Text('含第一期'),
                    ),
                    RadioListTile<RepeatEndType>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: RepeatEndType.until,
                      title: Row(
                        children: [
                          const Text('到'),
                          TextButton(
                            onPressed: _pickUntil,
                            child: Text(
                              _until == null ? '选择日期' : _untilText(_until!),
                            ),
                          ),
                          const Text('为止'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _preview(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const RepeatChoice(null)),
            child: const Text('不重复'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: widget.hasDue &&
                  (_end != RepeatEndType.until || _until != null)
              ? _save
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }

  List<Widget> _customSection(ThemeData theme) {
    switch (_freq) {
      case RepeatFreq.daily:
        return const [];

      case RepeatFreq.weekly:
        return [
          Text('重复在', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  label: Text(kWeekdayNames[day - 1]),
                  selected: _weekdays.contains(day),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _weekdays.add(day);
                    } else if (_weekdays.length > 1) {
                      _weekdays.remove(day);
                    }
                  }),
                ),
            ],
          ),
        ];

      case RepeatFreq.monthly:
        return [
          Text('每月按', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('几号'),
                selected: _monthlyMode == MonthlyMode.day,
                onSelected: (_) =>
                    setState(() => _monthlyMode = MonthlyMode.day),
              ),
              ChoiceChip(
                label: const Text('第几个周几'),
                selected: _monthlyMode == MonthlyMode.nthWeekday,
                onSelected: (_) =>
                    setState(() => _monthlyMode = MonthlyMode.nthWeekday),
              ),
              ChoiceChip(
                label: const Text('月末'),
                selected: _monthlyMode == MonthlyMode.lastDay,
                onSelected: (_) =>
                    setState(() => _monthlyMode = MonthlyMode.lastDay),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_monthlyMode == MonthlyMode.day)
            Row(
              children: [
                const Text('日期'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _monthDay,
                  items: [
                    for (var d = 1; d <= 31; d++)
                      DropdownMenuItem(value: d, child: Text('$d 号')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _monthDay = v);
                  },
                ),
              ],
            ),
          if (_monthlyMode == MonthlyMode.nthWeekday)
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<int>(
                  value: _nth,
                  items: [
                    for (var n = 1; n <= 5; n++)
                      DropdownMenuItem(
                          value: n, child: Text('第${_cn(n)}个')),
                    const DropdownMenuItem(value: -1, child: Text('最后一个')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _nth = v);
                  },
                ),
                DropdownButton<int>(
                  value: _nthWeekday,
                  items: [
                    for (var d = 1; d <= 7; d++)
                      DropdownMenuItem(
                          value: d, child: Text('周${kWeekdayNames[d - 1]}')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _nthWeekday = v);
                  },
                ),
              ],
            ),
          if (_monthlyMode == MonthlyMode.lastDay)
            const Text('每月最后一天'),
        ];

      case RepeatFreq.yearly:
        return [
          Text('每年在', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<int>(
                value: _month,
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text('$m 月')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _month = v;
                      _yearDay = _yearDay.clamp(1, _daysInMonth(v));
                    });
                  }
                },
              ),
              DropdownButton<int>(
                value: _yearDay.clamp(1, _daysInMonth(_month)),
                items: [
                  for (var d = 1; d <= _daysInMonth(_month); d++)
                    DropdownMenuItem(value: d, child: Text('$d 日')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _yearDay = v);
                },
              ),
            ],
          ),
        ];
    }
  }

  static int _daysInMonth(int month) => DateTime(2024, month + 1, 0).day;

  String _cn(int n) => const ['', '一', '二', '三', '四', '五'][n.clamp(0, 5)];

  String _preview() {
    if (!widget.hasDue) return '';
    final rule = _buildRule();
    final next = nextDueAfter(_dueDefault, rule);
    if (next == null) return '';
    return '${describeRepeat(rule)} · 下一期 ${next.month}月${next.day}日';
  }

  RepeatRule _buildRule() {
    var weekdays = <int>[];
    if (_freq == RepeatFreq.weekly) {
      final selected = _weekdays.toList()..sort();
      // 只选「原来那天」等于旧默认行为，不写进 JSON，保证 1.34 的 id 不变。
      final isDefault = widget.due != null &&
          selected.length == 1 &&
          selected.first == widget.due!.weekday;
      if (!isDefault) weekdays = selected;
    }

    int? monthDay;
    if (_freq == RepeatFreq.monthly && _monthlyMode == MonthlyMode.day) {
      final isDefault = widget.due != null && _monthDay == widget.due!.day;
      if (!isDefault) monthDay = _monthDay;
    }

    int? month;
    int? day;
    if (_freq == RepeatFreq.yearly) {
      final isDefault = widget.due != null &&
          _month == widget.due!.month &&
          _yearDay == widget.due!.day;
      if (!isDefault) {
        month = _month;
        day = _yearDay.clamp(1, _daysInMonth(_month));
      }
    }

    return RepeatRule(
      freq: _freq,
      interval: _interval,
      end: _end,
      endCount: _count,
      endUntil: _end == RepeatEndType.until && _until != null
          ? '${_until!.year.toString().padLeft(4, '0')}-'
              '${_until!.month.toString().padLeft(2, '0')}-'
              '${_until!.day.toString().padLeft(2, '0')}'
          : null,
      weekdays: weekdays,
      monthlyMode: _freq == RepeatFreq.monthly ? _monthlyMode : MonthlyMode.day,
      monthDay: monthDay,
      nth: _freq == RepeatFreq.monthly &&
              _monthlyMode == MonthlyMode.nthWeekday
          ? _nth
          : null,
      nthWeekday: _freq == RepeatFreq.monthly &&
              _monthlyMode == MonthlyMode.nthWeekday
          ? _nthWeekday
          : null,
      month: month,
      day: day,
    );
  }

  Future<void> _pickUntil() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _until ?? now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _until = picked);
  }

  void _save() {
    Navigator.of(context).pop(RepeatChoice(_buildRule()));
  }
}

/// 让 UI 拿到「下一期会是哪天」的文案（预览用，可选）。
String repeatPreviewText(RepeatRule rule, DateTime? due, DateTime now) {
  if (due == null) return '';
  final next = nextDueAfter(due, rule);
  if (next == null) return '';
  return '下一期：${next.month}月${next.day}日';
}
