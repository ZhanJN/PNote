/// 改账号的对话框（1.51）。
///
/// 交互刻意做得像「改个名字」而不是「登录」：没有密码框、没有验证按钮，
/// 只有一个名字输入框和两个常用选项。用户 2026-11-24 明确要求：
/// 「只需要填同一个名字就算，不要任何其他验证手段」。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/sync/account.dart';

/// 返回新账号名；取消返回 null。
///
/// [lastPrivate] 是上次用过的非公开账号名：当前在「公开同步」时，输入框
/// 预填它，点保存即可切回去（1.52）。
Future<String?> showAccountDialog(
  BuildContext context, {
  required String current,
  String lastPrivate = kDefaultAccount,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AccountDialog(
      current: normalizeAccount(current),
      lastPrivate: normalizeAccount(lastPrivate),
    ),
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({required this.current, required this.lastPrivate});

  final String current;
  final String lastPrivate;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _name = TextEditingController(
    text: accountDraft(widget.current, widget.lastPrivate),
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _pick(String preset) {
    _name.text = preset;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = normalizeAccount(_name.text);
    final public = isPublicAccount(draft);

    return AlertDialog(
      title: const Text('账号'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '只有账号名相同的设备才会互相同步。没有密码，也没有别的验证。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              maxLength: kAccountMaxLength,
              decoration: const InputDecoration(
                labelText: '账号名',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(widget.lastPrivate),
                  selected: draft == widget.lastPrivate,
                  onSelected: (_) => _pick(widget.lastPrivate),
                ),
                ChoiceChip(
                  label: const Text(kPublicAccount),
                  selected: draft == kPublicAccount,
                  onSelected: (_) => _pick(kPublicAccount),
                ),
              ],
            ),
            if (public) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '「公开同步」会把你的任务和笔记同步给同一个 Wi‑Fi 下'
                  '任何也选了这个名字的设备。用完记得换回自己的账号。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: draft.isEmpty
              ? null
              : () => Navigator.of(context).pop(draft),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
