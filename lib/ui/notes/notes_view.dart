/// 笔记模块主页面（1.41 第一步 → 1.45 交互对齐待办页）。
///
/// 列表按「年 月」分组，最新在上；点一行进编辑器。
/// 1.45 起和待办页一个手感：
///   * 长按（手机）/ 右键（电脑）/ 行尾 ⋮ 三个入口共用同一个菜单；
///   * 菜单里可以进「多选」，多选后底部是「删除」；
///   * 删除仍然只是移到笔记库的 `.trash`（笔记版回收站，见 TrashPage）。
///
/// 这里不发任何网络请求，所有内容都来自磁盘上的 Markdown 文件。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_format.dart';
import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_search.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/common/minute_refresh.dart';
import 'package:pnote/ui/notes/note_editor_page.dart';
import 'package:pnote/ui/notes/note_list_body.dart';
import 'package:pnote/ui/notes/note_menu.dart';
import 'package:pnote/ui/common/rename_dialog.dart';
import 'package:pnote/ui/tasks/task_menu.dart';

/// 1.48：笔记页的视图顺序 =「全部」→ 各组 → 四种时间视图。
enum NotesListMode { all, group, createdAsc, createdDesc, modifiedAsc, modifiedDesc }

class NotesView extends StatefulWidget {
  const NotesView({super.key, this.store = const NotesStore(), this.onCountChanged});

  final NotesStore store;

  /// 把笔记篇数告诉顶栏（`笔记 · 12 篇`）。
  final ValueChanged<int>? onCountChanged;

  @override
  State<NotesView> createState() => NotesViewState();
}

