/// 1.57：块状笔记编辑器（仿小米笔记的第一版）。
///
/// 每段文字是一个块：标题、正文、列表、待办、引用、代码、分割线、图片。
/// 源文件仍是 Markdown（见 markdown_blocks.dart），这里只负责「边写边排版」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/markdown_blocks.dart';

/// 图片路径解析：`![[名字]]` → 本机文件的绝对路径；找不到返回 null。
typedef AssetResolver = String? Function(String name);

class BlockEditor extends StatefulWidget {
  const BlockEditor({
    super.key,
    required this.initialText,
    required this.onChanged,
    required this.assetPath,
    required this.onPickImage,
    required this.onPickLink,
    this.focusHeadingIndex,
    this.autofocus = true,
  });

  final String initialText;
  final ValueChanged<String> onChanged;
  final AssetResolver assetPath;
  final Future<String?> Function() onPickImage;
  final Future<String?> Function() onPickLink;

  /// 从大纲/锚点进来时，把光标放到第 N 个标题块（0 起）。
  final int? focusHeadingIndex;
  final bool autofocus;

  @override
  State<BlockEditor> createState() => BlockEditorState();
}

class _BlockEntry {
  _BlockEntry(this.block)
      : controller = _RichController(text: block.text),
        focus = FocusNode(),
        lastText = block.text;

  final MdBlock block;
  final _RichController controller;
  final FocusNode focus;
  final GlobalKey key = GlobalKey();
  String lastText;

  /// 1.63：工具条抢焦点会把 TextField 的选区清掉。
  /// 记住最后一次「非折叠」选区，点格式按钮时优先用它。
  TextSelection? savedSelection;

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

class BlockEditorState extends State<BlockEditor> {
  late List<_BlockEntry> _entries;
  var _serial = 0;
  var _lastFocused = 0;

