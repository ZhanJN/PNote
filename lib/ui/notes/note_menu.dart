/// 笔记行的菜单（1.45）。
///
/// 和待办页的任务菜单同一套手感（`task_menu.dart`）：
///   ① 手机长按抬手 → 菜单弹在手指位置；
///   ② 电脑右键 → 菜单弹在鼠标位置；
///   ③ 行尾 ⋮ → 没有指针坐标，贴着行右下角弹。
///
/// 菜单里只有笔记真正有的动作：打开、改标题、插入素材、在文件夹中显示、
/// 多选、删除（移到 `.trash`）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/ui/tasks/task_menu.dart';

/// 一行笔记的菜单动作。
enum NoteMenuAction {
  open,
  rename,
  asset,
  moveToGroup,
  pin,
  reveal,
  multiSelect,
  delete,
}

/// 弹出某一行的笔记菜单。
///
/// [canReveal] 为 false 时（比如拿不到笔记载体）不显示「在文件夹中显示」。
/// [pinned] 为真时显示「取消置顶」，否则显示「置顶到组内最前」。
Future<NoteMenuAction?> showNoteMenu({
  required BuildContext context,
  required NoteFile note,
  required TaskMenuAnchor anchor,
  required bool canReveal,
  bool pinned = false,
}) {
  final geo = menuRectFor(
    context,
    anchor,
    (canReveal ? 396.0 : 348.0),
  );
  return showMenu<NoteMenuAction>(
    context: context,
    position: geo,
    items: [
      const PopupMenuItem(
        value: NoteMenuAction.open,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.article_outlined),
          title: Text('打开'),
        ),
      ),
      const PopupMenuItem(
        value: NoteMenuAction.rename,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.edit_outlined),
          title: Text('改标题'),
        ),
      ),
      const PopupMenuItem(
        value: NoteMenuAction.asset,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.attach_file),
          title: Text('插入素材…'),
        ),
      ),
      const PopupMenuItem(
        value: NoteMenuAction.moveToGroup,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.drive_file_move_outline),
          title: Text('移动到组…'),
        ),
      ),
      PopupMenuItem(
        value: NoteMenuAction.pin,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.push_pin_outlined),
          title: Text(pinned ? '取消置顶' : '置顶到组内最前'),
        ),
      ),
      if (canReveal)
        const PopupMenuItem(
          value: NoteMenuAction.reveal,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_outlined),
            title: Text('在文件夹中显示'),
          ),
        ),
      const PopupMenuItem(
        value: NoteMenuAction.multiSelect,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.checklist),
          title: Text('多选'),
        ),
      ),
      const PopupMenuItem(
        value: NoteMenuAction.delete,
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
