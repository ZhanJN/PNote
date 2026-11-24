/// 笔记列表的「手势层」（1.46）：和待办页同一套长按 → 授予资格 → 拖拽 / 弹菜单。
///
/// 为什么要单独一层：待办页的手感（静默 120 ms、320 ms 授予、抬起 + 阴影、
/// 跟手预览、插入线、落位闪烁、自动边缘滚动）都在 `TaskListBody` 里，
/// 笔记要「同样的动效」就得复用同一套时间线与同一种画法。
///
/// 与待办页的一处刻意差异：笔记列表是**按月分组**的，拖拽只在同一个月内生效
/// （跨月移动等于改分组，那需要另一套规则，先不做）。落点回调给页面的是
/// 「这个月的新顺序」，由页面写进库根的 `.order.json`。
///
/// 这里不碰磁盘：所有动作都回调出去，方便在 Widget 测试里跑。
library;

import 'dart:async';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/ui/notes/note_tile.dart';
import 'package:pnote/ui/common/press_machine.dart';

/// 列表里的一个月分组（`2026 年 11 月`）。
class NoteGroup {
  const NoteGroup({
    required this.key,
    required this.title,
    required this.notes,
  });

  /// `2026-11`，写进 `.order.json` 的键。
  final String key;

  /// 小标题文案。
  final String title;

  final List<NoteFile> notes;
}

class NoteListBody extends StatefulWidget {
  const NoteListBody({
    super.key,
    required this.groups,
    required this.now,
    required this.onOpen,
    required this.onMenu,
    required this.onReorder,
    this.selecting = false,
    this.selected = const <String>{},
    this.onSelect,
    this.showHeaders = true,
    this.draggable = true,
  });

  final List<NoteGroup> groups;

  /// 相对时间的基准。
  final DateTime now;

  final ValueChanged<NoteFile> onOpen;

  /// `(这一篇, 行矩形, 触发点或 null)`。
  final void Function(NoteFile note, Rect rect, Offset? at) onMenu;

  /// 拖拽落位：`(分组键, 这个组的新顺序)`，包含被拖的那一篇。
  final void Function(String groupKey, List<String> orderedIds) onReorder;

  final bool selecting;
  final Set<String> selected;
  final ValueChanged<NoteFile>? onSelect;

  /// 时间视图（1.48）是平铺的：不画「2026 年 11 月」那种小标题。
  final bool showHeaders;

  /// 时间视图按时间排，拖出来的顺序会被排序覆盖，所以那里禁拖拽（菜单照常）。
  final bool draggable;

  @override
  State<NoteListBody> createState() => _NoteListBodyState();
}