/// 公开给 [HomePage]：切到笔记页时可以主动 [reload] 一次。
class NotesViewState extends State<NotesView> with MinuteRefresh<NotesView> {
  final TextEditingController _search = TextEditingController();
  List<NoteFile> _notes = const <NoteFile>[];
  List<NoteHit> _hits = const <NoteHit>[];
  bool _loading = true;
  bool _searching = false;
  bool _everLoaded = false;
  bool _busy = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};
  String? _error;
  Timer? _searchDebounce;

  /// 1.48：当前视图。「全部」与组视图按月分组、可拖拽；时间视图平铺、禁拖拽。
  NotesListMode _mode = NotesListMode.all;
  String? _group;
  NoteGroups _groupIndex = const NoteGroups.empty();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// 重新扫一遍库。
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    // 只有第一次（或上次失败）才显示转圈：切页重扫时保留旧列表，
    // 避免「点一下笔记页先闪一圈加载」。
    if (mounted && !_everLoaded) setState(() => _loading = true);
    try {
      final notes = await widget.store.list();
      final root = await notesRoot();
      final index = mergePhysical(root, await widget.store.readGroups(), notes);
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _groupIndex = index;
        if (_group != null && !index.topNames.contains(_group)) {
          _mode = NotesListMode.all;
          _group = null;
        }
        _loading = false;
        _everLoaded = true;
        _error = null;
        final ids = {for (final note in notes) note.relPath};
        _selected.removeWhere((id) => !ids.contains(id));
        if (_notes.isEmpty) _selecting = false;
      });
      widget.onCountChanged?.call(notes.length);
    } catch (e) {
      // 库目录打不开（权限、被占用、插件缺失）不该让整个页面崩掉。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _everLoaded = true;
        _error = e is NotesIoException ? e.message : '打不开笔记库：$e';
      });
    }
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _searching = false;
        _hits = const <NoteHit>[];
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      final hits = await searchNotes(_notes, query);
      if (!mounted || _search.text.trim() != query) return;
      setState(() => _hits = hits);
    });
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const RenameDialog(initialTitle: '', title: '新建笔记'),
    );
    if (!mounted) return;
    final title = (name ?? '').trim();
    try {
      final note = await widget.store.create(title.isEmpty ? '未命名笔记' : title);
      // 1.48：在组视图里新建 → 文件仍落在年/月目录，但顺手加进这个组。
      if (_mode == NotesListMode.group && _group != null) {
        await widget.store.addToGroup(_group!, note.relPath);
      }
      await _reload();
      if (!mounted) return;
      await _open(note);
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _open(NoteFile note, {String? anchor}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NoteEditorPage(
        note: note,
        store: widget.store,
        hasNote: _hasNote,
        openNote: _openByStem,
        initialAnchor: anchor,
      ),
    ));
    await _reload();
  }

  bool _hasNote(String stem) =>
      _notes.any((note) => linkStemOf(note.relPath) == stem);

  NoteFile? _noteByStem(String stem) {
    for (final note in _notes) {
      if (linkStemOf(note.relPath) == stem) return note;
    }
    return null;
  }

  Future<void> _openByStem(String raw) async {
    final stem = normalizeRefKey(raw);
    final anchor = refAnchor(raw);
    var note = _noteByStem(stem);
    if (note == null) {
      // 编辑器里刚「新建」的笔记还不在本地列表里，重扫一次再找（1.43）。
      await _reload();
      note = _noteByStem(stem);
    }
    if (note == null) {
      _toast('找不到笔记「$stem」');
      return;
    }
    await _open(note, anchor: anchor);
  }

  Future<void> _rename(NoteFile note) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        initialTitle: linkStemOf(note.relPath),
        title: '改标题',
      ),
    );
    if (!mounted || name == null) return;
    try {
      await widget.store.renameFile(note, name);
      await _reload();
      _toast('已改标题：${name.trim()}');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 从列表里给这篇笔记加素材：复制进 `.assets`，再把 `![[名字]]` 放进剪贴板。
  ///
  /// 列表页拿不到正文光标，所以没法像编辑器里那样直接插进去；
  /// 复制 + 提示是最不容易让人困惑的做法。
  Future<void> _insertAsset(NoteFile note) async {
    final picked = await openFile();
    if (picked == null) return;
    try {
      final name = await widget.store.importAsset(note, File(picked.path));
      await _reload();
      await Clipboard.setData(ClipboardData(text: '![[$name]]'));
      _toast('已复制 ![[$name]]，粘贴到笔记正文里即可');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 「在文件夹中显示」：电脑上打开资源管理器并选中这个文件；
  /// 手机上没法打开系统文件管理器定位到私有目录，退化成复制路径。
  ///
  /// 1.46 修：原来把 `/select,C:\…\x.md` 塞进**一个**参数，explorer 解析不了
  /// 带空格的路径，会退回到默认目录（用户看到「导向文档」）。实测只有把
  /// `/select,` 和路径拆成两个参数，Windows 才会打开正确文件夹并选中文件。
  Future<void> _reveal(NoteFile note) async {
    final root = await notesRoot();
    // 必须用本机分隔符：`relPath` 里是 `/`，直接交给 explorer 会被当成开关
    //（1.46.1 实测：混合分隔符 → explorer 退回「桌面」并选中「文档」）。
    final path = nativePathIn(root, note.relPath);
    final folder = p.dirname(path);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', path]);
        // 把实际打开的目录回显出来，方便用户/我们判断走没走对地方。
        _toast('已打开：$folder');
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
        _toast('已打开：$folder');
      } else {
        await Clipboard.setData(ClipboardData(text: path));
        _toast('路径已复制：$path');
      }
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: path));
      _toast('打不开文件管理器，路径已复制');
    }
  }

  Future<void> _delete(NoteFile note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这篇笔记？'),
        content: Text('「${note.title}」会被移到笔记库的 .trash 目录，'
            '文件还在，需要时可以自己去捞回来。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.store.delete(note);
      await _reload();
      _toast('已移到 .trash');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  // ------------------------------------------------------------- 多选

  void _enterSelect({String? relPath}) {
    setState(() {
      _selecting = true;
      _selected.clear();
      if (relPath != null) _selected.add(relPath);
    });
  }

  void _exitSelect() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(NoteFile note) {
    setState(() {
      if (!_selected.remove(note.relPath)) _selected.add(note.relPath);
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _visible().length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_visible().map((note) => note.relPath));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _busy) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除选中的 $n 篇笔记？'),
        content: const Text('会移到笔记库的 .trash 目录，之后可以在回收站的'
            '「笔记」页签里恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final picked = _notes.where((note) => _selected.contains(note.relPath));
    setState(() => _busy = true);
    var done = 0;
    try {
      for (final note in picked) {
        await widget.store.delete(note);
        done++;
      }
      if (!mounted) return;
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      await _reload();
      _toast('已把 $done 篇笔记移到 .trash');
    } on NotesIoException catch (e) {
      _toast('第 ${done + 1} 篇失败：${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------- 菜单

  Future<void> _openMenu(NoteFile note, Rect rect, Offset? at) async {
    if (_busy) return;
    final action = await showNoteMenu(
      context: context,
      note: note,
      anchor: TaskMenuAnchor(rect: rect, at: at),
      canReveal: true,
    );
    if (!mounted) return;
    switch (action) {
      case NoteMenuAction.open:
        await _open(note);
      case NoteMenuAction.rename:
        await _rename(note);
      case NoteMenuAction.asset:
        await _insertAsset(note);
      case NoteMenuAction.groups:
        await _editGroups(note);
      case NoteMenuAction.reveal:
        await _reveal(note);
      case NoteMenuAction.multiSelect:
        _enterSelect(relPath: note.relPath);
      case NoteMenuAction.delete:
        await _delete(note);
      case null:
        break;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        _topBar(),
        Expanded(child: _body()),
        if (_selecting) _actionBar(),
      ],
    );
  }

  /// 平时是「搜索框 + 新建」；多选时换成「取消 / 已选 N 篇 / 全选」。
  Widget _topBar() {
    if (_selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Row(
          children: [
            TextButton(onPressed: _exitSelect, child: const Text('取消')),
            Expanded(
              child: Center(
                child: Text(
                  '已选 ${_selected.length} 篇',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            TextButton(
              onPressed: _notes.isEmpty ? null : _selectAll,
              child: Text(
                _selected.length == _visible().length && _visible().isNotEmpty
                    ? '取消全选'
                    : '全选',
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(child: _searchField()),
              const SizedBox(width: 8),
              // 1.42：用户反馈「没有新建按钮」——原来只有搜索框右侧一个小图标。
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        // 1.48：视图条 =「全部」→ 组 → 四种时间视图。
        _chipsRow(),
      ],
    );
  }

  Widget _actionBar() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _selected.isEmpty || _busy ? null : _deleteSelected,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('删除'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _search,
      onChanged: _onQueryChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索标题和正文',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _search.clear();
                  _onQueryChanged('');
                },
              ),
        border: const OutlineInputBorder(),
      ),
    );
  }

  // ------------------------------------------------------- 视图条与组（1.48）

  bool get _isTimeMode =>
      _mode == NotesListMode.createdAsc ||
      _mode == NotesListMode.createdDesc ||
      _mode == NotesListMode.modifiedAsc ||
      _mode == NotesListMode.modifiedDesc;

  static const Map<NotesListMode, String> _timeLabels = {
    NotesListMode.createdAsc: '创建 ↑',
    NotesListMode.createdDesc: '创建 ↓',
    NotesListMode.modifiedAsc: '修改 ↑',
    NotesListMode.modifiedDesc: '修改 ↓',
  };

  /// 当前视图要显示的笔记。
  ///
  /// 「全部」直接用 `list()` 的顺序（含 `.order.json` 的手工顺序）；
  /// 组视图按归属过滤，但保留同样的顺序；时间视图给排好序的副本。
  List<NoteFile> _visible() {
    switch (_mode) {
      case NotesListMode.all:
        return _notes;
      case NotesListMode.group:
        final picked = _groupIndex.notesUnder(_group ?? '');
        return [
          for (final note in _notes)
            if (picked.contains(note.relPath)) note,
        ];
      case NotesListMode.createdAsc:
        return [..._notes]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case NotesListMode.createdDesc:
        return [..._notes]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case NotesListMode.modifiedAsc:
        return [..._notes]..sort((a, b) => a.modified.compareTo(b.modified));
      case NotesListMode.modifiedDesc:
        return [..._notes]..sort((a, b) => b.modified.compareTo(a.modified));
    }
  }

  /// 横向滚动的视图条：「全部」→ 各组 →「新建组」→ 四种时间视图。
  Widget _chipsRow() {
    final names = _groupIndex.topNames;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip(
            '全部',
            _mode == NotesListMode.all,
            () => _setMode(NotesListMode.all),
          ),
          for (final name in names) _groupChip(name),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('新建组'),
              onPressed: _createGroup,
            ),
          ),
          for (final entry in _timeLabels.entries)
            _chip(entry.value, _mode == entry.key, () => _setMode(entry.key)),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  /// 组视图的 chip：长按改名/删组。
  Widget _groupChip(String name) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onLongPress: () => _groupMenu(name),
        child: ChoiceChip(
          label: Text(name),
          selected: _mode == NotesListMode.group && _group == name,
          onSelected: (_) => _setMode(NotesListMode.group, group: name),
        ),
      ),
    );
  }

  void _setMode(NotesListMode mode, {String? group}) {
    setState(() {
      _mode = mode;
      if (mode == NotesListMode.group) {
        final picked = group ?? _group;
        _group = picked ?? (_groupIndex.topNames.isEmpty ? null : _groupIndex.topNames.first);
        if (_group == null) _mode = NotesListMode.all;
      }
      _selecting = false;
      _selected.clear();
    });
  }

  /// 新建组 = 在笔记库根下真建一个文件夹（用户说的「纯文件夹那种」）。
  Future<void> _createGroup() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const RenameDialog(initialTitle: '', title: '新建组'),
    );
    if (!mounted) return;
    final clean = (name ?? '').trim();
    if (clean.isEmpty) return;
    if (isYearDir(clean) || isInternalName(clean)) {
      _toast('「$clean」不能用：组名不能是年份数字，也不能用点开头的名字');
      return;
    }
    try {
      final root = await notesRoot();
      final dir = Directory(p.join(root.path, clean));
      if (!await dir.exists()) await dir.create(recursive: true);
      await _reload();
      if (!mounted) return;
      setState(() {
        _mode = NotesListMode.group;
        _group = clean;
      });
      _toast('已新建组「$clean」（就是笔记库里的一个文件夹）');
    } on FileSystemException catch (e) {
      _toast('建不了组：${e.message}');
    }
  }

  Future<void> _groupMenu(String name) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('组「$name」'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const ListTile(
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('重命名组'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const ListTile(
              leading: Icon(Icons.remove_circle_outline),
              title: Text('删除组（笔记不删）'),
            ),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      await _renameGroup(name);
    } else if (action == 'delete') {
      await _deleteGroup(name);
    }
  }

  Future<void> _renameGroup(String name) async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initialTitle: name, title: '重命名组'),
    );
    final clean = (next ?? '').trim();
    if (!mounted || clean.isEmpty || clean == name) return;
    if (isYearDir(clean) || isInternalName(clean)) {
      _toast('「$clean」不能用：组名不能是年份数字，也不能用点开头的名字');
      return;
    }
    try {
      final root = await notesRoot();
      final from = Directory(p.join(root.path, name));
      final to = Directory(p.join(root.path, clean));
      if (await from.exists() && !await to.exists()) {
        await from.rename(to.path);
      }
      // 清单里同名的一级组（以及它的子组）跟着改名。
      final groups = await widget.store.readGroups();
      final nextMap = <String, List<String>>{};
      groups.byGroup.forEach((key, paths) {
        if (topOf(key) == name) {
          final renamed = clean + key.substring(name.length);
          nextMap[renamed] = List<String>.of(paths);
        } else {
          nextMap[key] = List<String>.of(paths);
        }
      });
      await widget.store.writeGroups(NoteGroups(nextMap));
      await _reload();
      if (!mounted) return;
      setState(() => _group = clean);
      _toast('组已改名为「$clean」');
    } on FileSystemException catch (e) {
      _toast('改不了：${e.message}');
    }
  }

  /// 删组只删「空文件夹 + 清单里的记录」，里面的笔记文件一个都不动。
  Future<void> _deleteGroup(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除组「$name」？'),
        content: const Text('只会删掉这个空文件夹和在组清单里的记录，'
            '组里的笔记文件都还在「全部」里，不会被删。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除组'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final root = await notesRoot();
      final dir = Directory(p.join(root.path, name));
      if (await dir.exists()) {
        final empty = await dir.list().length == 0;
        if (empty) await dir.delete();
      }
      final groups = await widget.store.readGroups();
      final nextMap = <String, List<String>>{};
      groups.byGroup.forEach((key, paths) {
        if (topOf(key) != name) nextMap[key] = List<String>.of(paths);
      });
      await widget.store.writeGroups(NoteGroups(nextMap));
      await _reload();
      if (!mounted) return;
      setState(() {
        _mode = NotesListMode.all;
        _group = null;
      });
    } on FileSystemException catch (e) {
      _toast('删不了：${e.message}');
    }
  }

  /// 「加入组…」：一篇笔记可以同时属于多个组（多对多，指向同一个文件）。
  Future<void> _editGroups(NoteFile note) async {
    final names = _groupIndex.topNames;
    final picked = <String>{..._groupIndex.groupsOf(note.relPath).map(topOf)};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('「${note.title}」属于哪些组？'),
          content: SizedBox(
            width: 320,
            child: names.isEmpty
                ? const Text('还没有组。先在视图条里点「新建组」，'
                    '或者直接在笔记库里建一个文件夹。')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final name in names)
                        CheckboxListTile(
                          dense: true,
                          value: picked.contains(name),
                          title: Text(name),
                          onChanged: (value) => setLocal(() {
                            if (value == true) {
                              picked.add(name);
                            } else {
                              picked.remove(name);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, picked),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final groups = await widget.store.readGroups();
      final nextMap = <String, List<String>>{};
      groups.byGroup.forEach((key, paths) {
        final isTop = topOf(key) == key;
        if (!isTop) {
          nextMap[key] = List<String>.of(paths);
          return;
        }
        final list = List<String>.of(paths)..remove(note.relPath);
        if (result.contains(key)) list.add(note.relPath);
        if (list.isNotEmpty) nextMap[key] = list;
      });
      // 选中但当时还不存在的组名，补一条。
      for (final name in result) {
        final list = nextMap[name] ?? <String>[];
        if (!list.contains(note.relPath)) list.add(note.relPath);
        nextMap[name] = list;
      }
      await widget.store.writeGroups(NoteGroups(nextMap));
      await _reload();
      if (!mounted) return;
      _toast(result.isEmpty ? '已移出所有组' : '已放进 ${result.length} 个组');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Widget _emptyView() {
    final theme = Theme.of(context);
    final label = _mode == NotesListMode.group ? '组「${_group ?? ''}」' : '这个视图';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_off_outlined,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('$label里还没有笔记', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '「新建」会把笔记存到年/月目录，并加进当前组。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_searching && !_selecting) return _searchResults();
    if (_notes.isEmpty) return _empty();
    if (_visible().isEmpty) return _emptyView();
    return RefreshIndicator(
      onRefresh: _reload,
      child: NoteListBody(
        groups: _groups(),
        // 时间视图平铺、禁拖拽（顺序由时间决定，拖了也会被排序覆盖）。
        showHeaders: !_isTimeMode,
        draggable: !_isTimeMode,
        now: DateTime.now(),
        selecting: _selecting,
        selected: _selected,
        onSelect: _toggleSelect,
        onOpen: (note) => unawaited(_open(note)),
        onMenu: (note, rect, at) => unawaited(_openMenu(note, rect, at)),
        onReorder: _reorder,
      ),
    );
  }

  /// 按月分组：`createdAt` 的年月相同就归一组，组的顺序沿用 `list()` 的顺序。
  List<NoteGroup> _groups() {
    final visible = _visible();
    if (_isTimeMode) {
      // 时间视图：一整段平铺，不画月份小标题。
      return [NoteGroup(key: '', title: '', notes: visible)];
    }
    final groups = <String, List<NoteFile>>{};
    for (final note in visible) {
      final key = monthKeyOf(note.createdAt);
      (groups[key] ??= <NoteFile>[]).add(note);
    }
    return [
      for (final entry in groups.entries)
        NoteGroup(
          key: entry.key,
          title: formatMonthHeader(entry.value.first.createdAt),
          notes: entry.value,
        ),
    ];
  }

  /// 拖拽落位：把这一组的新顺序写进 `.order.json`，然后重新扫库。
  Future<void> _reorder(String groupKey, List<String> orderedIds) async {
    if (_busy) return;
    try {
      await widget.store.writeOrder(groupKey, orderedIds);
      await _reload();
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Widget _searchResults() {
    if (_hits.isEmpty) {
      return Center(
        child: Text('没有找到含「${_search.text.trim()}」的笔记',
            style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final now = DateTime.now();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _hits.length,
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return ListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text(hit.note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            hit.inTitle ? '标题命中 · ${formatRelative(hit.note.modified, now)}'
                : hit.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: !hit.inTitle && hit.snippet.isNotEmpty,
          onTap: () => _open(hit.note),
        );
      },
    );
  }

  Widget _empty() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('还没有笔记', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '每篇笔记都是磁盘上的一个 .md 文件，\n用记事本也能打开。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('新建第一篇笔记'),
            ),
          ],
        ),
      ),
    );
  }
}
