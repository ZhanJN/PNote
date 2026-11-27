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
import 'package:pnote/ui/settings/notes_prefs.dart';
import 'package:pnote/ui/common/horizontal_chip_bar.dart';
import 'package:pnote/ui/common/minute_refresh.dart';
import 'package:pnote/ui/notes/note_editor_page.dart';
import 'package:pnote/ui/notes/note_list_body.dart';
import 'package:pnote/ui/notes/note_menu.dart';
import 'package:pnote/ui/common/rename_dialog.dart';
import 'package:pnote/ui/tasks/task_menu.dart';

/// 1.54：笔记列表只有「排序方式」是视图状态，不落盘。
///
/// * [manual] 是唯一持久顺序（存在 `.groups.json` 的 `order` 里），拖拽只改它；
/// * 其它四种只是**临时**把当前列表按时间排一下，切回手动就恢复原顺序，
///   任何时候都不会写盘覆盖手动顺序。
enum NotesSort { manual, createdAsc, createdDesc, modifiedAsc, modifiedDesc }

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

  /// 1.54：`null` = 全部；否则只看这个组。
  String? _filterGroup;
  /// 排序视图：手动是持久顺序，其它只是临时显示。
  NotesSort _sort = NotesSort.manual;
  NoteGroups _groupIndex = const NoteGroups.empty();

  @override
  void initState() {
    super.initState();
    noteListPreview.addListener(_onPreviewPrefChanged);
    _reload();
  }

  void _onPreviewPrefChanged() {
    if (mounted) _reload();
  }

  @override
  void dispose() {
    noteListPreview.removeListener(_onPreviewPrefChanged);
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
      final notes = await widget.store.list(
        withPreview: noteListPreview.value,
      );
      final index = await widget.store.readGroupsMigrated();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _groupIndex = index;
        if (_filterGroup != null && index.groupNamed(_filterGroup!) == null) {
          _filterGroup = null;
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

  Future<void> _create({String? group}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final target = group ?? _filterGroup;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const RenameDialog(initialTitle: '', title: '新建笔记'),
    );
    if (!mounted) return;
    final title = (name ?? '').trim();
    try {
      final note = await widget.store.create(title.isEmpty ? '未命名笔记' : title);
      // 1.54：在某个组里点「新建」→ 文件仍落在年/月目录，但直接归到这个组。
      // 1.56：组标题上的「+」也可以直接指定组。
      if (target != null) {
        await widget.store.addToGroup(target, note.relPath);
      }
      await _reload();
      if (!mounted) return;
      await _open(note);
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _open(NoteFile note, {String? anchor}) async {
    // 1.56：进编辑器前先收键盘/焦点，回来时不会让搜索框又抢焦点、自动弹键盘。
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NoteEditorPage(
        note: note,
        store: widget.store,
        hasNote: _hasNote,
        openNote: _openByStem,
        initialAnchor: anchor,
      ),
    ));
    FocusManager.instance.primaryFocus?.unfocus();
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
        content: Text('「${note.title}」会被移到回收站，'
            '之后可以在回收站的「笔记」页签里恢复。'),
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
      _toast('已移到回收站');
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

  int get _visibleCount =>
      _sections().fold<int>(0, (sum, group) => sum + group.notes.length);

  void _selectAll() {
    final visible = [
      for (final group in _sections()) ...group.notes,
    ];
    setState(() {
      if (_selected.length == visible.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(visible.map((note) => note.relPath));
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
        content: const Text('会移到回收站，之后可以在回收站的「笔记」页签里恢复。'),
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
      _toast('已把 $done 篇笔记移到回收站');
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
      pinned: _groupIndex.isPinnedNote(note.relPath),
    );
    if (!mounted) return;
    switch (action) {
      case NoteMenuAction.open:
        await _open(note);
      case NoteMenuAction.rename:
        await _rename(note);
      case NoteMenuAction.asset:
        await _insertAsset(note);
      case NoteMenuAction.moveToGroup:
        await _moveNote(note);
      case NoteMenuAction.pin:
        await _toggleNotePinned(note);
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

  /// 笔记置顶 / 取消置顶（组内排最前）。
  Future<void> _toggleNotePinned(NoteFile note) async {
    final pinned = _groupIndex.isPinnedNote(note.relPath);
    try {
      await widget.store.writeGroups(
        _groupIndex.withNotePinned(note.relPath, !pinned),
      );
      await _reload();
      if (!mounted) return;
      _toast(pinned ? '已取消置顶' : '已置顶到组内最前');
    } on NotesIoException catch (e) {
      _toast(e.message);
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
                _selected.length == _visibleCount && _visibleCount > 0
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
              // 1.56：一个按钮管两件事（新建笔记 / 新建分组），少一次犹豫。
              MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.note_add_outlined, size: 18),
                    onPressed: _create,
                    child: const Text('新建笔记'),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.create_new_folder_outlined,
                        size: 18),
                    onPressed: () => _createGroup(),
                    child: const Text('新建分组'),
                  ),
                ],
                builder: (context, controller, child) => FilledButton.icon(
                  onPressed: () =>
                      controller.isOpen ? controller.close() : controller.open(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建'),
                ),
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

  // ------------------------------------------------------- 视图条与组（1.54）

  bool get _isManual => _sort == NotesSort.manual;

  String get _sortLabel => switch (_sort) {
        NotesSort.manual => '手动',
        NotesSort.createdAsc => '创建 ↑',
        NotesSort.createdDesc => '创建 ↓',
        NotesSort.modifiedAsc => '修改 ↑',
        NotesSort.modifiedDesc => '修改 ↓',
      };

  List<NoteFile> _poolFor(String key) {
    final name = key.isEmpty ? null : key;
    return [
      for (final note in _notes)
        if (_groupIndex.groupOf(note.relPath) == name) note,
    ];
  }

  /// 手动顺序：清单里的顺序优先，新笔记按创建时间倒序接在后面。
  List<String> _manualOrder(String key, List<NoteFile> pool) {
    final byPath = {for (final note in pool) note.relPath: note};
    final ids = <String>[];
    for (final id in _groupIndex.order[key] ?? const <String>[]) {
      if (byPath.containsKey(id) && !ids.contains(id)) ids.add(id);
    }
    final rest = [
      for (final note in pool)
        if (!ids.contains(note.relPath)) note,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    ids.addAll(rest.map((note) => note.relPath));
    return ids;
  }

  List<NoteFile> _sectionNotes(String key) {
    final pool = _poolFor(key);
    if (!_isManual) {
      pool.sort(switch (_sort) {
        NotesSort.createdAsc => (a, b) => a.createdAt.compareTo(b.createdAt),
        NotesSort.createdDesc => (a, b) => b.createdAt.compareTo(a.createdAt),
        NotesSort.modifiedAsc => (a, b) => a.modified.compareTo(b.modified),
        NotesSort.modifiedDesc => (a, b) => b.modified.compareTo(a.modified),
        NotesSort.manual => (a, b) => 0,
      });
      return _pinnedFirst(pool);
    }
    final byPath = {for (final note in pool) note.relPath: note};
    final ordered = [
      for (final id in _manualOrder(key, pool)) byPath[id]!,
    ];
    return _pinnedFirst(ordered);
  }

  /// 置顶的笔记永远排在本组最前；其余保持当前排序（1.55）。
  List<NoteFile> _pinnedFirst(List<NoteFile> notes) {
    final pinned = <NoteFile>[];
    final rest = <NoteFile>[];
    for (final note in notes) {
      if (_groupIndex.isPinnedNote(note.relPath)) {
        pinned.add(note);
      } else {
        rest.add(note);
      }
    }
    return <NoteFile>[...pinned, ...rest];
  }

  /// 当前要画的组分区（1.55：按树展开，子组缩进）。
  ///
  /// * 「全部」：一级组按置顶 + 手动顺序，组内先画自己的笔记，再递归子组；
  ///   未分组永远在最后。
  /// * 组视图：显示这个组及其全部下级组（折叠状态各管各的）。
  List<NoteGroup> _sections() {
    final out = <NoteGroup>[];
    void emitGroup(String name, int depth) {
      final def = _groupIndex.groupNamed(name);
      if (def == null) return;
      out.add(NoteGroup(
        key: def.name,
        title: def.name,
        notes: _sectionNotes(def.name),
        color: def.color,
        collapsed: def.collapsed,
        depth: depth,
        pinned: def.pinned,
      ));
      if (def.collapsed) return;
      for (final child in _groupIndex.childrenOf(def.name)) {
        emitGroup(child.name, depth + 1);
      }
    }

    if (_filterGroup != null) {
      final def = _groupIndex.groupNamed(_filterGroup!);
      if (def != null) emitGroup(def.name, 0);
      return out;
    }
    for (final def in _groupIndex.roots) {
      emitGroup(def.name, 0);
    }
    final ungrouped = _sectionNotes('');
    if (ungrouped.isNotEmpty) {
      out.add(NoteGroup(
        key: '',
        title: '未分组',
        notes: ungrouped,
        ungrouped: true,
        collapsible: false,
      ));
    }
    return out;
  }

  Widget _chipsRow() {
    return HorizontalChipBar(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        _chip('全部', _filterGroup == null, () => _setFilter(null)),
        // 视图只放一级组：子组在列表里以缩进的组标题出现（1.55）。
        for (final def in _groupIndex.roots) _groupChip(def),
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ActionChip(
            avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('新建组'),
            onPressed: _createGroup,
          ),
        ),
        _sortButton(),
      ],
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

  /// 组 chip：点一下只看这个组；长按改名 / 换色 / 置顶 / 子组 / 上下移 / 删除。
  Widget _groupChip(NoteGroupDef def) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onLongPress: () => _groupMenu(def),
        child: ChoiceChip(
          avatar: Icon(
            def.pinned ? Icons.push_pin : Icons.folder_outlined,
            size: 16,
            color: def.pinned ? scheme.primary : noteGroupColor(def.color),
          ),
          label: Text(def.name),
          selected: _filterGroup == def.name,
          onSelected: (_) => _setFilter(def.name),
        ),
      ),
    );
  }

  Widget _sortButton() {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<NotesSort>(
      tooltip: '排序方式',
      initialValue: _sort,
      onSelected: _setSort,
      itemBuilder: (_) => [
        for (final value in NotesSort.values)
          PopupMenuItem(
            value: value,
            child: Row(
              children: [
                Icon(
                  value == NotesSort.manual
                      ? Icons.drag_indicator
                      : Icons.schedule,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(switch (value) {
                  NotesSort.manual => '手动顺序（可拖拽）',
                  NotesSort.createdAsc => '创建时间 ↑',
                  NotesSort.createdDesc => '创建时间 ↓',
                  NotesSort.modifiedAsc => '修改时间 ↑',
                  NotesSort.modifiedDesc => '修改时间 ↓',
                }),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('排序：$_sortLabel'),
          ],
        ),
      ),
    );
  }

  void _setFilter(String? group) {
    setState(() {
      _filterGroup = group;
      _selecting = false;
      _selected.clear();
    });
  }

  void _setSort(NotesSort sort) {
    setState(() {
      _sort = sort;
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _toggleCollapse(String key) async {
    if (key.isEmpty) return;
    final def = _groupIndex.groupNamed(key);
    if (def == null) return;
    final next = _groupIndex.withCollapsed(key, !def.collapsed);
    setState(() => _groupIndex = next);
    try {
      await widget.store.writeGroups(next);
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 新建组：只是清单里多一条标签，不再在库根建文件夹。
  /// [parent] 非空表示在某个组下面建子组（1.55）。
  Future<void> _createGroup({String parent = ''}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        initialTitle: '',
        title: parent.isEmpty ? '新建组' : '在「$parent」下新建子组',
      ),
    );
    if (!mounted) return;
    final clean = (name ?? '').trim();
    if (clean.isEmpty) return;
    if (_groupIndex.groupNamed(clean) != null) {
      _toast('已经有叫「$clean」的组了');
      return;
    }
    final color = _groupIndex.groups.length % kGroupColorCount;
    try {
      await widget.store.writeGroups(
        _groupIndex.addGroup(clean, color: color, parent: parent),
      );
      await _reload();
      if (!mounted) return;
      setState(() => _filterGroup = clean);
      _toast(parent.isEmpty
          ? '已新建组「$clean」'
          : '已在「$parent」下新建子组「$clean」');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 组标题右侧「+」：直接在这个组里新建（1.56）。
  Future<void> _createInGroup(NoteGroup group) async {
    await _create(group: group.ungrouped ? null : group.key);
  }

  /// 列表里长按 / 右键组标题：与顶部组标签菜单同一套（1.56）。
  Future<void> _openGroupMenu(
    NoteGroup group,
    Rect rect,
    Offset? at,
  ) async {
    final def = _groupIndex.groupNamed(group.key);
    if (def != null) {
      await _groupMenu(def);
      return;
    }
    // 「未分组」没有组属性，只给「新建笔记」。
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('未分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'new'),
            child: const ListTile(
              leading: Icon(Icons.note_add_outlined),
              title: Text('新建笔记'),
            ),
          ),
        ],
      ),
    );
    if (!mounted || action != 'new') return;
    await _create(group: null);
  }

  Future<void> _groupMenu(NoteGroupDef def) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('组「${def.name}」'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'new'),
            child: ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text('在「${def.name}」里新建笔记'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'pin'),
            child: ListTile(
              leading: Icon(
                def.pinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(def.pinned ? '取消置顶' : '置顶（排到同级最前）'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'subgroup'),
            child: const ListTile(
              leading: Icon(Icons.create_new_folder_outlined),
              title: Text('新建子组…'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const ListTile(
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('重命名组'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'color'),
            child: const ListTile(
              leading: Icon(Icons.palette_outlined),
              title: Text('改颜色'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'up'),
            child: const ListTile(
              leading: Icon(Icons.arrow_upward),
              title: Text('上移一组'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'down'),
            child: const ListTile(
              leading: Icon(Icons.arrow_downward),
              title: Text('下移一组'),
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
    switch (action) {
      case 'new':
        await _create(group: def.name);
      case 'pin':
        await _toggleGroupPinned(def);
      case 'subgroup':
        await _createGroup(parent: def.name);
      case 'rename':
        await _renameGroup(def);
      case 'color':
        await _pickColor(def);
      case 'up':
        await _moveGroup(def, -1);
      case 'down':
        await _moveGroup(def, 1);
      case 'delete':
        await _deleteGroup(def);
    }
  }

  /// 组置顶 / 取消置顶（同级组里排最前，顶部标签顺序同步）。
  Future<void> _toggleGroupPinned(NoteGroupDef def) async {
    try {
      await widget.store.writeGroups(
        _groupIndex.withGroupPinned(def.name, !def.pinned),
      );
      await _reload();
      if (!mounted) return;
      _toast(def.pinned ? '已取消置顶「${def.name}」' : '已置顶「${def.name}」');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _renameGroup(NoteGroupDef def) async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initialTitle: def.name, title: '重命名组'),
    );
    if (!mounted) return;
    final clean = (next ?? '').trim();
    if (clean.isEmpty || clean == def.name) return;
    if (_groupIndex.groupNamed(clean) != null) {
      _toast('已经有叫「$clean」的组了');
      return;
    }
    try {
      await widget.store.writeGroups(_groupIndex.renameGroup(def.name, clean));
      await _reload();
      if (!mounted) return;
      if (_filterGroup == def.name) setState(() => _filterGroup = clean);
      _toast('组已改名为「$clean」');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _pickColor(NoteGroupDef def) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${def.name}」的颜色'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var i = 0; i < kNoteGroupColors.length; i++)
              InkWell(
                onTap: () => Navigator.pop(ctx, i),
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: noteGroupColor(i),
                    shape: BoxShape.circle,
                    border: i == def.color
                        ? Border.all(
                            color: Theme.of(ctx).colorScheme.onSurface,
                            width: 3,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await widget.store.writeGroups(_groupIndex.withColor(def.name, picked));
      await _reload();
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _moveGroup(NoteGroupDef def, int delta) async {
    try {
      await widget.store
          .writeGroups(_groupIndex.moveGroup(def.name, delta));
      await _reload();
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 删组只删组名与归属记录，笔记文件一个都不动（回「未分组」）；
  /// 子组上移到它的上一层（1.55）。
  Future<void> _deleteGroup(NoteGroupDef def) async {
    final count = _groupIndex.pathsOf(def.name).length;
    final children = _groupIndex.childrenOf(def.name).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除组「${def.name}」？'),
        content: Text('组里 $count 篇笔记会回到「未分组」，'
            '${children > 0 ? '它的 $children 个子组会移到上一层，' : ''}'
            '文件一个都不删，手动顺序也不再保留。'),
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
      await widget.store.writeGroups(_groupIndex.deleteGroup(def.name));
      await _reload();
      if (!mounted) return;
      if (_filterGroup == def.name) setState(() => _filterGroup = null);
      _toast('已删除组「${def.name}」，$count 篇笔记回到未分组');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  /// 「移动到组…」：一篇笔记同时只在一个组里，单选。
  Future<void> _moveNote(NoteFile note) async {
    final current = _groupIndex.groupOf(note.relPath) ?? '';
    final ordered = <NoteGroupDef>[];
    void walk(NoteGroupDef def) {
      ordered.add(def);
      for (final child in _groupIndex.childrenOf(def.name)) {
        walk(child);
      }
    }

    for (final root in _groupIndex.roots) {
      walk(root);
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _MoveToGroupDialog(
        title: '把「${note.title}」移到…',
        current: current,
        groups: ordered,
        depths: <String, int>{
          for (final def in ordered) def.name: _groupIndex.depthOf(def.name),
        },
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await widget.store
          .writeGroups(_groupIndex.withNoteGroup(note.relPath, picked));
      await _reload();
      if (!mounted) return;
      _toast(picked.isEmpty ? '已移到未分组' : '已移到「$picked」');
    } on NotesIoException catch (e) {
      _toast(e.message);
    }
  }

  Widget _emptyView() {
    final theme = Theme.of(context);
    final label =
        _filterGroup == null ? '这个视图' : '组「$_filterGroup」';
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
              '「新建」会把笔记存到年/月目录，并归到当前组。',
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
    final sections = _sections();
    if (sections.isEmpty ||
        sections.every((group) => group.notes.isEmpty)) {
      return _emptyView();
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: NoteListBody(
        groups: sections,
        // 组标题永远画（含「未分组」）；折叠时只留标题。
        showHeaders: true,
        // 只有手动顺序可拖；时间排序是临时的，拖了也会被排回去。
        draggable: _isManual,
        now: DateTime.now(),
        selecting: _selecting,
        selected: _selected,
        pinnedNotes: _groupIndex.pins,
        onToggleCollapse: _toggleCollapse,
        onGroupMenu: (group, rect, at) =>
            unawaited(_openGroupMenu(group, rect, at)),
        onCreateInGroup: (group) => unawaited(_createInGroup(group)),
        onSelect: _toggleSelect,
        onOpen: (note) => unawaited(_open(note)),
        onMenu: (note, rect, at) => unawaited(_openMenu(note, rect, at)),
        onReorder: _reorder,
      ),
    );
  }

  /// 拖拽落位：写进这个组的手动顺序，然后重新扫库。
  Future<void> _reorder(String groupKey, List<String> orderedIds) async {
    if (!_isManual || _busy) return;
    try {
      await widget.store.writeGroups(
        _groupIndex.withOrder(groupKey, orderedIds),
      );
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


/// 「移动到组…」的单选对话框：`''` 表示未分组，null = 取消。
class _MoveToGroupDialog extends StatefulWidget {
  const _MoveToGroupDialog({
    required this.title,
    required this.current,
    required this.groups,
    this.depths = const <String, int>{},
  });

  final String title;
  final String current;
  final List<NoteGroupDef> groups;
  final Map<String, int> depths;

  @override
  State<_MoveToGroupDialog> createState() => _MoveToGroupDialogState();
}

class _MoveToGroupDialogState extends State<_MoveToGroupDialog> {
  late String _picked = widget.current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(String value, String label, {int? color}) {
      final selected = _picked == value;
      return ListTile(
        dense: true,
        leading: Icon(
          selected ? Icons.check_circle : Icons.circle_outlined,
          size: 20,
          color: selected ? scheme.primary : scheme.outline,
        ),
        title: Row(
          children: [
            if (color != null) ...[
              Icon(Icons.folder_outlined,
                  size: 16, color: noteGroupColor(color)),
              const SizedBox(width: 6),
            ],
            Expanded(child: Text(label)),
          ],
        ),
        onTap: () => setState(() => _picked = value),
      );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: ListView(
          shrinkWrap: true,
          children: [
            row('', '未分组'),
            for (final def in widget.groups)
              Padding(
                padding: EdgeInsets.only(
                  left: 12.0 * (widget.depths[def.name] ?? 0),
                ),
                child: row(def.name, def.name, color: def.color),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _picked),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
