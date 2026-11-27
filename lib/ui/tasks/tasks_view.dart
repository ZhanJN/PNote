import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/reminder.dart';
import 'package:pnote/data/repeat.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/platform/reminder_service.dart';
import 'package:pnote/ui/tasks/group_dialogs.dart';
import 'package:pnote/ui/tasks/group_tile.dart';
import 'package:pnote/ui/common/horizontal_chip_bar.dart';
import 'package:pnote/ui/common/minute_refresh.dart';
import 'package:pnote/ui/reminders/reminder_dialog.dart';
import 'package:pnote/ui/common/rename_dialog.dart';
import 'package:pnote/ui/tasks/repeat_dialog.dart';
import 'package:pnote/ui/tasks/task_list_body.dart';
import 'package:pnote/ui/tasks/task_menu.dart';

/// 待办模块的**内容区**（不含顶栏、不含底栏、不含同步按钮）。
///
/// 1.17 起 App 变成「待办 + 笔记」两个模块，外壳（顶栏功能栏、底栏同步条）
/// 由 `HomePage` 负责，这里只画列表本身，所以没有 Scaffold。
/// 同步完成后由 HomePage 通过 GlobalKey 调 [TasksViewState.reload] 刷新。
///
/// 1.24（M12 分组）：列表先经 [flattenTree] 摊平成行，再交给 [TaskListBody]。
/// 组只是「视角」：不参与完成/截止，计数实时算，折叠状态也同步。
class TasksView extends StatefulWidget {
  const TasksView({super.key, required this.dao, this.onCountChanged});

  final TaskDao dao;

  /// 列表条数变化时通知外壳（底栏要显示「共 N 条」，只数任务不数组）。
  final ValueChanged<int>? onCountChanged;

  @override
  State<TasksView> createState() => TasksViewState();
}

class TasksViewState extends State<TasksView> with MinuteRefresh<TasksView> {
  final TextEditingController _input = TextEditingController();

  /// 数据库里的全部可见节点（任务 + 组）。
  List<TaskState> _nodes = const [];
  List<NodeRow> _rows = const [];
  bool _loading = true;
  bool _busy = false;

  /// 正在淡出的行（删除动画期间）。
  String? _removingId;

  /// 多选模式（1.29）：从行菜单的「多选」进入，勾选后批量移动/移入/删除。
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// 当前时间切片（1.31）：全部 / 今天 / 本周 / 逾期。只是视角，不落库。
  TimeSlice _slice = TimeSlice.all;