  /// 1.63.3：当前块按真实焦点定位。之前用的是构建时捕获的 index，
  /// 增删块后索引会错位（点「删除当前行」删到下一行）。
  int _currentIndex() {
    if (_entries.isEmpty) return 0;
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].focus.hasFocus) return i;
    }
    return _lastFocused.clamp(0, _entries.length - 1);
  }

  // 1.59：整块跨行框选（不是文本选区）。
  // 1.60：改为长按 450 ms 才进入，避免拖动/点按误触；进入后可点按或拖动扩展。
  int? _selAnchor;
  int? _selFocus;
  bool _blockSelecting = false;
  final ScrollController _scroll = ScrollController();
  final GlobalKey _listBoxKey = GlobalKey();
  final GlobalKey _barKey = GlobalKey();
  final GlobalKey _toolbarKey = GlobalKey();
  Timer? _edgeTimer;
  Offset? _pointerAt;
  Offset? _downAt;
  Timer? _longPress;
  bool _pointerDown = false;

  @override
  void initState() {
    super.initState();
    _buildEntries(widget.initialText);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didUpdateWidget(covariant BlockEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 1.63：不按 initialText 的差异重建——父层回写的 controller 可能比
    // 这里的 _encode() 慢一拍，按差异重建会把刚输入的一行“吞掉”。
    // 需要外部重建时，父层会换 key（_blocksSerial）。
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    for (final entry in _entries) {
      entry.dispose();
    }
    super.dispose();
  }

  void _buildEntries(String text) {
    final blocks = MdBlock.parseBlocks(text);
    if (blocks.isEmpty) blocks.add(MdBlock.emptyParagraph());
    _entries = [
      for (final block in blocks)
        _BlockEntry(block),
    ];
    if (widget.autofocus && _entries.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusHeading(widget.focusHeadingIndex ?? 0);
      });
    }
  }

  void _focusHeading(int headingIndex) {
    if (headingIndex < 0) return;
    var seen = -1;
    for (final entry in _entries) {
      final kind = entry.block.kind;
      if (kind == MdBlockKind.heading1 ||
          kind == MdBlockKind.heading2 ||
          kind == MdBlockKind.heading3) {
        seen++;
        if (seen == headingIndex) {
          entry.focus.requestFocus();
          entry.controller.selection = TextSelection.collapsed(
            offset: entry.controller.text.length,
          );
          return;
        }
      }
    }
  }

  String _encode() => MdBlock.encodeBlocks([for (final e in _entries) e.block]);

  void _notify() {
    widget.onChanged(_encode());
  }

  /// 1.63：外部（AppBar 切源码/预览/保存前）调用，把还没回写的输入提交出来。
  /// 返回最新的 Markdown，保证切模式时不会丢最后一行。
  String flush() {
    var changed = false;
    for (final entry in _entries) {
      final text = entry.controller.text;
      if (text != entry.block.text) {
        entry.block.text = text;
        entry.lastText = text;
        changed = true;
      }
    }
    if (changed) _notify();
    return _encode();
  }

  void _onBlockTextChanged(_BlockEntry entry, String value) {
    final index = _entries.indexOf(entry);
    if (index < 0) return; // 块已在重组中被移除，旧回调直接忽略
    // 回车拆块：只在「比上一次恰好多一个换行」时拆。
    if (value.length == entry.lastText.length + 1) {
      final at = _insertedNewlineIndex(entry.lastText, value);
      if (at >= 0) {
        _splitAt(index, at, value);
        return;
      }
    }
    // 1.63：粘贴多行（含空行）时一次拆成多个块，不能把整段塞进一个块里，
    // 否则切模式/保存后空行会丢、行会“占位但没内容”。
    if (value.contains('\n') && value != entry.lastText) {
      _applyMultiline(index, value);
      return;
    }
    entry.block.text = value;
    entry.lastText = value;
    _notify();
  }

  /// 把一段含换行的文本拆成多个块；空行保留为 blank 块。
  void _applyMultiline(int index, String value) {
    final parts = value.split('\n');
    final entry = _entries[index];
    final first = parts.first;
    final created = <_BlockEntry>[];
    entry.block.text = first;
    entry.lastText = first;
    entry.controller.value = TextEditingValue(
      text: first,
      selection: TextSelection.collapsed(offset: first.length),
    );
    for (var i = 1; i < parts.length; i++) {
      final segment = parts[i];
      final block = segment.isEmpty
          ? MdBlock(MdBlockKind.blank, '')
          : MdBlock(MdBlockKind.paragraph, segment);
      created.add(_BlockEntry(block));
    }
    setState(() {
      _entries.insertAll(index + 1, created);
    });
    _notify();
    final last = created.isEmpty ? entry : created.last;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      last.focus.requestFocus();
      last.controller.selection =
          TextSelection.collapsed(offset: last.controller.text.length);
    });
  }

  int _insertedNewlineIndex(String oldValue, String newValue) {
    if (newValue.length != oldValue.length + 1) return -1;
    final at = newValue.indexOf('\n');
    if (at < 0) return -1;
    if (newValue.substring(0, at) + newValue.substring(at + 1) == oldValue) {
      return at;
    }
    return -1;
  }

  void _splitAt(int index, int at, String value) {
    final entry = _entries[index];
    final before = value.substring(0, at);
    final after = value.substring(at + 1);
    final kind = entry.block.kind;
    final nextKind = switch (kind) {
      MdBlockKind.heading1 ||
      MdBlockKind.heading2 ||
      MdBlockKind.heading3 ||
      MdBlockKind.quote ||
      MdBlockKind.code ||
      MdBlockKind.table ||
      MdBlockKind.divider ||
      MdBlockKind.image =>
        MdBlockKind.paragraph,
      _ => kind,
    };
    final newEntry = _BlockEntry(MdBlock(nextKind, after));
    setState(() {
      entry.block.text = before;
      entry.lastText = before;
      entry.controller.value = TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: before.length),
      );
      _entries.insert(index + 1, newEntry);
    });
    _notify();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      newEntry.focus.requestFocus();
      newEntry.controller.selection = const TextSelection.collapsed(offset: 0);
    });
  }

  /// 外部（AppBar 的「插入素材」）插一张图片块。
  /// 1.60：手机软键盘在空行上不产生 onChanged，给工具条一个显式的「删行」。
  /// 语义和退格一致：有内容先清空，空了再按一次才并到上一块。
  void deleteCurrentRow() {
    if (_entries.length > 1) {
      final index = _currentIndex();
      final entry = _entries[index];
      if (entry.controller.text.isNotEmpty &&
          entry.block.kind != MdBlockKind.image &&
          entry.block.kind != MdBlockKind.divider) {
        final value = entry.controller.value;
        entry.controller.value = value.copyWith(
          text: '',
          selection: const TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        );
        entry.block.text = '';
        entry.lastText = '';
        _notify();
        return;
      }
      if (index > 0) {
        _mergeIntoPrevious(index);
      } else {
        _mergeNext(index);
      }
      return;
    }
    final only = _entries.first;
    only.controller.value = const TextEditingValue();
    only.block.text = '';
    only.lastText = '';
    _notify();
  }

  void insertImageBlock(String name) {
    final entry = MdBlock(MdBlockKind.image, '![[$name]]', imageName: name);
    final newEntry =
        _BlockEntry(entry);
    final at = _lastFocused.clamp(0, _entries.length);
    setState(() => _entries.insert(at + 1, newEntry));
    _notify();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      newEntry.focus.requestFocus();
    });
  }

  void _insertDivider() {
    final entry = MdBlock(MdBlockKind.divider, '');
    final newEntry =
        _BlockEntry(entry);
    final at = _lastFocused.clamp(0, _entries.length);
    setState(() => _entries.insert(at + 1, newEntry));
    _notify();
  }

  Future<void> _pickImage() async {
    final name = await widget.onPickImage();
    if (name == null || name.isEmpty || !mounted) return;
    insertImageBlock(name);
  }

  /// 在光标处插入一段 Markdown（AppBar 的「插入笔记链接」用）。
  void insertSnippet(String snippet) => _wrapSelection(snippet, '');

  Future<void> _pickLink() async {
    final snippet = await widget.onPickLink();
    if (snippet == null || !mounted) return;
    _wrapSelection(snippet, snippet);
  }

  void _wrapSelection(String left, String right) {
    final index = _currentIndex();
    final entry = _entries[index];
    final value = entry.controller.value;
    final selection = _effectiveSelection(entry);
    final text = value.text;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    // 1.59：空行 / 行首行尾不放标记——「功能键落在空处」应当没反应。
    if (start == end && (text.trim().isEmpty || start == 0 || start == text.length)) {
      return;
    }
    final selected = text.substring(start, end);
    final replaced = text.replaceRange(start, end, '$left$selected$right');
    entry.controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(
        offset: start + left.length + selected.length + right.length,
      ),
    );
    entry.block.text = replaced;
    entry.lastText = replaced;
    entry.savedSelection = null;
    entry.focus.requestFocus();
    _notify();
  }

  /// 1.63：工具条抢焦点时，TextField 的选区会变成无效/折叠。
  /// 优先用当前有效选区，其次用最后一次记住的非折叠选区。
  TextSelection _effectiveSelection(_BlockEntry entry) {
    final current = entry.controller.selection;
    if (current.isValid && !current.isCollapsed) return current;
    final saved = entry.savedSelection;
    final length = entry.controller.text.length;
    if (saved != null && saved.isValid && !saved.isCollapsed && saved.end <= length) {
      return saved;
    }
    return current;
  }

  void _rememberSelections() {
    for (final entry in _entries) {
      final selection = entry.controller.selection;
      if (selection.isValid && !selection.isCollapsed) {
        entry.savedSelection = selection;
      }
    }
  }

  /// 工具条开关：已经是这个格式就取消，否则加上；不会叠第二层标记。
  /// 1.63.2：加/去标记后把选区放回正文，而不是跳到块尾——否则看起来
  /// 像「App 的逻辑光标」和「屏幕上闪的光标」分了家，还得再点一次。
  void _toggleWrap(String open, String close) {
    final index = _currentIndex();
    final entry = _entries[index];
    final text = entry.controller.text;
    if (text.trim().isEmpty) return;
    final selection = _effectiveSelection(entry);
    final hasSel = selection.isValid && !selection.isCollapsed;
    final start = hasSel ? selection.start : 0;
    final end = hasSel ? selection.end : text.length;

    if (!hasSel) {
      final caret = selection.isValid ? selection.start : text.length;
      if (text.length >= open.length + close.length &&
          text.startsWith(open) &&
          text.endsWith(close)) {
        final inner = text.substring(open.length, text.length - close.length);
        if (!inner.contains(open) && !inner.contains(close)) {
          final next = caret - open.length;
          _commitSel(
            entry,
            inner,
            TextSelection.collapsed(offset: next.clamp(0, inner.length)),
          );
          return;
        }
      }
      final next = '$open$text$close';
      _commitSel(
        entry,
        next,
        TextSelection.collapsed(
          offset: (caret + open.length).clamp(0, next.length),
        ),
      );
      return;
    }

    final selected = text.substring(start, end);
    final wrapped = selected.length >= open.length + close.length &&
        selected.startsWith(open) &&
        selected.endsWith(close);
    final surrounded = start >= open.length &&
        end + close.length <= text.length &&
        text.substring(start - open.length, start) == open &&
        text.substring(end, end + close.length) == close;
    if (wrapped) {
      final inner = selected.substring(open.length, selected.length - close.length);
      final next = text.replaceRange(start, end, inner);
      _commitSel(
        entry,
        next,
        TextSelection(baseOffset: start, extentOffset: start + inner.length),
      );
    } else if (surrounded) {
      final next =
          text.replaceRange(start - open.length, end + close.length, selected);
      final s = start - open.length;
      _commitSel(
        entry,
        next,
        TextSelection(baseOffset: s, extentOffset: s + selected.length),
      );
    } else {
      final next = text.replaceRange(start, end, '$open$selected$close');
      final s = start + open.length;
      _commitSel(
        entry,
        next,
        TextSelection(baseOffset: s, extentOffset: s + selected.length),
      );
    }
  }

  static final RegExp _hlPattern =
      RegExp(r'==\{([yrgbp])\}([^\n]*?)==|==([^\n]*?)==');

  /// 1.63.2：高亮按「选区是否已经全部上色」判断，不按层叠加。
  /// - 选区里只要有一段没上色 → 整段上所选颜色（原来的颜色被覆盖）；
  /// - 选区已经全部上色（可能混着不同颜色）→ 整段取消颜色；
  /// - 没有选区时，把整块当作选区。
  void _toggleHighlight(String code) {
    if (_entries.isEmpty) return;
    final entry = _entries[_currentIndex()];
    final text = entry.controller.text;
    if (text.trim().isEmpty) return;
    final selection = _effectiveSelection(entry);
    final hasSel = selection.isValid && !selection.isCollapsed;
    final start = hasSel ? selection.start : 0;
    final end = hasSel ? selection.end : text.length;
    if (end <= start) return;
    final plan = _highlightPlan(text, start, end, code);
    _commitSel(entry, plan.$1, plan.$2);
  }

  /// 返回（新文本, 新选区）。标记字符不参与「是否上色」的判断。
  (String, TextSelection) _highlightPlan(
    String text,
    int start,
    int end,
    String code,
  ) {
    final markers = <int>{};
    final owner = <int, String>{};
    for (final m in _hlPattern.allMatches(text)) {
      final color = m.group(1) ?? 'y';
      final openLen = m.group(1) == null ? 2 : 5;
      final bodyStart = m.start + openLen;
      final bodyEnd = m.end - 2;
      for (var i = m.start; i < bodyStart; i++) {
        markers.add(i);
      }
      for (var i = bodyEnd; i < m.end; i++) {
        markers.add(i);
      }
      for (var i = bodyStart; i < bodyEnd; i++) {
        owner[i] = color;
      }
    }

    var covered = true;
    final colors = <String>{};
    final plain = StringBuffer();
    for (var i = start; i < end; i++) {
      if (markers.contains(i)) continue;
      plain.write(text[i]);
      final color = owner[i];
      if (color == null) {
        covered = false;
      } else {
        colors.add(color);
      }
    }
    if (plain.isEmpty) {
      return (text, TextSelection.collapsed(offset: start));
    }
    final head = _keepHighlights(text, 0, start, markers, owner);
    final tail = _keepHighlights(text, end, text.length, markers, owner);

    // 全部上色、而且就是这次点的颜色 → 取消；否则用所选颜色覆盖。
    // 混着两种以上颜色也按「覆盖」处理，不会越叠越多。
    final sameColor = covered && colors.length == 1 && colors.first == code;
    if (sameColor) {
      final next = '$head$plain$tail';
      return (
        next,
        TextSelection(
          baseOffset: head.length,
          extentOffset: head.length + plain.length,
        ),
      );
    }
    final open = code == 'y' ? '==' : '=={$code}';
    final next = '$head$open$plain==$tail';
    final s = head.length + open.length;
    return (
      next,
      TextSelection(baseOffset: s, extentOffset: s + plain.length),
    );
  }

  /// 保留区间里原有的高亮（跳过标记字符）；跨边界的着色在边界处收口，
  /// 这样只改选中范围，不会把整块其它颜色的高亮一起抹掉。
  String _keepHighlights(
    String text,
    int from,
    int to,
    Set<int> markers,
    Map<int, String> owner,
  ) {
    final out = StringBuffer();
    final run = StringBuffer();
    String? runColor;

    void flush() {
      if (run.isEmpty) return;
      final color = runColor ?? 'y';
      out.write(color == 'y' ? '==' : '=={$color}');
      out.write(run);
      out.write('==');
      run.clear();
      runColor = null;
    }

    for (var i = from; i < to; i++) {
      if (markers.contains(i)) continue;
      final color = owner[i];
      if (color == null) {
        flush();
        out.write(text[i]);
      } else if (runColor == color) {
        run.write(text[i]);
      } else {
        flush();
        runColor = color;
        run.write(text[i]);
      }
    }
    flush();
    return out.toString();
  }

  /// 1.63.2：一次提交同时给定文本和选区。
  /// 以前只给一个折叠光标，工具条操作后光标会跳到块尾，看起来像
  /// 「App 的逻辑光标」和「屏幕上闪的系统光标」分了家；这里让选区
  /// 跟着文本走（加标记就选中标记内的正文，去标记就选中原文）。
  void _commitSel(_BlockEntry entry, String next, TextSelection selection) {
    entry.controller.value = TextEditingValue(
      text: next,
      selection: selection,
    );
    entry.block.text = next;
    entry.lastText = next;
    entry.savedSelection = null;
    entry.focus.requestFocus();
    _notify();
  }

  void _mergeIntoPrevious(int index) {    if (index <= 0) return;
    final current = _entries[index];
    final previous = _entries[index - 1];
    if (previous.block.kind == MdBlockKind.image) return;
    // 1.60：分割线当作「一整行」删掉，不把文字接过去，和删行的直觉一致。
    if (previous.block.kind == MdBlockKind.divider) {
      setState(() {
        _entries.removeAt(index - 1);
        previous.dispose();
      });
      _notify();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        current.focus.requestFocus();
      });
      return;
    }
    final before = previous.controller.text;
    final merged = before + current.controller.text;
    setState(() {
      _entries.removeAt(index);
      current.dispose();
      previous.block.text = merged;
      previous.lastText = merged;
    });
    _notify();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      previous.controller.value = TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: before.length),
      );
      previous.focus.requestFocus();
      previous.controller.selection =
          TextSelection.collapsed(offset: before.length);
    });
  }

  void _mergeNext(int index) {
    if (index >= _entries.length - 1) return;
    final current = _entries[index];
    final next = _entries[index + 1];
    if (next.block.kind == MdBlockKind.image) return;
    if (next.block.kind == MdBlockKind.divider) {
      setState(() {
        _entries.removeAt(index + 1);
        next.dispose();
      });
      _notify();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        current.focus.requestFocus();
      });
      return;
    }
    final before = current.controller.text;
    final merged = before + next.controller.text;
    setState(() {
      _entries.removeAt(index + 1);
      next.dispose();
      current.block.text = merged;
      current.lastText = merged;
    });
    _notify();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      current.controller.value = TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: before.length),
      );
      current.focus.requestFocus();
      current.controller.selection =
          TextSelection.collapsed(offset: before.length);
    });
    return;
  }

  /// 块首退格 / 块尾 Delete 的兜底：EditableText 在边界会直接把键吃掉，
  /// 所以用 HardwareKeyboard 全局监听，命中边界时合并块并返回 true。
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || _entries.isEmpty) return false;
    if (_blockSelecting) {
      final key = event.logicalKey;
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (key == LogicalKeyboardKey.escape) {
        _clearBlockSelection();
        return true;
      }
      if (ctrl && key == LogicalKeyboardKey.keyC) {
        _copySelected();
        return true;
      }
      if (ctrl && key == LogicalKeyboardKey.keyX) {
        _cutSelected();
        return true;
      }
      if (ctrl && key == LogicalKeyboardKey.keyA) {
        setState(() {
          _selAnchor = 0;
          _selFocus = _entries.length - 1;
        });
        return true;
      }
      if (key == LogicalKeyboardKey.delete ||
          key == LogicalKeyboardKey.backspace) {
        _deleteSelected();
        return true;
      }
      return false;
    }
    final index = _currentIndex();
    final entry = _entries[index];
    if (!entry.focus.hasFocus) return false;
    final selection = entry.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        selection.baseOffset == 0) {
      _mergeIntoPrevious(index);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete &&
        selection.baseOffset == entry.controller.text.length) {
      _mergeNext(index);
      return true;
    }
    return false;
  }

  void _convert(MdBlockKind kind) {
    final index = _currentIndex();
    final entry = _entries[index];
    // 再点一次同一个类型 → 回到正文（标题/列表/引用/代码都是开关）。
    final target = entry.block.kind == kind && kind != MdBlockKind.paragraph
        ? MdBlockKind.paragraph
        : kind;
    setState(() {
      entry.block.kind = target;
      if (target == MdBlockKind.divider) entry.block.text = '';
      final encoded = entry.controller.text;
      if (encoded.isEmpty && target == MdBlockKind.code) entry.block.text = '';
    });
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: (_) {
        // 手机上输入法/文本框的长按识别器抢手势时会发 cancel；
        // 已经在整块选择里就不要被它打断，否则一拖就退出选择。
        if (_blockSelecting) {
          _stopEdgeScroll();
        } else {
          _clearBlockSelection();
        }
      },
      onPointerSignal: (event) {
        if (!_blockSelecting || !_scroll.hasClients) return;
        if (event is PointerScrollEvent) {
          final max = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(
            (_scroll.offset + event.scrollDelta.dy).clamp(0.0, max),
          );
        }
      },
      child: Column(
        children: [
          if (_blockSelecting)
            KeyedSubtree(key: _barKey, child: _blockSelectionBar(theme)),
          Expanded(
            child: MouseRegion(
              // 1.63.4：整块选择时把系统 I 形光标收掉，只显示 App 自己的选区。
              cursor: _blockSelecting
                  ? SystemMouseCursors.basic
                  : MouseCursor.defer,
              child: KeyedSubtree(
              key: ValueKey(_serial),
              child: ListView.builder(
                key: _listBoxKey,
                controller: _scroll,
                physics:
                    _blockSelecting ? const NeverScrollableScrollPhysics() : null,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
                itemCount: _entries.length,
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  final selected = _blockSelecting && _isSelected(index);
                  return Container(
                    key: entry.key,
                    color: selected
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : null,
                    child: IgnorePointer(
                      ignoring: _blockSelecting,
                      child: _buildRow(context, index, theme),
                    ),
                  );
                },
              ),
            ),
            ),
          ),
          KeyedSubtree(key: _toolbarKey, child: _toolbar(theme)),
        ],
      ),
    );
  }

  bool _isSelected(int index) {
    final a = _selAnchor;
    final b = _selFocus;
    if (a == null || b == null) return false;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    return index >= lo && index <= hi;
  }

  int? _rowAt(Offset global, {bool edge = true}) {
    for (var i = 0; i < _entries.length; i++) {
      final box = _entries[i].key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return i;
    }
    // 拖到列表上/下方时，贴边选到首/末块（点击时不启用，免得点选择条也命中首行）。
    if (!edge) return null;
    if (_entries.isEmpty) return null;
    final first = _entries.first.key.currentContext?.findRenderObject() as RenderBox?;
    if (first != null && first.hasSize) {
      final top = first.localToGlobal(Offset.zero).dy;
      if (global.dy < top) return 0;
    }
    final last = _entries.last.key.currentContext?.findRenderObject() as RenderBox?;
    if (last != null && last.hasSize) {
      final bottom = last.localToGlobal(Offset.zero).dy + last.size.height;
      if (global.dy > bottom) return _entries.length - 1;
    }
    return null;
  }

  /// 1.63.1：点「复制/剪切/取消」时，明确把选择条区域排除在选区判定之外，
  /// 否则手机上一按按钮，选区会跳成按钮正下方那一块。
  bool _hitArea(GlobalKey key, Offset global) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.contains(global);
  }

  bool _tapInBar(Offset global) => _hitArea(_barKey, global);

  /// 1.63.4：选择条和底部工具条都算「操作区」，整块选择时指针落到这里
  /// 不能改变选区（否则一按按钮，选区就缩成按钮下方那一块）。
  bool _tapInChrome(Offset global) =>
      _tapInBar(global) || _hitArea(_toolbarKey, global);

  void _onPointerDown(PointerDownEvent event) {
    _rememberSelections();
    if (_tapInChrome(event.position)) {
      _pointerDown = false;
      _longPress?.cancel();
      _longPress = null;
      return;
    }
    final row = _rowAt(event.position, edge: false);
    if (_blockSelecting) {
      // 1.63：点选择条/工具条时 row == null，绝不能把 _pointerAt 挪到那里，
      // 否则贴边滚动会把选区收缩成“按钮下面那一块”。
      if (row != null) {
        _pointerAt = event.position;
        setState(() {
          _selAnchor ??= row;
          _selFocus = row;
        });
      }
      return;
    }
    _pointerDown = true;
    _downAt = event.position;
    _selAnchor = row;
    _selFocus = row;
    _longPress?.cancel();
    if (row == null) return;
    // 1.63.1：320ms 比系统长按（约 400–500ms）更早触发，先接管为整块选择，
    // 避免手机上系统选择菜单和块选择同时出现，复制到错的文本。
    _longPress = Timer(const Duration(milliseconds: 320), () {
      if (!mounted || !_pointerDown) return;
      // 1.63.4：进入整块选择先把文字选区收成光标位置再失焦，
      // 否则系统光标/选区高亮会和 App 的整块选区同时显示。
      for (final entry in _entries) {
        final sel = entry.controller.selection;
        if (sel.isValid) {
          entry.controller.selection = TextSelection.collapsed(
            offset: sel.extentOffset.clamp(0, entry.controller.text.length),
          );
        }
        entry.focus.unfocus();
      }
      setState(() {
        _blockSelecting = true;
        _selFocus = _selAnchor;
      });
      _pointerAt = event.position;
      _startEdgeScroll();
    });
  }

  void _startEdgeScroll() {
    _pointerAt ??= _downAt;
    _edgeTimer?.cancel();
    _edgeTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted) return;
      _edgeTick();
    });
  }

  void _stopEdgeScroll() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _pointerAt = null;
  }

  void _edgeTick() {
    final pointer = _pointerAt ?? _downAt;
    if (!_blockSelecting || pointer == null || !_scroll.hasClients) return;
    if (_tapInChrome(pointer)) return;
    final box = _listBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // 用列表的全局矩形判断，指针跑到列表外（比如压到工具条上）也能继续滚。
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    const zone = 64.0;
    var step = 0.0;
    if (pointer.dy < top + zone) {
      final over = (top + zone - pointer.dy).clamp(0.0, 160.0);
      step = -(8 + over / 10);
    } else if (pointer.dy > bottom - zone) {
      final over = (pointer.dy - (bottom - zone)).clamp(0.0, 160.0);
      step = 8 + over / 10;
    } else {
      return;
    }
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    final next = (_scroll.offset + step).clamp(0.0, max);
    if ((next - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(next);
    final row = _rowAt(pointer);
    if (row != null && row != _selFocus) {
      setState(() => _selFocus = row);
    } else if (row == null) {
      // 指针压在列表外时，按滚动方向把焦点推到首/末行。
      final edge = step < 0 ? 0 : _entries.length - 1;
      if (edge != _selFocus) setState(() => _selFocus = edge);
    }
  }

  TextAlign _textAlignFor(String align) => switch (align) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };

  /// 指针是否在列表（含上下 48 px 缓冲）范围内。用于避免点选择条时误扩展选区。
  bool _withinList(Offset global, {double pad = 0}) {
    final box = _listBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    return global.dy >= top - pad && global.dy <= bottom + pad;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_blockSelecting) {
      // 指针跑到选择条/工具条上时不参与选区扩展，也不贴边滚动。
      if (_tapInChrome(event.position) || !_withinList(event.position)) {
        _stopEdgeScroll();
        return;
      }
      _pointerAt = event.position;
      if (_edgeTimer == null) _startEdgeScroll();
      final row = _rowAt(event.position);
      if (row != null && row != _selFocus) {
        setState(() => _selFocus = row);
      }
      return;
    }
    final down = _downAt;
    if (!_pointerDown || down == null) return;
    // 长按要求指针完全不动；一有位移就取消，直接拖拉选字优先交给 TextField。
    if ((event.position - down).distance > 1) {
      _longPress?.cancel();
      _longPress = null;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointerDown = false;
    _longPress?.cancel();
    _longPress = null;
    _downAt = null;
    if (_blockSelecting) {
      _stopEdgeScroll();
      return;
    }
    // 1.63.2：普通点击（聚焦、放光标、选字）不重建整棵块列表。
    // 以前每次抬指都 setState 清锚点，TextField 自己的 tap 会被打断，
    // 表现就是「第一次点光标不跟手，要再点一次」。
    _selAnchor = null;
    _selFocus = null;
    _stopEdgeScroll();
  }

  void _clearBlockSelection() {
    _stopEdgeScroll();
    if (_selAnchor == null && _selFocus == null && !_blockSelecting) {
      _downAt = null;
      return;
    }
    setState(() {
      _selAnchor = null;
      _selFocus = null;
      _blockSelecting = false;
      _downAt = null;
    });
  }

  List<int> get _selectedRange {
    final a = _selAnchor;
    final b = _selFocus;
    if (a == null || b == null) return const <int>[];
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    return [for (var i = lo; i <= hi; i++) i];
  }

  String _blockSource(_BlockEntry entry) {
    final block = entry.block;
    switch (block.kind) {
      case MdBlockKind.image:
        return '![[${block.imageName ?? ''}]]';
      case MdBlockKind.divider:
        return '---';
      default:
        return entry.controller.text;
    }
  }

  Widget _blockSelectionBar(ThemeData theme) {
    final count = _selectedRange.length;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Wrap(
          spacing: 2,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('已选 $count 段', style: theme.textTheme.labelMedium),
            ),
            IconButton(
              onPressed: () => _nudgeScroll(-1),
              tooltip: '向上滚一屏',
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: () => _nudgeScroll(1),
              tooltip: '向下滚一屏',
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            ),
            TextButton.icon(
              onPressed: _copySelected,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制'),
            ),
            TextButton.icon(
              onPressed: _cutSelected,
              icon: const Icon(Icons.content_cut, size: 16),
              label: const Text('剪切'),
            ),
            TextButton.icon(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除'),
            ),
            TextButton(
              onPressed: _clearBlockSelection,
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  void _copySelected() {
    final range = _selectedRange;
    if (range.isEmpty) return;
    final text = [for (final i in range) _blockSource(_entries[i])].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    // 1.63.1：复制后保留选区，方便接着剪切/对照；退出点是「取消」或点空白。
    _stopEdgeScroll();
    _showTip('已复制 ${range.length} 段');
  }

  void _cutSelected() {
    final range = _selectedRange;
    if (range.isEmpty) return;
    final lo = range.first;
    final hi = range.last;
    final text = [for (final i in range) _blockSource(_entries[i])].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    final removed = [for (final i in range) _entries[i]];
    setState(() {
      _entries.removeRange(lo, hi + 1);
      for (final entry in removed) {
        entry.dispose();
      }
      if (_entries.isEmpty) {
        _entries.add(_BlockEntry(MdBlock.emptyParagraph()));
      }
      _selAnchor = null;
      _selFocus = null;
      _blockSelecting = false;
      _serial++;
    });
    _stopEdgeScroll();
    _notify();
    _showTip('已剪切 ${range.length} 段');
  }

  void _deleteSelected() {
    final range = _selectedRange;
    if (range.isEmpty) return;
    final lo = range.first;
    final hi = range.last;
    final removed = [for (final i in range) _entries[i]];
    setState(() {
      _entries.removeRange(lo, hi + 1);
      for (final entry in removed) {
        entry.dispose();
      }
      if (_entries.isEmpty) {
        _entries.add(_BlockEntry(MdBlock.emptyParagraph()));
      }
      _selAnchor = null;
      _selFocus = null;
      _blockSelecting = false;
      _serial++;
    });
    _stopEdgeScroll();
    _notify();
    _showTip('已删除 ${range.length} 段');
  }

  /// 选择状态下没有手势也能滚：点一下按钮滚一屏，并把选区跟到屏幕中心那一行。
  void _nudgeScroll(int direction) {
    if (!_scroll.hasClients) return;
    final box = _listBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final max = _scroll.position.maxScrollExtent;
    final page = box.size.height * 0.8;
    final next = (_scroll.offset + direction * page).clamp(0.0, max);
    _scroll.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_blockSelecting) return;
      final rect = box.localToGlobal(Offset.zero);
      final row = _rowAt(rect + Offset(24, box.size.height / 2));
      if (row != null) setState(() => _selFocus = row);
    });
  }

  void _showTip(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(milliseconds: 900)),
    );
  }

  Widget _buildRow(BuildContext context, int index, ThemeData theme) {
    final entry = _entries[index];
    final block = entry.block;
    if (block.kind == MdBlockKind.divider) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            IconButton(
              tooltip: '删除分割线',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () {
                setState(() {
                  _entries.removeAt(index);
                  entry.dispose();
                });
                _notify();
              },
            ),
          ],
        ),
      );
    }
    if (block.kind == MdBlockKind.image) {
      return _imageRow(index, entry, theme);
    }

    final leading = _leading(block, index, theme);
    entry.controller.baseStyle = _styleFor(context, block.kind);
    return Padding(
      padding: EdgeInsets.only(bottom: block.kind == MdBlockKind.paragraph ? 6 : 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?leading,
          Expanded(
            child: Focus(
              // 1.63.3：边界退格/Delete 统一由 _onHardwareKey 处理。
              // 这里再处理一次会和它重复执行（分割线被删后文字又被并一次）。
              child: TextField(
                controller: entry.controller,
                focusNode: entry.focus,
                maxLines: null,
                textAlign: _textAlignFor(block.align),
                style: _styleFor(context, block.kind),
                cursorColor: theme.colorScheme.primary,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                ),
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onTap: () => _lastFocused = _entries.indexOf(entry),
                onChanged: (value) {
                  _lastFocused = _entries.indexOf(entry);
                  _onBlockTextChanged(entry, value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 1.60：连续的有序列表按 1、2、3… 显示，不再全部写成 1.。
  /// 1.63：空行不断列表——否则空一行后「3.」会变回「1.」。
  int _ordinal(int index) {
    var number = 1;
    for (var i = index - 1; i >= 0; i--) {
      final kind = _entries[i].block.kind;
      if (kind == MdBlockKind.blank) continue;
      if (kind != MdBlockKind.numbered) break;
      number++;
    }
    return number;
  }

  Widget? _leading(MdBlock block, int index, ThemeData theme) {
    switch (block.kind) {
      case MdBlockKind.todo:
        return Padding(
          padding: const EdgeInsets.only(top: 2, right: 6),
          child: Checkbox(
            value: block.checked,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) {
              setState(() => block.checked = value ?? false);
              _notify();
            },
          ),
        );
      case MdBlockKind.bullet:
        return const _Prefix(text: '•');
      case MdBlockKind.numbered:
        return _Prefix(text: '${_ordinal(index)}.');
      case MdBlockKind.quote:
        return Container(
          width: 3,
          height: 22,
          margin: const EdgeInsets.only(top: 6, right: 8),
          color: theme.colorScheme.primary.withValues(alpha: .5),
        );
      default:
        return null;
    }
  }

  Widget _imageRow(int index, _BlockEntry entry, ThemeData theme) {
    final name = entry.block.imageName ?? entry.block.text;
    final path = widget.assetPath(name);
    final file = path == null ? null : File(path);
    final exists = file != null && file.existsSync();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: exists
                  ? Image.file(file, fit: BoxFit.contain)
                  : Container(
                      padding: const EdgeInsets.all(12),
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Row(
                        children: [
                          const Icon(Icons.image_not_supported_outlined, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text('找不到素材：$name')),
                        ],
                      ),
                    ),
            ),
          ),
          IconButton(
            tooltip: '删除图片',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () {
              setState(() {
                _entries.removeAt(index);
                entry.dispose();
              });
              _notify();
            },
          ),
        ],
      ),
    );
  }

  void _setAlign(String value) {
    if (_entries.isEmpty) return;
    final index = _currentIndex();
    final block = _entries[index].block;
    setState(() {
      block.align = block.align == value ? '' : value;
    });
    _notify();
  }

  Widget _alignTool(String value, IconData icon, String tooltip) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: () => _setAlign(value),
      icon: Icon(icon),
    );
  }

  Widget _highlightTool(ThemeData theme) {
    const colors = <String, String>{
      'y': '黄',
      'r': '红',
      'g': '绿',
      'b': '蓝',
      'p': '紫',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(Icons.border_color_outlined, '高亮', () => _toggleHighlight('y')),
        PopupMenuButton<String>(
          tooltip: '高亮颜色',
          padding: EdgeInsets.zero,
          iconSize: 18,
          onSelected: (code) {
            _toggleHighlight(code);
          },
          itemBuilder: (context) => [
            for (final item in colors.entries)
              PopupMenuItem(
                value: item.key,
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: highlightColor(item.key),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(item.value),
                  ],
                ),
              ),
          ],
          icon: const Icon(Icons.arrow_drop_down),
        ),
      ],
    );
  }

  Widget _toolbar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _tool('H1', '大标题', () => _convert(MdBlockKind.heading1)),
            _tool('H2', '中标题', () => _convert(MdBlockKind.heading2)),
            _tool('H3', '小标题', () => _convert(MdBlockKind.heading3)),
            _tool('正文', '普通正文', () => _convert(MdBlockKind.paragraph)),
            const _ToolDivider(),
            _icon(Icons.format_bold, '加粗', () => _toggleWrap('**', '**')),
            _icon(Icons.format_italic, '斜体', () => _toggleWrap('*', '*')),
            _icon(Icons.format_strikethrough, '删除线', () => _toggleWrap('~~', '~~')),
            _icon(Icons.code, '行内代码', () => _toggleWrap('`', '`')),
            const _ToolDivider(),
            _icon(Icons.format_list_bulleted, '无序列表', () => _convert(MdBlockKind.bullet)),
            _icon(Icons.format_list_numbered, '有序列表', () => _convert(MdBlockKind.numbered)),
            _icon(Icons.check_box_outlined, '待办', () => _convert(MdBlockKind.todo)),
            _icon(Icons.format_quote, '引用', () => _convert(MdBlockKind.quote)),
            _icon(Icons.data_object, '代码块', () => _convert(MdBlockKind.code)),
            _icon(Icons.horizontal_rule, '分割线', _insertDivider),
            _icon(Icons.backspace_outlined, '删除当前行', deleteCurrentRow),
            const _ToolDivider(),
            _alignTool('left', Icons.format_align_left, '居左'),
            _alignTool('center', Icons.format_align_center, '居中'),
            _alignTool('right', Icons.format_align_right, '居右'),
            _highlightTool(theme),
            const _ToolDivider(),
            _icon(Icons.image_outlined, '插入图片', _pickImage),
            _icon(Icons.link, '插入链接/笔记引用', _pickLink),
          ],
        ),
      ),
    );
  }

  Widget _tool(String label, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: onTap,
      icon: Icon(icon),
    );
  }
}

