/// 回收站里的「任务」页签（1.45 从 RecycleBinPage 抽出来）。
///
/// 语义（与《PNote项目说明》7.4 一致）：
///   删除 = 打墓碑，任务从列表里消失，但仍然在库里、仍然参与同步。
///   恢复 = 给 deleted_at 写一个「值为 null 的新版本」，于是它又变回未删除。
///   永久删除 = 真的从库里删掉，并把它记进 purged，让另一台设备也删掉。
///
/// **永久删除永远是手动的**：这里不会自动清理，也没有定时任务。
/// 你不动手，墓碑就一直留着 —— 留着才安全（随时能恢复）。
///
/// 这个文件不带 Scaffold：它被 [TrashPage] 放进页签，也被
/// [RecycleBinPage]（老入口，保留给测试和旧调用）单独包一层 Scaffold。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/tasks/group_tile.dart';

class TasksTrashView extends StatefulWidget {
  const TasksTrashView({super.key, required this.dao});

  final TaskDao dao;

  @override
  State<TasksTrashView> createState() => TasksTrashViewState();
}

class TasksTrashViewState extends State<TasksTrashView> {
  List<TaskState> _tasks = const [];
  bool _loading = true;
  bool _busy = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 重新读一遍删除列表（[TrashPage] 里切页签、或从别处回来时调用）。
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    final tasks = await widget.dao.deletedTasks();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
      final ids = {for (final t in tasks) t.id};
      _selected.removeWhere((id) => !ids.contains(id));
      if (_tasks.isEmpty) _selecting = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } on Exception catch (e) {
      _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String okLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(TaskState task) {
    setState(() {
      if (!_selected.add(task.id)) _selected.remove(task.id);
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _tasks.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_tasks.map((t) => t.id));
      }
    });
  }

  Future<void> _restoreAll() async {
    if (_tasks.isEmpty) return;
    final ids = _tasks.map((t) => t.id).toList();
    await _run(() async {
      await widget.dao.restoreMany(ids);
      _toast('已恢复 ${ids.length} 项');
    });
  }

  Future<void> _restoreSelected() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    await _run(() async {
      await widget.dao.restoreMany(ids);
      _toast('已恢复 ${ids.length} 项');
      if (mounted) _exitSelect();
    });
  }

  Future<void> _purgeSelected() async {
    if (_selected.isEmpty) return;
    final ok = await _confirm(
      title: '永久删除选中的 ${_selected.length} 项？',
      body: '这些内容会被彻底删掉，无法恢复；下次同步时另一台设备上的'
          '对应条目也会被删掉。',
      okLabel: '永久删除',
    );
    if (!ok) return;
    final ids = _selected.toList();
    await _run(() async {
      final n = await widget.dao.purgeTasks(ids);
      _toast('已永久删除 $n 项');
      if (mounted) _exitSelect();
    });
  }

  Future<void> _restore(TaskState task) => _run(() async {
        await widget.dao.restoreTask(task.id);
        _toast(
          task.isGroup
              ? '已恢复分组「${task.title}」；里面的任务还在回收站，需要单独恢复'
              : '已恢复「${task.title}」',
        );
      });

  Future<void> _purgeOne(TaskState task) async {
    final ok = await _confirm(
      title: '永久删除？',
      body: '「${task.title}」会被彻底删掉，无法恢复。\n'
          '${task.isGroup ? '组里的任务不会跟着删，要单独处理。\n' : ''}'
          '下次同步时，另一台设备上的这一条也会被删掉。',
      okLabel: '永久删除',
    );
    if (!ok) return;
    await _run(() async {
      await widget.dao.purgeTasks([task.id]);
      _toast('已永久删除「${task.title}」');
    });
  }

  Future<void> _purgeAll() async {
    if (_tasks.isEmpty) return;
    final ok = await _confirm(
      title: '清空回收站？',
      body: '会永久删除这里的 ${_tasks.length} 项，无法恢复。',
      okLabel: '全部删除',
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.dao.purgeTasks(_tasks.map((t) => t.id));
      _toast('已永久删除 $n 条');
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _toolbar(),
        Expanded(child: _buildList()),
        if (_selecting)
          SafeArea(
            top: false,
            child: Material(
              color: scheme.surfaceContainerHigh,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed:
                          _selected.isEmpty || _busy ? null : _restoreSelected,
                      child: const Text('恢复'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed:
                          _selected.isEmpty || _busy ? null : _purgeSelected,
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      child: const Text('永久删除'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _toolbar() {
    if (_selecting) {
      return Row(
        children: [
          IconButton(
            tooltip: '取消多选',
            onPressed: _exitSelect,
            icon: const Icon(Icons.close),
          ),
          Expanded(
            child: Center(
              child: Text(
                '已选 ${_selected.length} 项',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: '全选',
            onPressed: _tasks.isEmpty || _busy ? null : _selectAll,
            icon: Icon(
              _selected.length == _tasks.length && _tasks.isNotEmpty
                  ? Icons.deselect
                  : Icons.select_all,
            ),
          ),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '全部恢复',
            onPressed: _tasks.isEmpty || _busy ? null : _restoreAll,
            icon: const Icon(Icons.restore_page_outlined),
          ),
          IconButton(
            tooltip: '多选',
            onPressed: _tasks.isEmpty || _busy
                ? null
                : () => setState(() => _selecting = true),
            icon: const Icon(Icons.checklist),
          ),
          IconButton(
            tooltip: '清空回收站',
            onPressed: _tasks.isEmpty || _busy ? null : _purgeAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_tasks.isEmpty) {
      return const Center(child: Text('回收站是空的'));
    }
    return ListView.separated(
      itemCount: _tasks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final task = _tasks[index];
        final deletedAt = task.deletedAt;
        final kindLabel = task.isGroup ? '分组 · ' : '';
        return ListTile(
          leading: _selecting
              ? Checkbox(
                  value: _selected.contains(task.id),
                  onChanged: _busy ? null : (_) => _toggleSelect(task),
                )
              : (task.isGroup
                  ? Icon(Icons.folder_rounded, color: groupColor(task.color))
                  : null),
          title: Text(task.title.isEmpty ? '（无标题）' : task.title),
          subtitle: Text(
            deletedAt == null
                ? '$kindLabel已删除'
                : '$kindLabel删除于 ${formatShortTime(deletedAt)}',
          ),
          onTap: _selecting && !_busy ? () => _toggleSelect(task) : null,
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '恢复',
                      onPressed: _busy ? null : () => _restore(task),
                      icon: const Icon(Icons.restore),
                    ),
                    IconButton(
                      tooltip: '永久删除',
                      onPressed: _busy ? null : () => _purgeOne(task),
                      icon: const Icon(Icons.delete_forever_outlined),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// `MM-DD HH:mm`，回收站两个页签共用（笔记那边是 DateTime，这里转一下）。
String formatShortTime(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  return formatShortDateTime(t);
}

/// `MM-DD HH:mm`。
String formatShortDateTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