  /// 组视图（1.33）：选中哪个一级组，就只看这个组里的内容。
  /// 与时间切片互斥；组被删掉或被挪成二级组时自动退回「全部」。
  String? _groupViewId;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 供外壳（同步/导入/回收站返回后）调用。
  Future<void> reload() async {
    final nodes = await widget.dao.visibleTasks();
    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _rows = flattenTree(nodes);
      _loading = false;
      if (_selecting) {
        final alive = {for (final n in nodes) n.id};
        _selected.removeWhere((id) => !alive.contains(id));
      }
      final gid = _groupViewId;
      if (gid != null &&
          !nodes.any((n) => n.id == gid && n.isGroup && n.parentId == null)) {
        // 组被删掉，或被移进别的组（不再是一级组）：退回「全部」。
        _groupViewId = null;
      }
    });
    widget.onCountChanged
        ?.call(nodes.where((n) => !n.isGroup).length);
    // 1.37：每次列表刷新（启动、操作、同步、导入）后重排手机提醒。
    // 桌面端 ReminderService 内部直接返回，所以这里不用再判断平台。
    unawaited(ReminderService.instance.syncFrom(nodes, widget.dao));
  }

  /// 当前选中的组（组视图用）。不在组视图时是 null。
  TaskState? get _currentGroup {
    final gid = _groupViewId;
    if (gid == null) return null;
    for (final n in _nodes) {
      if (n.id == gid) return n;
    }
    return null;
  }

  /// 顶栏 chips 用的顺序：一级组按它们在列表里的上下顺序。
  List<TaskState> get _topGroups => [
        for (final n in _nodes)
          if (n.isGroup && n.parentId == null) n,
      ];

  /// 当前视角该画哪些行：组视图看组内，其余走时间切片。
  List<NodeRow> _displayRows() {
    final gid = _groupViewId;
    if (gid != null) return groupViewRows(_nodes, gid);
    return filterRows(_rows, _slice, DateTime.now());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    final title = _input.text.trim();
    if (title.isEmpty) return;
    await _run(() async {
      // 在组视图里添加，直接落进这个组；否则落在一级。
      await widget.dao.addTask(title, parentId: _groupViewId);
      _input.clear();
    });
  }

  /// 勾选/取消。
  ///
  /// 1.36 起，设置里开了「完成后自动移入回收站」时：勾完成的动作 = 先按
  /// 原规则完成（重复任务会生成下一期），再把这一条软删除，并给一次撤销。
  /// 取消完成不受影响。
  Future<void> _toggle(NodeRow row) async {
    final task = row.node;
    if (task.done) {
      await _run(() => widget.dao.setDone(task.id, false));
      return;
    }
    final auto = await widget.dao.readSetting('auto_delete_done') == '1';
    if (!auto || task.isGroup) {
      await _run(() => widget.dao.setDone(task.id, true));
      return;
    }
    await _run(() async {
      await widget.dao.setDone(task.id, true);
      await widget.dao.softDeleteMany([task.id]);
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('已完成，移入回收站'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoArchive(task.id),
          ),
        ),
      );
  }

  /// 撤销「完成即归档」：先恢复回列表，再退回未完成。
  /// 恢复只动 deleted_at/parent/order；取消完成只写 done，两者互不覆盖。
  Future<void> _undoArchive(String id) => _run(() async {
        await widget.dao.restoreTask(id);
        await widget.dao.setDone(id, false);
      });

  /// 删除：先让这一行 160 ms 淡出，再真正落库（数据变化属于「推荐」类动效）。
  /// 系统要求「减少动态效果」时直接删，不做过渡。
  Future<void> _delete(TaskState task) async {
    if (_busy) return;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      await _run(() => widget.dao.softDelete(task.id));
      return;
    }
    setState(() => _removingId = task.id);
    await Future<void>.delayed(const Duration(milliseconds: 160));
    try {
      await _run(() => widget.dao.softDelete(task.id));
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
  }

  Future<void> _edit(TaskState task) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initialTitle: task.title),
    );
    if (result == null || result.trim().isEmpty) return;
    await _run(() => widget.dao.renameTask(task.id, result));
  }

  // ------------------------------------------------------------- 时间

  /// 设置/修改/清除任务时间（1.31）。精度三档：全天、日期+时刻、清除。
  /// 设置/修改重复规则（1.34）。规则必须挂在有时间任务上。
  Future<void> _setRepeat(TaskState task) async {
    if (_busy) return;
    final current = parseRepeatRule(task.repeatRule);
    final choice = await showRepeatDialog(
      context,
      current: current,
      hasDue: dueOf(task) != null,
      due: dueOf(task),
    );
    if (choice == null || !mounted) return;
    await _run(() => widget.dao.setRepeat(task.id, choice.rule));
  }

  /// 设置提醒（1.37）：任务上设单条提前量，组上设「组里任务的默认」。
  Future<void> _setReminder(TaskState node) async {
    if (_busy) return;
    final settings = await ReminderService.instance.readSettings(widget.dao);
    if (!mounted) return;
    TaskState? group;
    if (node.parentId != null) {
      for (final n in _nodes) {
        if (n.id == node.parentId) {
          group = n;
          break;
        }
      }
    }
    final inherited = group?.remindLead ?? settings.defaultLead;
    final followLabel = inherited == ReminderLead.off
        ? '跟随默认（关闭）'
        : '跟随默认（${ReminderLead.label(inherited)}）';
    final choice = await showReminderDialog(
      context,
      title: node.isGroup ? '组提醒默认' : '提醒',
      followLabel: node.isGroup
          ? '跟随全局默认（${ReminderLead.label(settings.defaultLead)}）'
          : followLabel,
      current: node.remindLead,
      showDueWarning: !node.isGroup && dueOf(node) == null,
    );
    if (choice == null || !mounted) return;
    await _run(() => widget.dao.setRemindLead(node.id, choice.lead));
  }

  Future<void> _setDue(TaskState task) async {
    if (_busy) return;
    final existing = dueOf(task);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (existing != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清除时间'),
                onTap: () => Navigator.of(ctx).pop('clear'),
              ),
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: const Text('只到日期（全天）'),
              subtitle: const Text('当天出现，不显示具体时刻'),
              onTap: () => Navigator.of(ctx).pop('date'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('日期 + 时刻'),
              subtitle: const Text('可以排序，也可以提醒'),
              onTap: () => Navigator.of(ctx).pop('datetime'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'clear') {
      await _run(() => widget.dao.clearDue(task.id));
      return;
    }

    final now = DateTime.now();
    final base = existing ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;

    if (choice == 'date') {
      final at = DateTime(date.year, date.month, date.day);
      await _run(
        () => widget.dao.setDue(
          task.id,
          at: at,
          precision: DuePrecision.date,
        ),
      );
      return;
    }

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    final at = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _run(
      () => widget.dao.setDue(
        task.id,
        at: at,
        precision: DuePrecision.dateTime,
      ),
    );
  }

  /// 折叠的组里若有「24 小时内」或「已逾期」的任务，组行要亮小红点（1.38 起含逾期）。
  Set<String> _urgentGroups(DateTime now) {
    final out = <String>{};
    for (final group in _nodes) {
      if (!group.isGroup || !group.collapsed) continue;
      final descendants = descendantIds(_nodes, group.id);
      final urgent = _nodes.any(
        (n) =>
            !n.isGroup &&
            descendants.contains(n.id) &&
            (isUrgent(n, now) || isOverdue(n, now)),
      );
      if (urgent) out.add(group.id);
    }
    return out;
  }

  // ------------------------------------------------------------- 组

  Future<void> _createGroup({String? parentId}) async {
    final result = await showGroupNameDialog(
      context,
      title: parentId == null ? '新建分组' : '新建子组',
    );
    if (result == null) return;
    await _run(
      () => widget.dao.addGroup(
        result.name,
        parentId: parentId,
        color: result.color,
      ),
    );
  }

  Future<void> _createTaskIn(TaskState group) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initialTitle: '', title: '新建任务'),
    );
    if (result == null || result.trim().isEmpty) return;
    await _run(() => widget.dao.addTask(result, parentId: group.id));
  }

  Future<void> _renameGroup(TaskState group) async {
    final result = await showGroupNameDialog(
      context,
      title: '改组名',
      initialName: group.title,
      initialColor: group.color,
    );
    if (result == null) return;
    await _run(() async {
      await widget.dao.renameTask(group.id, result.name);
      if (result.color != group.color) {
        await widget.dao.setGroupColor(group.id, result.color);
      }
    });
  }

  Future<void> _collapse(NodeRow row) => _run(
        () => widget.dao.setGroupCollapsed(row.id, !row.node.collapsed),
      );

  /// 移动到…（任务和组共用）。
  Future<void> _moveNode(TaskState node) async {
    if (_busy) return;
    final result = await showMoveDialog(
      context,
      nodeName: node.title,
      targets: NodeTargets(_moveTargets(node)),
    );
    if (result == null) return;
    final parentId = result == kMoveToTop ? null : result;
    await _run(() => widget.dao.moveToParent(node.id, parentId));
  }

  /// 合法目标：活着的、自己不是别人的子组的一级组；排除自己和自己的子孙。
  /// 自己还带着子组时不能往组里挪（会变三级），只留「顶层」。
  List<TaskState> _moveTargets(TaskState node) {
    final descendants = descendantIds(_nodes, node.id);
    final hasSubgroup = node.isGroup &&
        _nodes.any((n) => !n.isDeleted && n.isGroup && n.parentId == node.id);
    if (hasSubgroup) return const [];
    return _nodes
        .where((n) =>
            n.isGroup &&
            !n.isDeleted &&
            n.parentId == null &&
            n.id != node.id &&
            !descendants.contains(n.id))
        .toList();
  }

  Future<void> _deleteGroup(TaskState group) async {
    if (_busy) return;
    final descendants = descendantIds(_nodes, group.id);
    final tasks =
        _nodes.where((n) => descendants.contains(n.id) && !n.isGroup).length;
    final groups =
        _nodes.where((n) => descendants.contains(n.id) && n.isGroup).length;
    final cascade = await showDeleteGroupDialog(
      context,
      name: group.title,
      tasks: tasks,
      groups: groups,
    );
    if (cascade == null) return; // 取消
    await _run(() => widget.dao.deleteGroup(group.id, cascade: cascade));
    if (!cascade && tasks + groups > 0) {
      _toast('已删除分组，${tasks + groups} 项内容已上移到上一层');
    }
  }

  // ------------------------------------------------------------- 多选

  void _enterSelect({String? initialId}) {
    setState(() {
      _selecting = true;
      _selected.clear();
      if (initialId != null) _selected.add(initialId);
    });
  }

  void _exitSelect() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(NodeRow row) {
    setState(() {
      if (!_selected.remove(row.id)) _selected.add(row.id);
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_displayRows().map((r) => r.id));
    });
  }

  /// 选中的节点是否都在同一层。跨层时批量移动没有唯一落点，先说明原因。
  bool _selectionSameLevel() {
    String? parent;
    var first = true;
    final byId = {for (final n in _nodes) n.id: n};
    for (final id in _selected) {
      final node = byId[id];
      if (node == null) continue;
      final p = effectiveParentOf(node, byId);
      if (first) {
        parent = p;
        first = false;
      } else if (p != parent) {
        _toast('多选只能在同一个层次内移动；请只勾同一层的条目');
        return false;
      }
    }
    return true;
  }

  Future<void> _batchMoveIn() async {
    if (_selected.isEmpty || _busy) return;
    if (!_selectionSameLevel()) return;
    final ids = _selected.toList();
    final result = await showMoveDialog(
      context,
      nodeName: '${ids.length} 项',
      targets: NodeTargets(_moveTargetsForIds(ids)),
    );
    if (result == null) return;
    final parentId = result == kMoveToTop ? null : result;
    await _run(() async {
      await widget.dao.moveManyToParent(ids, parentId);
      _selected.clear();
    });
  }

  /// 批量移入的目标组：活着的、是一级组、不是选中项、也不是选中项的子孙。
  List<TaskState> _moveTargetsForIds(List<String> ids) {
    final blocked = <String>{};
    for (final id in ids) {
      final index = _nodes.indexWhere((n) => n.id == id);
      if (index < 0) continue;
      blocked
        ..add(id)
        ..addAll(descendantIds(_nodes, id));
    }
    return _nodes
        .where((n) =>
            n.isGroup &&
            !n.isDeleted &&
            n.parentId == null &&
            !blocked.contains(n.id))
        .toList();
  }

  Future<void> _batchNudge(int delta) async {
    if (_selected.isEmpty || _busy) return;
    if (!_selectionSameLevel()) return;
    final ids = _selected.toList();
    await _run(() => widget.dao.nudgeMany(ids, delta));
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty || _busy) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中的条目'),
        content: Text('共 $n 项，删除后可在回收站找回。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    await _run(() async {
      await widget.dao.softDeleteMany(ids);
      _selected.clear();
      _selecting = false;
    });
  }

  // ------------------------------------------------------------- 菜单

  /// 长按抬手 / 点 ⋮ / 电脑右键都会走到这里。
  Future<void> _openMenu(NodeRow row, Rect rect, Offset? at) async {
    if (_busy) return;
    final anchor = TaskMenuAnchor(rect: rect, at: at);
    if (row.isGroup) {
      final action = await showGroupMenu(
        context: context,
        group: row.node,
        anchor: anchor,
        // 二级组不能再套子组（最多两级）。
        canAddSubgroup: row.depth < 2,
        canRemind: ReminderService.instance.supported,
      );
      switch (action) {
        case GroupMenuAction.rename:
          await _renameGroup(row.node);
        case GroupMenuAction.newTask:
          await _createTaskIn(row.node);
        case GroupMenuAction.newSubgroup:
          await _createGroup(parentId: row.node.id);
        case GroupMenuAction.remind:
          await _setReminder(row.node);
        case GroupMenuAction.move:
          await _moveNode(row.node);
        case GroupMenuAction.multiSelect:
          _enterSelect(initialId: row.node.id);
        case GroupMenuAction.delete:
          await _deleteGroup(row.node);
        case null:
          break;
      }
      return;
    }

    final action = await showTaskMenu(
      context: context,
      task: row.node,
      anchor: anchor,
      canMove: _nodes.any((n) => n.isGroup && !n.isDeleted),
      canRemind: ReminderService.instance.supported,
    );
    switch (action) {
      case TaskMenuAction.rename:
        await _edit(row.node);
      case TaskMenuAction.dueTime:
        await _setDue(row.node);
      case TaskMenuAction.remind:
        await _setReminder(row.node);
      case TaskMenuAction.repeat:
        await _setRepeat(row.node);
      case TaskMenuAction.toggleDone:
        await _toggle(row);
      case TaskMenuAction.move:
        await _moveNode(row.node);
      case TaskMenuAction.multiSelect:
        _enterSelect(initialId: row.node.id);
      case TaskMenuAction.delete:
        await _delete(row.node);
      case null:
        break;
    }
  }

  /// 拖拽落位：只接受同级的落点。
  ///
  /// [beforeId] 是「插到这一行前面」。它不是自己的同级兄弟时说明用户想
  /// 跨组拖 —— 明确拒绝并提示走「移动到…」。
  Future<void> _reorder(NodeRow row, String? beforeId) async {
    if (beforeId == row.id) return;
    if (_slice != TimeSlice.all) {
      _toast('先切回「全部」再拖动排序；切片的顺序是按时间算的');
      return;
    }
    final byId = {for (final n in _nodes) n.id: n};
    final parent = effectiveParentOf(row.node, byId);
    final siblings =
        siblingsOf(_nodes, parent).where((n) => n.id != row.id).toList();
    int target;
    if (beforeId == null) {
      target = siblings.length;
    } else {
      final index = siblings.indexWhere((n) => n.id == beforeId);
      if (index < 0) {
        _toast('只能在同一级里拖动；要换组请用「移动到…」');
        return;
      }
      target = index;
    }
    final ids = siblings.map((n) => n.id).toList()
      ..insert(target.clamp(0, siblings.length), row.id);
    await _run(() => widget.dao.reorderSiblings(ids));
  }

  /// 统一包裹：防重复点击、捕获异常、刷新列表。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await reload();
    } on ArgumentError catch (e) {
      _toast('${e.message}');
    } catch (e) {
      _toast('出错了：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final overdueCount = countInSlice(_rows, TimeSlice.overdue, now);
    return Column(
      children: [
        if (_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: _exitSelect,
                  child: const Text('取消'),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '已选 ${_selected.length} 项',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _selectAll,
                  child: const Text('全选'),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      hintText: _currentGroup == null
                          ? '添加任务…'
                          : '添加到「${_currentGroup!.title}」…',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: '新建分组',
                  // 不随 _busy 置灰：折叠/展开也走 _run，置灰会让按钮闪一下。
                  onPressed: () => _createGroup(parentId: _groupViewId),
                ),
                FilledButton(
                  // 同上；重复点击由 _add 内部的 _busy 判断挡掉。
                  onPressed: _add,
                  child: const Text('添加'),
                ),
              ],
            ),
          ),
        if (!_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: HorizontalChipBar(
              height: 36,
              children: [
                for (final slice in TimeSlice.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        slice == TimeSlice.overdue && overdueCount > 0
                            ? '逾期 $overdueCount'
                            : slice.label,
                      ),
                      selected: _groupViewId == null && _slice == slice,
                      onSelected: (_) => setState(() {
                        _slice = slice;
                        _groupViewId = null;
                      }),
                    ),
                  ),
                if (_topGroups.isNotEmpty) ...[
                  Container(
                    width: 1,
                    height: 22,
                    margin: const EdgeInsets.only(right: 12, top: 7),
                    color: scheme.outlineVariant,
                  ),
                  for (final group in _topGroups)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: Icon(
                          Icons.folder_outlined,
                          size: 16,
                          color: groupColor(group.color),
                        ),
                        label: Text(group.title),
                        selected: _groupViewId == group.id,
                        onSelected: (_) => setState(() {
                          _groupViewId = group.id;
                          _slice = TimeSlice.all;
                          _selecting = false;
                          _selected.clear();
                        }),
                      ),
                    ),
                ],
              ],
            ),
          ),
        Expanded(
          child: Builder(
            builder: (context) {
              final now = DateTime.now();
              final display = _displayRows();
              return _loading
                  ? const Center(child: CircularProgressIndicator())
                  : display.isEmpty
                      ? Center(
                          child: Text(
                            _groupViewId != null
                                ? '这个分组里还没有内容'
                                : _rows.isEmpty
                                    ? '还没有任务，上面输入一条吧'
                                    : '这个视图里没有任务',
                          ),
                        )
                      : TaskListBody(
                          rows: display,
                          onToggle: _toggle,
                          onMenu: _openMenu,
                          onReorder: _reorder,
                          onCollapse: _collapse,
                          removingId: _removingId,
                          selecting: _selecting,
                          selectedIds: _selected,
                          onSelect: _toggleSelect,
                          urgentGroups: _urgentGroups(now),
                          now: now,
                        );
            },
          ),
        ),
        if (_selecting)
          SafeArea(
            top: false,
            child: Material(
              color: scheme.surfaceContainerHigh,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _selected.isEmpty ? null : _batchMoveIn,
                      child: const Text('移入…'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed:
                          _selected.isEmpty ? null : () => _batchNudge(-1),
                      child: const Text('上移'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed:
                          _selected.isEmpty ? null : () => _batchNudge(1),
                      child: const Text('下移'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: _selected.isEmpty ? null : _batchDelete,
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      child: const Text('删除'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