/// 1.61：高亮底色。`y` 黄（默认）、`r` 红、`g` 绿、`b` 蓝、`p` 紫。
Color highlightColor(String? code) {
  // 1.63.3：改成半透明底色（约 35%），深色主题下不再「亮底白字」看不清。
  return switch (code) {
    'r' => const Color(0x59EF5350),
    'g' => const Color(0x594CAF50),
    'b' => const Color(0x5942A5F5),
    'p' => const Color(0x59AB47BC),
    _ => const Color(0x59FFEB3B),
  };
}

class _Prefix extends StatelessWidget {
  const _Prefix({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    // 1.63.1：与正文用同一行高、同一上边距，序号/圆点才和文字在同一条基线上。
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, height: 1.55),
      ),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

TextStyle _styleFor(BuildContext context, MdBlockKind kind) {
  final theme = Theme.of(context);
  final base = theme.textTheme.bodyMedium?.copyWith(height: 1.55) ??
      const TextStyle(fontSize: 15, height: 1.55);
  return switch (kind) {
    MdBlockKind.heading1 =>
      base.copyWith(fontSize: 22, fontWeight: FontWeight.w700, height: 1.3),
    MdBlockKind.heading2 =>
      base.copyWith(fontSize: 19, fontWeight: FontWeight.w700, height: 1.3),
    MdBlockKind.heading3 =>
      base.copyWith(fontSize: 17, fontWeight: FontWeight.w600, height: 1.35),
    MdBlockKind.quote => base.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    MdBlockKind.code => base.copyWith(
        fontFamily: 'monospace',
        fontSize: 13.5,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
    _ => base,
  };
}

/// 编辑时也带行内样式：`**粗**` 的星号隐藏、中间变粗。
class _RichController extends TextEditingController {
  _RichController({super.text});

  TextStyle baseStyle = const TextStyle();

  static final _inline = RegExp(
    r'(==\{[yrgbp]\}[^\n]*?==)|(==[^\n]*?==)|(\*\*[^\n*]+?\*\*)|(\*[^\n*]+?\*)|(~~[^\n~]+?~~)|(`[^`\n]+?`)|(\[\[[^\]\n]+\]\])|(\[[^\]\n]+\]\([^)\n]+\))',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 中文输入法在组字（拼音未上屏）时，带隐藏标记的富文本容易把候选框/光标
    // 放到错位置。组字期间退回纯文本，上屏后再上样式。
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return TextSpan(style: baseStyle, text: text);
    }
    final theme = Theme.of(context);
    return TextSpan(
      style: baseStyle,
      children: _children(text, theme, baseStyle),
    );
  }

  /// 1.63.1：递归解析，支持嵌套（粗体里套高亮、高亮里套斜体），
  /// 这样内层标记也会被隐藏，不会露出 `==` / `**`。
  List<InlineSpan> _children(String text, ThemeData theme, TextStyle? style) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: style),
        );
      }
      spans.add(_spanFor(match.group(0)!, theme, style));
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return spans;
  }

  TextSpan _spanFor(String raw, ThemeData theme, TextStyle? style) {
    if (raw.startsWith('==')) {
      final colored = raw.startsWith('=={');
      final code = colored ? raw.substring(3, 4) : 'y';
      final bodyStart = colored ? 5 : 2;
      final body = raw.substring(bodyStart, raw.length - 2);
      final bodyStyle = (style ?? const TextStyle())
          .copyWith(backgroundColor: highlightColor(code));
      return TextSpan(
        children: [
          TextSpan(text: raw.substring(0, bodyStart), style: _marker(theme)),
          ..._children(body, theme, bodyStyle),
          TextSpan(text: '==', style: _marker(theme)),
        ],
      );
    }
    if (raw.startsWith('**')) {
      final body = raw.substring(2, raw.length - 2);
      final bodyStyle =
          (style ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700);
      return TextSpan(
        children: [
          TextSpan(text: '**', style: _marker(theme)),
          ..._children(body, theme, bodyStyle),
          TextSpan(text: '**', style: _marker(theme)),
        ],
      );
    }
    if (raw.startsWith('~~')) {
      final body = raw.substring(2, raw.length - 2);
      final bodyStyle = (style ?? const TextStyle())
          .copyWith(decoration: TextDecoration.lineThrough);
      return TextSpan(
        children: [
          TextSpan(text: '~~', style: _marker(theme)),
          ..._children(body, theme, bodyStyle),
          TextSpan(text: '~~', style: _marker(theme)),
        ],
      );
    }
    if (raw.startsWith('`')) {
      return TextSpan(
        children: [
          TextSpan(text: '`', style: _marker(theme)),
          TextSpan(
            text: raw.substring(1, raw.length - 1),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          TextSpan(text: '`', style: _marker(theme)),
        ],
      );
    }
    if (raw.startsWith('[[')) {
      return TextSpan(
        children: [
          TextSpan(text: '[[', style: _marker(theme)),
          TextSpan(
            text: raw.substring(2, raw.length - 2),
            style: TextStyle(color: theme.colorScheme.primary),
          ),
          TextSpan(text: ']]', style: _marker(theme)),
        ],
      );
    }
    if (raw.startsWith('[')) {
      final close = raw.indexOf('](');
      return TextSpan(
        children: [
          TextSpan(text: '[', style: _marker(theme)),
          TextSpan(
            text: raw.substring(1, close),
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
          TextSpan(text: raw.substring(close), style: _marker(theme)),
        ],
      );
    }
    // 单个 *斜体*
    final body = raw.substring(1, raw.length - 1);
    final bodyStyle =
        (style ?? const TextStyle()).copyWith(fontStyle: FontStyle.italic);
    return TextSpan(
      children: [
        TextSpan(text: '*', style: _marker(theme)),
        ..._children(body, theme, bodyStyle),
        TextSpan(text: '*', style: _marker(theme)),
      ],
    );
  }

  /// 编辑时把 Markdown 标记符号隐藏掉：字号趋近 0 且透明，字符仍留在文本里，
  /// 保存的 Markdown 不变，光标位置也不会错位太多。
  TextStyle _marker(ThemeData theme) => const TextStyle(
        fontSize: 0.01,
        height: 0.01,
        letterSpacing: 0,
        color: Color(0x00000000),
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.normal,
        decoration: TextDecoration.none,
      );
}
