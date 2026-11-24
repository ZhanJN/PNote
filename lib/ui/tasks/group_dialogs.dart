import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/models.dart';
import 'package:pnote/ui/tasks/group_tile.dart';

/// 「移动到顶层」的返回值。用哨兵而不是 null，因为 null 表示「用户取消」。
const String kMoveToTop = '__top__';

/// 新建 / 改名分组：名字 + 8 色选一个。
///
/// 返回 null = 取消；返回记录 = 名字与颜色下标。
Future<({String name, int color})?> showGroupNameDialog(
  BuildContext context, {
  String title = '新建分组',
  String initialName = '',
  int initialColor = 0,
}) {
  return showDialog<({String name, int color})>(
    context: context,
    builder: (_) => _GroupNameDialog(
      title: title,
      initialName: initialName,
      initialColor: initialColor,
    ),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({
    required this.title,
    required this.initialName,
    required this.initialColor,
  });

  final String title;
  final String initialName;
  final int initialColor;

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);
  late int _color = widget.initialColor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, color: _color));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 60,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '名字',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text('颜色', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < kGroupPalette.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _color = i),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: groupColor(i),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == i ? scheme.onSurface : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: _color == i
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

/// 删除分组：说清连带范围，默认**不勾**连带子组/任务。
///
/// 用户明确要求：「删组说清连带范围且默认不勾连带子组，并提供内容上移后
/// 删空壳的退路」。
Future<bool?> showDeleteGroupDialog(
  BuildContext context, {
  required String name,
  required int tasks,
  required int groups,
}) {
  final children = tasks + groups;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      var cascade = false;
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('删除分组'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('「$name」：$tasks 个任务、$groups 个子组。'),
                const SizedBox(height: 12),
                if (children == 0)
                  const Text('空组，删除后可在回收站找回。')
                else ...[
                  const Text('默认只删这个组，里面的内容上移到上一层。'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: cascade,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('连内容一起删'),
                    subtitle: const Text('可在回收站找回'),
                    onChanged: (v) => setState(() => cascade = v ?? false),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, cascade),
                child: const Text('删除'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 移动到…：顶层 + 所有可作为目标的一级组，单选。
///
/// [targets] 由调用方过滤好（不含自己、不含自己的子孙）。
/// 返回 [kMoveToTop] / 组 id / null（取消）。
Future<String?> showMoveDialog(
  BuildContext context, {
  required String nodeName,
  required NodeTargets targets,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('移动到…'),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('顶层（不放进任何组）'),
                onTap: () => Navigator.pop(dialogContext, kMoveToTop),
              ),
              const Divider(height: 1),
              for (final g in targets.groups)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.folder_rounded,
                    color: groupColor(g.color),
                  ),
                  title: Text(g.title),
                  onTap: () => Navigator.pop(dialogContext, g.id),
                ),
              if (targets.groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('还没有可移入的组，先建一个吧。'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
}

/// 移动对话框的目标集合（避免 UI 层再算一遍层级规则）。
class NodeTargets {
  const NodeTargets(this.groups);

  final List<TaskState> groups;
}
