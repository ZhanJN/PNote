import 'package:material_ui/material_ui.dart';

/// 改标题的对话框。
///
/// 单独做成 StatefulWidget 的唯一原因：`TextEditingController` 必须由
/// 「还在树上」的对象持有。早期版本在 `showDialog` 的 Future 返回后立刻
/// `controller.dispose()`，而此时对话框的退场动画还在跑、TextField 仍然
/// 挂在树上，于是触发 Flutter 框架断言
/// `framework.dart: '_dependents.isEmpty': is not true.` 并崩溃。
/// 现在表单项用 [TextFormField] 的 initialValue + onChanged，完全不持有
/// controller，从根上避免「用了已释放的 controller」。
class RenameDialog extends StatefulWidget {
  const RenameDialog({
    super.key,
    required this.initialTitle,
    this.title = '改标题',
  });

  final String initialTitle;

  /// 对话框标题：新建任务时可以传「新建任务」。
  final String title;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late String _draft = widget.initialTitle;

  void _submit() => Navigator.of(context).pop(_draft);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextFormField(
        initialValue: widget.initialTitle,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: '标题'),
        onChanged: (v) => _draft = v,
        onFieldSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
