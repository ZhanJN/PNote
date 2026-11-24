/// 回收站里的「笔记」页签（1.45 新增）。
///
/// 笔记的删除和任务的删除**语义不同**，这里说清楚：
///   任务：打墓碑（`deleted_at` 记一个 HLC 版本），行还在库里，还参与同步。
///   笔记：文件真的被挪进笔记库的 `.trash/<时间戳>/` 目录，还在磁盘上，
///         但不参与搜索、不参与 `[[链接]]`，等你自己在回收站里恢复或永久删除。
///
/// 所以「互通」指的是**操作入口和手感一样**（同一个回收站、同一套恢复/永久删除、
/// 同一套多选），不是把两种数据混在一个列表里 —— 那会让「移动文件」和
/// 「打墓碑」这两件事看起来是一件事，反而更危险。
///
/// 恢复会把笔记放回它原来所在的 `年/月` 目录（时间戳记在文件名里，能还原）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/trash/tasks_trash_view.dart' show formatShortDateTime;

class NotesTrashView extends StatefulWidget {
  const NotesTrashView({super.key, required this.store});

  final NotesStore store;

  @override
  State<NotesTrashView> createState() => NotesTrashViewState();
}

class NotesTrashViewState extends State<NotesTrashView> {
  List<TrashEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 重新读一遍 `.trash`（[TrashPage] 切页签或从别处回来时调用）。
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    try {
      final entries = await widget.store.listTrash();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        final ids = {for (final entry in entries) entry.relPath};
        _selected.removeWhere((id) => !ids.contains(id));
        if (_entries.isEmpty) _selecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e is NotesIoException ? e.message : '打不开 .trash：$e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } on NotesIoException catch (e) {
      _toast(e.message);
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

  void _toggleSelect(TrashEntry entry) {
    setState(() {
      if (!_selected.add(entry.relPath)) _selected.remove(entry.relPath);
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _entries.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_entries.map((entry) => entry.relPath));
      }
    });
  }

  Future<void> _restoreOne(TrashEntry entry) => _run(() async {
        final note = await widget.store.restoreTrash(entry);
        _toast('已恢复「${note.title}」');
      });

  Future<void> _restoreSelected() async {
    if (_selected.isEmpty) return;
    final picked =
        _entries.where((entry) => _selected.contains(entry.relPath)).toList();
    await _run(() async {
      var done = 0;
      for (final entry in picked) {
        await widget.store.restoreTrash(entry);
        done++;
      }
      _toast('已恢复 $done 篇笔记');
      if (mounted) _exitSelect();
    });
  }

  Future<void> _restoreAll() async {
    if (_entries.isEmpty) return;
    final picked = List<TrashEntry>.of(_entries);
    await _run(() async {
      var done = 0;
      for (final entry in picked) {
        await widget.store.restoreTrash(entry);
        done++;
      }
      _toast('已恢复 $done 篇笔记');
    });
  }

  Future<void> _purgeOne(TrashEntry entry) async {
    final ok = await _confirm(
      title: '永久删除？',
      body: '「${entry.title}」的文件和它的素材目录会被真的删掉，无法恢复。',
      okLabel: '永久删除',
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.store.purgeTrash([entry]);
      _toast('已永久删除 $n 篇');
    });
  }

  Future<void> _purgeSelected() async {
    if (_selected.isEmpty) return;
    final picked =
        _entries.where((entry) => _selected.contains(entry.relPath)).toList();
    final ok = await _confirm(
      title: '永久删除选中的 ${picked.length} 篇？',
      body: '文件和素材目录会被真的删掉，无法恢复。',
      okLabel: '永久删除',
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.store.purgeTrash(picked);
      _toast('已永久删除 $n 篇');
      if (mounted) _exitSelect();
    });
  }

  Future<void> _purgeAll() async {
    if (_entries.isEmpty) return;
    final picked = List<TrashEntry>.of(_entries);
    final ok = await _confirm(
      title: '清空笔记回收站？',
      body: '会永久删除这里的 ${picked.length} 篇笔记，无法恢复。',
      okLabel: '全部删除',
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.store.purgeTrash(picked);
      _toast('已永久删除 $n 篇');
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
                '已选 ${_selected.length} 篇',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: '全选',
            onPressed: _entries.isEmpty || _busy ? null : _selectAll,
            icon: Icon(
              _selected.length == _entries.length && _entries.isNotEmpty
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
            onPressed: _entries.isEmpty || _busy ? null : _restoreAll,
            icon: const Icon(Icons.restore_page_outlined),
          ),
          IconButton(
            tooltip: '多选',
            onPressed: _entries.isEmpty || _busy
                ? null
                : () => setState(() => _selecting = true),
            icon: const Icon(Icons.checklist),
          ),
          IconButton(
            tooltip: '清空回收站',
            onPressed: _entries.isEmpty || _busy ? null : _purgeAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return const Center(child: Text('笔记回收站是空的'));
    }
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          leading: _selecting
              ? Checkbox(
                  value: _selected.contains(entry.relPath),
                  onChanged: _busy ? null : (_) => _toggleSelect(entry),
                )
              : const Icon(Icons.article_outlined),
          title: Text(entry.title.isEmpty ? '（无标题）' : entry.title),
          subtitle: Text('删除于 ${formatShortDateTime(entry.movedAt)}'),
          onTap: _selecting && !_busy
              ? () => _toggleSelect(entry)
              : () => _lockedHint(entry),
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '恢复',
                      onPressed: _busy ? null : () => _restoreOne(entry),
                      icon: const Icon(Icons.restore),
                    ),
                    IconButton(
                      tooltip: '永久删除',
                      onPressed: _busy ? null : () => _purgeOne(entry),
                      icon: const Icon(Icons.delete_forever_outlined),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// 回收站里的笔记不该直接进编辑器（它已经不在库里了），
  /// 点一行只是给个提示，真正要动它必须用「恢复」。
  void _lockedHint(TrashEntry entry) {
    _toast('这篇在回收站里，先点「恢复」才能编辑');
  }
}