class _NoteListBodyState extends State<NoteListBody>
    with SingleTickerProviderStateMixin {
  final PressMachine _machine = PressMachine();
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};

  Timer? _ticker;
  Offset _pointer = Offset.zero;

  /// 正在被按住 / 拖动的笔记 id（relPath）。
  String? _activeId;
  Rect _activeRect = Rect.zero;

  /// 落点在「当前分组」里的插入位置（0..组内篇数）。
  int _insertIndex = 0;

  OverlayEntry? _preview;
  Offset _previewOffset = Offset.zero;
  bool _scrollActive = false;

  /// 长按接管后的那一抬手不能再触发点击（打开笔记）。
  bool _suppressTap = false;

  String? _settleId;
  Timer? _settleTimer;

  /// 16 ms ticker 累加出来的按住时长（不用 Stopwatch：假时钟下它不走）。
  Duration _held = Duration.zero;

  /// 行的进出场动画：新出现的高度 0→1，消失的先变幽灵再收到 0。
  late final AnimationController _rowsAnim;
  List<String> _ghostOrder = const <String>[];
  final Map<String, NoteFile> _ghosts = <String, NoteFile>{};
  final Set<String> _entering = <String>{};

  @override
  void initState() {
    super.initState();
    _rowsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _rowsAnim.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _ghosts.clear();
          _entering.clear();
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant NoteListBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selecting != oldWidget.selecting) {
      // 进出多选态时手势层可能没收到 up（多选态不挂 Listener），
      // 这里统一收尾，顺手把「抬手后压住的点击」放开。
      _suppressTap = false;
      _machine.reset();
      _ticker?.cancel();
      _ticker = null;
      _removePreview();
      _activeId = null;
    }
    final oldNotes = [
      for (final group in oldWidget.groups) ...group.notes,
    ];
    final newNotes = [
      for (final group in widget.groups) ...group.notes,
    ];
    if (oldNotes.isEmpty) return;
    final oldIds = {for (final note in oldNotes) note.relPath};
    final newIds = {for (final note in newNotes) note.relPath};
    final added = newNotes
        .where((note) => !oldIds.contains(note.relPath))
        .toList(growable: false);
    final removed = oldNotes
        .where((note) => !newIds.contains(note.relPath))
        .toList(growable: false);
    if (added.isEmpty && removed.isEmpty) return;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce || added.length + removed.length > 20) {
      _ghosts.clear();
      _entering.clear();
      return;
    }
    _ghostOrder = [
      for (final note in oldNotes) note.relPath,
      for (final note in _ghosts.values) note.relPath,
    ];
    for (final note in removed) {
      _ghosts[note.relPath] = note;
    }
    _entering
      ..clear()
      ..addAll(added.map((note) => note.relPath));
    _rowsAnim.forward(from: 0);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _settleTimer?.cancel();
    _preview?.remove();
    _rowsAnim.dispose();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) => _rowKeys.putIfAbsent(id, () => GlobalKey());

  NoteGroup? _groupOf(String id) {
    for (final group in widget.groups) {
      for (final note in group.notes) {
        if (note.relPath == id) return group;
      }
    }
    return null;
  }

  NoteFile? _noteById(String id) {
    for (final group in widget.groups) {
      for (final note in group.notes) {
        if (note.relPath == id) return note;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- 指针

  void _onDown(PointerDownEvent event) {
    // 行的进出场动画期间行高是临时缩放出来的，拿它算落点会错。
    if (_rowsAnim.isAnimating) return;
    // 多选模式下整行点击只负责勾选，长按 / 拖拽一律不接管。
    if (widget.selecting) return;
    final hit = _noteAt(event.position);
    if (hit == null) return;
    if (!_machine.down(event.position, _held, scrollActive: _scrollActive)) {
      return;
    }
    setState(() {
      _activeId = hit.relPath;
      _activeRect = _rectOf(hit.relPath) ?? Rect.zero;
      _insertIndex = _positionInGroup(hit);
      _suppressTap = false;
    });
    _pointer = event.position;
    _held = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void _tick() {
    if (!_machine.isActive) return;
    _held += const Duration(milliseconds: 16);
    final granted = _machine.tick(_held);
    if (granted) {
      // 授予资格：轻震 + 抬起。这里**不弹菜单**，留出改主意的时间。
      HapticFeedback.selectionClick();
      _suppressTap = true;
    }
    if (_machine.phase == PressPhase.dragging) {
      _edgeScroll();
      _updateInsertIndex();
      _previewOffset = Offset.lerp(_previewOffset, _pointer, 0.35) ?? _pointer;
      _preview?.markNeedsBuild();
    }
    if (mounted) setState(() {});
  }

  void _onMove(PointerMoveEvent event) {
    if (!_machine.isActive) return;
    _pointer = event.position;
    switch (_machine.move(event.position)) {
      case PressMoveOutcome.abort:
        _cancelGesture();
      case PressMoveOutcome.drag:
        // 时间视图禁拖拽：长按授予后只允许「抬起弹菜单」。
        if (!widget.draggable) break;
        _suppressTap = true;
        if (_preview == null) _startDragPreview();
        _updateInsertIndex();
        _edgeScroll();
        if (mounted) setState(() {});
      case PressMoveOutcome.ignored:
        break;
    }
  }

  void _onUp(PointerUpEvent event) {
    if (!_machine.isActive) return;
    final id = _activeId;
    final rect = _activeRect;
    final outcome = _machine.release();
    _ticker?.cancel();
    _ticker = null;
    _removePreview();
    if (mounted) setState(() => _activeId = null);
    if (id == null) return;
    final note = _noteById(id);
    if (note == null) return;
    switch (outcome) {
      case PressReleaseOutcome.openMenu:
        widget.onMenu(note, rect, event.position);
      case PressReleaseOutcome.drop:
        _commitDrop(note);
        _flashSettled(id);
      case PressReleaseOutcome.ignored:
        break;
    }
  }

  void _cancelGesture() {
    _machine.reset();
    _ticker?.cancel();
    _ticker = null;
    _suppressTap = false;
    _removePreview();
    if (mounted) setState(() => _activeId = null);
  }

  /// 提交同组内的新顺序。
  void _commitDrop(NoteFile note) {
    final group = _groupOf(note.relPath);
    if (group == null) return;
    final remaining = <String>[
      for (final item in group.notes)
        if (item.relPath != note.relPath) item.relPath,
    ];
    var at = 0;
    for (var i = 0; i < _insertIndex && i < group.notes.length; i++) {
      if (group.notes[i].relPath != note.relPath) at++;
    }
    remaining.insert(at.clamp(0, remaining.length), note.relPath);
    widget.onReorder(group.key, remaining);
  }

  void _flashSettled(String id) {
    _settleTimer?.cancel();
    if (mounted) setState(() => _settleId = id);
    _settleTimer = Timer(const Duration(milliseconds: 320), () {
      if (mounted) setState(() => _settleId = null);
    });
  }

  // ------------------------------------------------------------- 拖拽视觉

  void _startDragPreview() {
    final id = _activeId;
    final note = id == null ? null : _noteById(id);
    if (note == null) return;
    _previewOffset = _pointer;
    final overlay = Overlay.of(context);
    final scheme = Theme.of(context).colorScheme;
    _preview = OverlayEntry(
      builder: (_) => Positioned(
        left: 12,
        right: 12,
        top: _previewOffset.dy - 28,
        child: IgnorePointer(
          // 跟手层绝不能拦截事件。
          child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(12),
            color: scheme.surfaceContainerHigh,
            child: ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(
                note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_preview!);
  }

  void _removePreview() {
    _preview?.remove();
    _preview = null;
  }

  void _edgeScroll() {
    if (!_scroll.hasClients) return;
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    const edge = 64.0;
    const step = 12.0;
    if (_pointer.dy < top + edge) {
      _scroll.jumpTo(
        (_scroll.offset - step).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    } else if (_pointer.dy > bottom - edge) {
      _scroll.jumpTo(
        (_scroll.offset + step).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    }
  }

  /// 插入位置只在**当前分组**内算：从上往下找第一条中心点位于手指之下的行。
  void _updateInsertIndex() {
    final active = _activeId;
    final group = active == null ? null : _groupOf(active);
    if (group == null) return;
    var index = group.notes.length;
    for (var i = 0; i < group.notes.length; i++) {
      final note = group.notes[i];
      if (note.relPath == active) continue;
      final rect = _rectOf(note.relPath);
      if (rect == null) continue;
      if (rect.center.dy > _pointer.dy) {
        index = i;
        break;
      }
    }
    _insertIndex = index;
  }

  int _positionInGroup(NoteFile note) {
    final group = _groupOf(note.relPath);
    if (group == null) return 0;
    return group.notes
        .indexWhere((item) => item.relPath == note.relPath)
        .clamp(0, group.notes.length);
  }

  Rect? _rectOf(String id) {
    final box = _rowKeys[id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  NoteFile? _noteAt(Offset position) {
    for (final group in widget.groups) {
      for (final note in group.notes) {
        final rect = _rectOf(note.relPath);
        if (rect != null && rect.contains(position)) return note;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- 构建

  List<_Row> _rows() {
    final rows = <_Row>[];
    final present = <String>{
      for (final group in widget.groups)
        for (final note in group.notes) note.relPath,
    };
    final ghostsAfter = <String?, List<NoteFile>>{};
    for (final id in _ghostOrder) {
      final ghost = _ghosts[id];
      if (ghost == null) continue;
      String? anchor;
      for (var i = _ghostOrder.indexOf(id) - 1; i >= 0; i--) {
        if (present.contains(_ghostOrder[i])) {
          anchor = _ghostOrder[i];
          break;
        }
      }
      (ghostsAfter[anchor] ??= <NoteFile>[]).add(ghost);
    }
    void emit(String? anchor) {
      for (final note in ghostsAfter[anchor] ?? const <NoteFile>[]) {
        rows.add(_Row.ghost(note));
      }
    }

    emit(null);
    final dragging = _machine.phase == PressPhase.dragging;
    final activeGroup = _activeId == null ? null : _groupOf(_activeId!);
    for (final group in widget.groups) {
      if (widget.showHeaders && group.title.isNotEmpty) {
        rows.add(_Row.header(group.title));
      }
      for (var i = 0; i < group.notes.length; i++) {
        final note = group.notes[i];
        if (dragging &&
            widget.draggable &&
            activeGroup?.key == group.key &&
            _insertIndex == i &&
            note.relPath != _activeId) {
          rows.add(_Row.bar());
        }
        rows.add(_Row.fresh(
          note,
          entering: _entering.contains(note.relPath),
        ));
        emit(note.relPath);
      }
      if (dragging &&
          widget.draggable &&
          activeGroup?.key == group.key &&
          _insertIndex >= group.notes.length) {
        rows.add(_Row.bar());
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dragging = _machine.phase == PressPhase.dragging;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final rows = _rows();
    final progress = Curves.easeOutCubic.transform(_rowsAnim.value);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) _scrollActive = true;
        if (notification is ScrollEndNotification) _scrollActive = false;
        return false;
      },
      child: ListView.builder(
        key: _viewportKey,
        controller: _scroll,
        // 静默期一过就锁住滚动：这次按压已经明确是长按。
        physics: _machine.shouldLockScroll
            ? const NeverScrollableScrollPhysics()
            : null,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: rows.length,
        itemBuilder: (_, index) {
          final row = rows[index];
          if (row.bar) return _insertBar(theme, reduce);
          if (row.title != null) return _header(theme, row.title!);
          return _buildNote(
            theme: theme,
            row: row,
            dragging: dragging,
            reduce: reduce,
            progress: progress,
          );
        },
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildNote({
    required ThemeData theme,
    required _Row row,
    required bool dragging,
    required bool reduce,
    required double progress,
  }) {
    final note = row.note!;
    final isActive = note.relPath == _activeId;
    final elevated =
        isActive && (_machine.phase == PressPhase.granted || dragging);

    final tile = NoteTile(
      note: note,
      now: widget.now,
      selecting: widget.selecting,
      selected: widget.selected.contains(note.relPath),
      elevated: elevated,
      settling: _settleId == note.relPath,
      fading: false,
      // 和待办页一致：授予资格之后把 onTap 摘掉，抬起时不会再「顺手打开」；
      // 下一次按下的 _onDown 会把它恢复（见 _onDown 里的 _suppressTap = false）。
      interactive: !_suppressTap && !row.ghost,
      onSelect: () {
        if (_suppressTap || row.ghost) return;
        widget.onSelect?.call(note);
      },
      onOpen: () {
        if (_suppressTap || row.ghost) return;
        widget.onOpen(note);
      },
      onMore: (rect, at) {
        if (row.ghost) return;
        widget.onMenu(note, rect, at);
      },
    );

    final content = Opacity(
      opacity: dragging && isActive ? 0.35 : 1,
      child: row.ghost
          ? IgnorePointer(child: tile)
          : widget.selecting
              ? tile
              : Listener(
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: (_) => _cancelGesture(),
                  child: tile,
                ),
    );

    final keyed = Container(
      key: row.ghost
          ? ValueKey<String>('ghost-${note.relPath}')
          : _keyFor(note.relPath),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const Divider(height: 1),
        ],
      ),
    );

    var scale = 1.0;
    if (row.ghost) {
      scale = 1 - progress;
    } else if (row.entering) {
      scale = progress;
    }
    if (scale >= 0.999) return keyed;
    // 只裁高度、不套 Opacity：逐行 saveLayer 在 Impeller 上首帧会闪。
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: scale.clamp(0.0, 1.0),
        child: keyed,
      ),
    );
  }

  /// 插入位置的高亮：2 px 的线，出现时 90 ms 淡入。
  Widget _insertBar(ThemeData theme, bool reduce) {
    final bar = Container(
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.primary,
    );
    if (reduce) return bar;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      builder: (_, value, child) => Opacity(opacity: value, child: child),
      child: bar,
    );
  }
}

/// 渲染列表里的一行：分组小标题、正常笔记、正在收缩的幽灵、插入线。
class _Row {
  _Row.header(this.title)
      : note = null,
        ghost = false,
        entering = false,
        bar = false;

  _Row.fresh(this.note, {required this.entering})
      : title = null,
        ghost = false,
        bar = false;

  _Row.ghost(this.note)
      : title = null,
        ghost = true,
        entering = false,
        bar = false;

  _Row.bar()
      : title = null,
        note = null,
        ghost = false,
        entering = false,
        bar = true;

  final String? title;
  final NoteFile? note;
  final bool ghost;
  final bool entering;
  final bool bar;
}
