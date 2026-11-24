/// 「提醒…」对话框（1.37）。
///
/// 任务与组共用：任务上是「这条任务的提醒」，组上是「组里任务的默认提醒」。
/// 选项是固定档位（用户 1.37 定的），不做自由输入。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/reminder.dart';

/// 对话框结果。[lead] 为 null 表示「跟随上一层」，-1 表示关闭。
class ReminderChoice {
  const ReminderChoice(this.lead);

  final int? lead;
}

Future<ReminderChoice?> showReminderDialog(
  BuildContext context, {
  required String title,
  required String followLabel,
  required int? current,
  bool showDueWarning = false,
}) {
  return showDialog<ReminderChoice>(
    context: context,
    builder: (ctx) => _ReminderDialog(
      title: title,
      followLabel: followLabel,
      current: current,
      showDueWarning: showDueWarning,
    ),
  );
}

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({
    required this.title,
    required this.followLabel,
    required this.current,
    required this.showDueWarning,
  });

  final String title;
  final String followLabel;
  final int? current;
  final bool showDueWarning;

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  late int? _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showDueWarning)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    '这个任务还没有时间；设了提醒，也要等设上时间后才会响。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              RadioGroup<int?>(
                groupValue: _selected,
                onChanged: (value) => setState(() => _selected = value),
                child: Column(
                  children: [
                    RadioListTile<int?>(
                      value: null,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(widget.followLabel),
                    ),
                    for (final lead in ReminderLead.choices)
                      RadioListTile<int?>(
                        value: lead,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(ReminderLead.label(lead)),
                      ),
                    RadioListTile<int?>(
                      value: ReminderLead.off,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(ReminderLead.label(ReminderLead.off)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(ReminderChoice(_selected)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
