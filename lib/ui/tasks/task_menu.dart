import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/models.dart';

/// 菜单要弹在哪里。1.23 起带上了「点在哪个位置」。
///
/// 为什么需要 [at]：电脑上右键菜单必须出现在鼠标那一点（用户反馈
/// 「菜单产生在相应位置而不是锁定在左侧」）；手机长按时就是手指的位置。
/// [rect] 仍然保留 —— 拿不到指针坐标时（比如行尾 ⋮ 按钮）用它兜底，
/// 并且菜单内容将来需要知道是哪一行。
class TaskMenuAnchor {
  const TaskMenuAnchor({required this.rect, this.at});

  /// 这一行在屏幕上的矩形。
  final Rect rect;

  /// 触发点（右键位置 / 长按抬起位置）。为空时按 [rect] 右下角算。
  final Offset? at;
}

/// 一行任务的菜单动作。1.24 起多了「移动到…」，1.29 起多了「多选」，
/// 1.31 起多了「设置时间…」，1.34 起多了「设置重复…」，1.37 起多了「提醒…」。
enum TaskMenuAction {
  rename,
  dueTime,
  remind,
  repeat,
  toggleDone,
  move,
  multiSelect,
  delete,
}

/// 一个分组的菜单动作。组没有完成/截止，所以菜单里没有「标记完成」。
enum GroupMenuAction {
  rename,
  newTask,
  newSubgroup,
  remind,
  move,
  multiSelect,
  delete,
}

/// 弹出某一行的任务菜单。
///
/// 三个入口共用它：①长按授予资格后抬手；②行尾的 ⋮ 按钮；③电脑上右键。
Future<TaskMenuAction?> showTaskMenu({
  required BuildContext context,
  required TaskState task,
  required TaskMenuAnchor anchor,
  bool canMove = false,
  bool canRemind = false,
}) {
  final geo = _Geometry.of(
    context,
    anchor,
    (canMove ? 336.0 : 291.0) + (canRemind ? 48.0 : 0),
  );
  return showMenu<TaskMenuAction>(
    context: context,
    position: geo.rect,
    items: [
      const PopupMenuItem(
        value: TaskMenuAction.rename,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.edit_outlined),
          title: Text('改标题'),
        ),
      ),
      PopupMenuItem(
        value: TaskMenuAction.dueTime,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule),
          title: Text(task.dueValue == null ? '设置时间…' : '修改时间…'),
        ),
      ),
      if (canRemind)
        PopupMenuItem(
          value: TaskMenuAction.remind,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_outlined),
            title: Text(task.remindLead == null ? '设置提醒…' : '修改提醒…'),
          ),
        ),
      PopupMenuItem(
        value: TaskMenuAction.repeat,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.repeat),
          title: Text(task.repeatRule == null ? '设置重复…' : '修改重复…'),
        ),
      ),
      PopupMenuItem(
        value: TaskMenuAction.toggleDone,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            task.done ? Icons.check_box_outlined : Icons.check_box_outline_blank,
          ),
          title: Text(task.done ? '标记为未完成' : '标记为完成'),
        ),
      ),
      if (canMove)
        const PopupMenuItem(
          value: TaskMenuAction.move,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.drive_file_move_outline),
            title: Text('移动到…'),
          ),
        ),
      const PopupMenuItem(
        value: TaskMenuAction.multiSelect,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.checklist),
          title: Text('多选'),
        ),
      ),
      const PopupMenuItem(
        value: TaskMenuAction.delete,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.delete_outline),
          title: Text('删除'),
        ),
      ),
    ],
  );
}

/// 弹出分组的菜单。位置规则与任务菜单完全一致。
Future<GroupMenuAction?> showGroupMenu({
  required BuildContext context,
  required TaskState group,
  required TaskMenuAnchor anchor,
  bool canAddSubgroup = true,
  bool canMove = true,
  bool canRemind = false,
}) {
  final geo = _Geometry.of(context, anchor, 260.0 + (canRemind ? 48.0 : 0));
  return showMenu<GroupMenuAction>(
    context: context,
    position: geo.rect,
    items: [
      const PopupMenuItem(
        value: GroupMenuAction.rename,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.edit_outlined),
          title: Text('改组名'),
        ),
      ),
      const PopupMenuItem(
        value: GroupMenuAction.newTask,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.add_task),
          title: Text('在这里新建任务'),
        ),
      ),
      if (canAddSubgroup)
        const PopupMenuItem(
          value: GroupMenuAction.newSubgroup,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('新建子组'),
          ),
        ),
      if (canRemind)
        const PopupMenuItem(
          value: GroupMenuAction.remind,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.notifications_outlined),
            title: Text('组提醒默认…'),
          ),
        ),
      if (canMove)
        const PopupMenuItem(
          value: GroupMenuAction.move,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.drive_file_move_outline),
            title: Text('移动到…'),
          ),
        ),
      const PopupMenuItem(
        value: GroupMenuAction.multiSelect,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.checklist),
          title: Text('多选'),
        ),
      ),
      const PopupMenuItem(
        value: GroupMenuAction.delete,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.delete_outline),
          title: Text('删除分组'),
        ),
      ),
    ],
  );
}

/// 给别的列表（比如笔记行，1.45）复用同一套弹出位置规则。
RelativeRect menuRectFor(
  BuildContext context,
  TaskMenuAnchor anchor,
  double menuHeight,
) =>
    _Geometry.of(context, anchor, menuHeight).rect;

/// 位置计算：有触发点就贴着那一点，没有就贴行右端；最后夹进屏幕。
class _Geometry {
  const _Geometry(this.rect);

  final RelativeRect rect;

  static _Geometry of(
    BuildContext context,
    TaskMenuAnchor anchor,
    double menuHeight,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject();
    final size =
        overlay is RenderBox ? overlay.size : MediaQuery.of(context).size;
    const menuWidth = 180.0;

    final at = anchor.at;
    double left;
    double top;
    if (at != null) {
      left = at.dx + 12;
      top = at.dy + 8;
    } else {
      left = anchor.rect.right - menuWidth;
      top = anchor.rect.bottom + 4;
    }
    left = left.clamp(8.0, (size.width - menuWidth - 8).clamp(8.0, size.width));
    top = top.clamp(
      8.0,
      (size.height - menuHeight - 8).clamp(8.0, size.height),
    );
    return _Geometry(
      RelativeRect.fromLTRB(left, top, size.width - left, 0),
    );
  }
}
