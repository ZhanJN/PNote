/// 笔记编辑器（1.41 第一步）：左边写 Markdown，右边看渲染结果。
///
/// 三条规矩：
///   1. 输入 900 ms 后自动写盘；退出前一定再写一次，写失败就**不退出**并报错；
///   2. 渲染永远是从当前文本现算的，不缓存到磁盘，不做任何隐藏元数据；
///   3. 「插入素材」= 复制进 `<笔记>.assets/` 并往光标处写 `![[文件名]]`。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_links.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_render.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/common/rename_dialog.dart';
import 'package:pnote/ui/notes/block_editor.dart';

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.note,
    required this.store,
    required this.hasNote,
    required this.openNote,
    this.initialAnchor,
  });

  final NoteFile note;
  final NotesStore store;
  final bool Function(String stem) hasNote;

  /// 点 `[[笔记#要点]]` 时传进来的锚点：进页面后直接定位到那个标题（1.44）。
  final String? initialAnchor;

  /// 收到的是 `[[ ]]` 里的原串，可能带 `#锚点`，交给 [NotesView] 再拆一次。
  final void Function(String stem) openNote;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final TextEditingController _controller = TextEditingController();
  final GlobalKey<BlockEditorState> _blockKey = GlobalKey<BlockEditorState>();
  var _blocksSerial = 0;
  int? _focusHeadingIndex;
  final ScrollController _scroll = ScrollController();
  Timer? _saveTimer;
  Map<String, File> _assets = <String, File>{};
  NoteDoc? _doc;
  List<GlobalKey> _headingKeys = const <GlobalKey>[];
  bool _loading = true;
  bool _preview = false;
  bool _source = false;
  bool _dirty = false;
  bool _saving = false;
  String? _error;
  DateTime? _savedAt;

  late NoteFile _note;
  bool _mute = false;

  String get _relPath => _note.relPath;
  String get _noteId => _note.id;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await widget.store.read(_relPath);
      final assets = await widget.store.assetsOf(_noteId);
      if (!mounted) return;
      setState(() {
        _controller.text = text;
        _assets = assets;
        _loading = false;
        _dirty = false;
        _blocksSerial++;
        // 1.55：已有内容的笔记默认进预览；只有空白笔记直接进编辑。
        // 渲染/解析出错时回撤到编辑模式，绝不把用户挡在错误页上。
        final hasContent = text.trim().isNotEmpty;
        if (hasContent) {
          try {
            _doc = parseNoteSource(text, keepBlankLines: true);
            _headingKeys = List<GlobalKey>.generate(
              _doc!.headingItems.length,
              (_) => GlobalKey(),
            );
            _preview = true;
          } catch (_) {
            _preview = false;
            _doc = null;
            _headingKeys = const <GlobalKey>[];
          }
        }
      });
      _controller.addListener(_onChanged);
      _applyInitialAnchor();
    } on NotesIoException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 带着 `#锚点` 进来时，把光标放到对应标题那一行（1.44）。
  void _applyInitialAnchor() {
    final anchor = widget.initialAnchor;
    if (anchor == null || anchor.trim().isEmpty) return;
    final doc = parseNoteSource(_controller.text);
    final index = doc.headingItems.indexWhere((item) => item.matches(anchor));
    if (index < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showMessage('这篇笔记里没有「$anchor」这个标题');
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToHeading(index, doc);
    });
  }

  void _onChanged() {
    if (_mute) return;
    if (!_dirty) setState(() => _dirty = true);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _save);
  }

  Future<void> _save() async {
    if (!_dirty || _saving) return;
    final text = _controller.text;
    setState(() => _saving = true);
    try {
      await widget.store.write(_relPath, text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _error = null;
        _savedAt = DateTime.now();
      });
      if (_preview) {
        try {
          _refreshDoc();
        } catch (_) {
          setState(() => _preview = false);
          _showMessage('预览失败，已切回编辑模式');
        }
      }
    } on NotesIoException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
      _showMessage(e.message);
    }
  }

  void _refreshDoc() {
    _doc = parseNoteSource(_controller.text, keepBlankLines: true);
    _headingKeys = List<GlobalKey>.generate(
      _doc!.headingItems.length,
      (_) => GlobalKey(),
    );
  }

  /// 大纲（1.44）：列出所有标题，点一条跳过去。
  Future<void> _showOutline() async {
    final doc = parseNoteSource(_controller.text);
    final items = doc.headingItems;
    if (items.isEmpty) {
      _showMessage('这篇笔记还没有标题：正文里用「# 标题」开头就会出现在大纲里');
      return;
    }
    final index = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: Text('大纲（${items.length} 个标题）'),
              subtitle: Text(_preview ? '点一条滚到那里' : '点一条把光标挪过去'),
            ),
            for (var i = 0; i < items.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.only(
                  left: 16.0 + (items[i].level - 1) * 16.0,
                  right: 16,
                ),
                leading: Icon(
                  items[i].level == 1
                      ? Icons.title
                      : Icons.subdirectory_arrow_right,
                  size: 18,
                ),
                title: Text(
                  items[i].text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheetContext).pop(i),
              ),
          ],
        ),
      ),
    );
    if (index == null || !mounted) return;
    _jumpToHeading(index, doc);
  }

  /// 跳到第 [index] 个标题：预览态滚动过去，编辑态把光标放过去（1.44）。
  void _jumpToHeading(int index, NoteDoc doc) {
    if (index < 0 || index >= doc.headingItems.length) return;
    if (_preview) {
      if (index >= _headingKeys.length) return;
      final target = _headingKeys[index].currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 220),
        alignment: 0.05,
      );
      return;
    }
    final offset = doc.headingItems[index].offset;
    final text = _controller.text;
    final caret = offset > text.length ? text.length : offset;
    _controller.selection = TextSelection.collapsed(offset: caret);
    // 1.57：块编辑器里没法只设一个全局光标，改成「聚焦第 N 个标题块」。
    setState(() {
      _focusHeadingIndex = index;
      _blocksSerial++;
    });
  }

  /// 1.60：源码模式——直接编辑整篇 Markdown，给需要精确控制格式的时候用。
  void _toggleSource() {
    setState(() {
      _source = !_source;
      if (_source) _preview = false;
      FocusManager.instance.primaryFocus?.unfocus();
    });
    if (!_source) _blocksSerial++;
  }

  void _togglePreview() {
    if (_source) setState(() => _source = false);
    if (_preview) {
      setState(() => _preview = false);
      // 预览时锚点只能滚动，切回编辑后把光标补放到那一节。
      final anchor = widget.initialAnchor;
      if (anchor != null && anchor.trim().isNotEmpty) {
        final doc = parseNoteSource(_controller.text);
        final index =
            doc.headingItems.indexWhere((item) => item.matches(anchor));
        if (index >= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToHeading(index, doc);
          });
        }
      }
      return;
    }
    try {
      _refreshDoc();
    } catch (_) {
      // 解析/渲染出错：不进预览，留在编辑模式。
      _showMessage('这篇笔记的格式有点问题，先在编辑模式里改一下');
      return;
    }
    setState(() => _preview = true);
  }

  /// 块编辑器改完文本后回写到 `_controller`（保存/大纲/字数都还是看它）。
  void _onBlocksChanged(String text) {
    if (_mute) return;
    _mute = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _mute = false;
    _onChanged();
  }

  /// 选图 + 导入素材，返回素材名（工具栏和 AppBar 的插入图片共用）。
  Future<String?> _importAssetName() async {
    final picked = await openFile();
    if (picked == null) return null;
    try {
      final name = await widget.store.importAsset(_note, File(picked.path));
      final assets = await widget.store.assetsOf(_noteId);
      if (mounted) setState(() => _assets = assets);
      return name;
    } on NotesIoException catch (e) {
      _showMessage(e.message);
      return null;
    }
  }

  /// 选一篇笔记，返回 `[[名字]]` 片段。
  Future<String?> _pickLinkSnippet() async {
    List<NoteFile> notes;
    try {
      notes = await widget.store.list();
    } on NotesIoException catch (e) {
      _showMessage(e.message);
      return null;
    }
    if (!mounted) return null;
    final stem = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('插入笔记链接'), dense: true),
            for (final note in notes)
              ListTile(
                leading: const Icon(Icons.article_outlined, size: 18),
                title: Text(linkStemOf(note.relPath)),
                onTap: () => Navigator.of(context).pop(linkStemOf(note.relPath)),
              ),
          ],
        ),
      ),
    );
    if (stem == null) return null;
    return '[[$stem]]';
  }

  Future<void> _insertAsset() async {
    final name = await _importAssetName();
    if (name == null || !mounted) return;
    _blockKey.currentState?.insertImageBlock(name);
    _showMessage('已插入素材：$name');
  }

  Future<void> _insertLink() async {
    final snippet = await _pickLinkSnippet();
    if (snippet == null || !mounted) return;
    _blockKey.currentState?.insertSnippet(snippet);
  }

  /// 反向链接（1.43）：谁引用了这篇笔记。点一条直接跳过去。
  Future<void> _showBacklinks() async {
    final stem = linkStemOf(_relPath);
    List<NoteFile> notes;
    try {
      notes = await widget.store.list();
    } on NotesIoException catch (e) {
      _showMessage(e.message);
      return;
    }
    final sources = <String, String>{};
    for (final note in notes) {
      if (note.relPath == _relPath) continue;
      try {
        sources[note.relPath] = await widget.store.read(note.relPath);
      } on NotesIoException {
        // 单篇读不出来就跳过，不为了一个坏文件毁掉整个面板。
      }
    }
    if (!mounted) return;
    final links = backlinksOf(
      notes: notes,
      sources: sources,
      selfRelPath: _relPath,
      stem: stem,
    );
    final broken = brokenLinksOf(_controller.text, widget.hasNote);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: Text(
                links.isEmpty ? '还没有别的笔记引用它' : '被 ${links.length} 篇笔记引用',
              ),
            ),
            for (final link in links)
              ListTile(
                leading: const Icon(Icons.link, size: 18),
                title: Text(
                  link.note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('引用 ${link.hits} 次'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openRef(linkStemOf(link.note.relPath));
                },
              ),
            if (broken.isNotEmpty)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.link_off,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text('断链 ${broken.length} 处：${broken.join('、')}'),
                subtitle: const Text('预览里红色的就是，点它可以新建'),
              ),
          ],
        ),
      ),
    );
  }

  /// 点 `[[名字]]`：有就打开，没有就问要不要新建一篇（1.43）；
  /// 带 `#锚点` 时把锚点一起交给上层，打开后直接定位（1.44）。
  Future<void> _openRef(String raw) async {
    if (!mounted) return;
    final stem = normalizeRefKey(raw);
    if (!widget.hasNote(stem)) {
      final create = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('还没有这篇笔记'),
          content: Text('「$stem」不在笔记库里。要现在新建一篇吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('新建'),
            ),
          ],
        ),
      );
      if (create != true || !mounted) return;
      try {
        await widget.store.create(stem);
      } on NotesIoException catch (e) {
        _showMessage(e.message);
        return;
      }
      if (!mounted) return;
    }
    final navigator = Navigator.of(context);
    navigator.pop();
    widget.openNote(raw);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _flushBeforeLeave() async {
    if (!_dirty) return true;
    await _save();
    return !_dirty;
  }

  /// 改标题（1.42）：点 AppBar 上的标题 → 文件名与正文第一行 `# 标题` 一起改。
  ///
  /// 列表里显示的是正文标题行，只改文件名会让人以为「改了没生效」——用户
  /// 1.42 反馈的正是这个。两处必须同步，见 notes_store.dart 的
  /// `_syncHeadingToStem`。
  Future<void> _rename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        initialTitle: linkStemOf(_note.relPath),
        title: '改标题',
      ),
    );
    if (!mounted || name == null) return;
    final clean = name.trim();
    if (clean.isEmpty) return;
    try {
      await _save(); // 先把还没落盘的改动写下去，再改名
      final updated = await widget.store.renameFile(_note, clean);
      final text = await widget.store.read(updated.relPath);
      final assets = await widget.store.assetsOf(updated.id);
      if (!mounted) return;
      _mute = true;
      _controller.text = text;
      _mute = false;
      setState(() {
        _note = updated.copyWith(title: clean);
        _assets = assets;
        _dirty = false;
        _savedAt = DateTime.now();
        _error = null;
        _blocksSerial++;
      });
      _showMessage('已改名为「$clean」');
    } on NotesIoException catch (e) {
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final ok = await _flushBeforeLeave();
        if (!mounted) return;
        if (!ok) return; // 写失败就不退，避免用户以为存上了
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: InkWell(
            onTap: _rename,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.edit_outlined, size: 16),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: '大纲（跳到标题）',
              onPressed: _showOutline,
              icon: const Icon(Icons.format_list_bulleted),
            ),
            IconButton(
              tooltip: '反向链接（谁引用了这篇）',
              onPressed: _showBacklinks,
              icon: const Icon(Icons.hub_outlined),
            ),
            IconButton(
              tooltip: _source ? '回到块编辑' : '源码模式（纯 Markdown）',
              onPressed: _toggleSource,
              icon: Icon(_source ? Icons.view_agenda_outlined : Icons.code),
            ),
            IconButton(
              tooltip: _preview ? '回到编辑' : '预览',
              onPressed: _togglePreview,
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
            ),
            IconButton(
              tooltip: '插入素材（图片/附件）',
              onPressed: _insertAsset,
              icon: const Icon(Icons.attach_file),
            ),
            IconButton(
              tooltip: '插入笔记链接',
              onPressed: _insertLink,
              icon: const Icon(Icons.link),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(22),
            child: _statusBar(),
          ),
        ),
        body: _body(),
      ),
    );
  }

  Widget _statusBar() {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final (text, color) = switch (true) {
          _ when _error != null => ('保存失败：$_error', theme.colorScheme.error),
          _ when _saving => ('正在保存…', theme.hintColor),
          _ when _dirty => ('未保存', theme.colorScheme.tertiary),
          _ when _savedAt != null => ('已保存 ${_clock(_savedAt!)}', theme.hintColor),
          _ => ('已是最新', theme.hintColor),
        };
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ),
              Text(
                '${countChars(value.text)} 字',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null && _controller.text.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(error, textAlign: TextAlign.center),
      ));
    }
    if (_preview) {
      final doc = _doc ?? parseNoteSource(_controller.text, keepBlankLines: true);
      if (_headingKeys.length != doc.headingItems.length) {
        _headingKeys = List<GlobalKey>.generate(
          doc.headingItems.length,
          (_) => GlobalKey(),
        );
      }
      return SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        // 1.56：预览在电脑上不拉满整块屏（一行太长难读），手机上仍是满宽。
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: NoteRender(
              doc: doc,
              assets: _assets,
              hasNote: widget.hasNote,
              openNote: _openRef,
              openAsset: _openAsset,
              openUrl: _copyUrl,
              headingKeys: _headingKeys,
            ),
          ),
        ),
      );
    }
    // 1.60：源码模式，直接编辑纯 Markdown。
    if (_source) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 14,
            height: 1.5,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '这里是纯 Markdown，可以直接改',
          ),
        ),
      );
    }
    // 1.57：块状编辑器。每个段落是一个块，标题/列表/待办/图片直接在原位排版。
    return BlockEditor(
      key: ValueKey<String>('blocks-$_blocksSerial-${_note.relPath}'),
      initialText: _controller.text,
      onChanged: _onBlocksChanged,
      assetPath: (name) => _assets[name]?.path,
      onPickImage: _importAssetName,
      onPickLink: _pickLinkSnippet,
      focusHeadingIndex: _focusHeadingIndex,
    );
  }

  Future<void> _openAsset(File file, String name) async {
    if (!Platform.isWindows) {
      _showMessage('这个附件在库里：${file.path}');
      return;
    }
    try {
      await Process.run('explorer', [file.path]);
    } on ProcessException catch (e) {
      _showMessage('打不开：${e.message}');
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    _showMessage('链接已复制：$url');
  }

  String _clock(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }
}
