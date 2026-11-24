/// 待办列表的「手势层」：长按 → 授予菜单资格 → 拖拽 / 弹菜单（1.20）。
///
/// 这里只干手势与视觉反馈，**不碰数据库**：顺序提交和菜单动作都回调出去，
/// 由 [TasksView] 决定怎么落库（见 press_machine.dart 的时间线说明）。
///
/// 1.24 起列表吃的是扁平化后的 [NodeRow]（见 data/tree.dart）：
///   * 组行用 [GroupTile]，任务行用 [TaskTile]，组内的任务缩进 24 px；
///   * 组里「子组在上、任务在下」时，两段之间画一条细线（[NodeRow.sectionBreak]）；
///   * 拖拽只允许**同一级**重排：落点回调的是一个「插到谁前面」的 id，
///     跨组的落点由页面拒绝并提示用「移动到…」。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'package:pnote/data/tree.dart';
import 'package:pnote/ui/tasks/group_tile.dart';
import 'package:pnote/ui/common/press_machine.dart';
import 'package:pnote/ui/tasks/task_tile.dart';

class TaskListBody extends StatefulWidget {
  const TaskListBody({
    super.key,
    required this.rows,
    required this.onToggle,
    required this.onMenu,
    required this.onReorder,
    required this.onCollapse,
    this.removingId,
    this.selecting = false,
    this.selectedIds = const <String>{},
    this.onSelect,
    this.urgentGroups = const <String>{},
    this.now,
  });

  final List<NodeRow> rows;
  final ValueChanged<NodeRow> onToggle;
  final void Function(NodeRow row, Rect rect, Offset? at) onMenu;

  /// 拖拽落位：`(被拖的行, 插到哪一行前面)`；null = 落到同级末尾。
  final void Function(NodeRow row, String? beforeId) onReorder;

  /// 点组行 / 折叠箭头。
  final ValueChanged<NodeRow> onCollapse;

  /// 正在被删除的那一行（160 ms 淡出期间置位，由 TasksView 控制）。
  final String? removingId;

  /// 多选模式（1.29）：行首勾选框改为「选中」，长按/拖拽手势停用。
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<NodeRow>? onSelect;

  /// 折叠组里有「24 小时内」任务时，组行要亮小红点的 id 集合（1.31）。
  final Set<String> urgentGroups;

  /// 时间文案的基准时刻；null = DateTime.now()。
  final DateTime? now;

  @override
  State<TaskListBody> createState() => _TaskListBodyState();
}

class _TaskListBodyState extends State<TaskListBody>
    with SingleTickerProviderStateMixin {
  final PressMachine _machine = PressMachine();
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};

  Timer? _ticker;
  Offset _pointer = Offset.zero;

  NodeRow? _active;
  Rect _activeRect = Rect.zero;
  int _insertIndex = 0;

  OverlayEntry? _preview;

  /// 拖拽预览的**显示位置**：它不直接等于手指坐标，而是每帧向手指插值，
  /// 形成一点点「追赶延迟」（手册：跟手型要有阻尼，否则生硬机械）。
  Offset _previewOffset = Offset.zero;
  bool _scrollActive = false;

  /// 长按接管后的那一抬手不能再触发勾选（用户的 bug 1）。
  bool _suppressTap = false;

  /// 刚落位的行 id：短暂高亮一下，回答「它落到哪了」。
  String? _settleId;
  Timer? _settleTimer;

  /// 由 16 ms 的 ticker 累加出来的「按住时长」。
  /// 不用 Stopwatch / DateTime.now()：那两样在 Widget 测试的假时钟下不会前进，
  /// 长按永远授予不了资格（踩过）。累加的写法在真机和测试里行为一致。
  Duration _held = Duration.zero;

  /// 行的进出场动画（1.24 补丁）：折叠/展开、新建、删除时，行不再瞬间出现或
  /// 消失，而是用 180 ms 收缩/展开高度，列表不会「跳一下」。
  ///
  /// 做法：旧行离开时先变成「幽灵行」留在列表里（不再跟随新的 rows），
  /// 与新出现的行一起按同一个 0→1 的进度缩放高度；动画结束再丢弃幽灵。
  late final AnimationController _rowsAnim;
  List<NodeRow> _ghostOrder = const [];
  final Map<String, NodeRow> _ghosts = {};
  final Set<String> _entering = {};

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
  void didUpdateWidget(covariant TaskListBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldRows = oldWidget.rows;
    final newRows = widget.rows;
    if (oldRows.isEmpty) return;
    final oldIds = {for (final r in oldRows) r.id};
    final newIds = {for (final r in newRows) r.id};
    final added = newRows.where((r) => !oldIds.contains(r.id)).toList();
    final removed = oldRows.where((r) => !newIds.contains(r.id)).toList();
    // 只是重排或刷新（同一批 id）：不掺和。
    if (added.isEmpty && removed.isEmpty) return;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 一次性变化太大（如导入备份）时直接换掉，逐行收缩反而更乱。
    if (reduce || added.length + removed.length > 20) {
      _ghosts.clear();
      _entering.clear();
      return;
    }
    _ghostOrder = [...oldRows, ..._ghosts.values];
    for (final r in removed) {
      _ghosts[r.id] = r;
    }
    _entering
      ..clear()
      ..addAll(added.map((r) => r.id));
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

  /// 正在拖一个组时，把它自己的子孙藏起来：否则插入线会画进它肚子里。
  bool _hidden(NodeRow row) {
    final active = _active;
    if (active == null || !active.isGroup || active.id == row.id) return false;
    final ids = descendantIds(widget.rows.map((r) => r.node).toList(), active.id);
    return ids.contains(row.id);
  }

  List<NodeRow> get _displayRows =>
      widget.rows.where((r) => !_hidden(r)).toList(growable: false);

  // ------------------------------------------------------------- 指针

  void _onDown(PointerDownEvent event) {
    // 行的进出场动画期间不接受拖拽：这时的行高是临时缩放出来的，
    // 拿它算落点会错（动画只有 180 ms，等一下就好）。
    if (_rowsAnim.isAnimating) return;
    // 多选模式下整行点击只负责勾选，长按/拖拽一律不接管。
    if (widget.selecting) return;
    final rows = _displayRows;
    final index = _indexAt(event.position, rows);
    if (index < 0) return;
    if (!_machine.down(event.position, _held, scrollActive: _scrollActive)) {
      return;
    }
    setState(() {
      _active = rows[index];
      _activeRect = _rectOf(_active!) ?? Rect.zero;
      _insertIndex = index;
      _suppressTap = false; // 新的一次按压：先恢复点击能力
    });
    _pointer = event.position;
    _held = Duration.zero;
    _ticker?.cancel();
    // 16 ms 一跳：同时负责「静默期结束」与「授予资格」两个时间点。
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void _tick() {
    if (!_machine.isActive) return;
    _held += const Duration(milliseconds: 16);
    final granted = _machine.tick(_held);
    if (granted) {
      // 授予资格：轻震一次 + 抬起。注意**这里不弹菜单**（见交互稿）。
      // 同时把点击关掉：这一手势剩下的抬起不能再勾选任务 / 折叠组。
      HapticFeedback.selectionClick();
      _suppressTap = true;
    }
    if (_machine.phase == PressPhase.dragging) {
      _edgeScroll();
      _updateInsertIndex();
      // 预览位置向手指插值（0.35/帧 ≈ 100 ms 追赶），产生轻微阻尼感。
      _previewOffset = Offset.lerp(_previewOffset, _pointer, 0.35) ?? _pointer;
      _preview?.markNeedsBuild();
    }
    if (mounted) setState(() {});
  }

  void _onMove(PointerMoveEvent event) {
    if (!_machine.isActive) return;
    _pointer = event.position;
    final outcome = _machine.move(event.position);
    switch (outcome) {
      case PressMoveOutcome.abort:
        _cancelGesture();
      case PressMoveOutcome.drag:
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
    final row = _active;
    final rect = _activeRect;
    final outcome = _machine.release();
    _ticker?.cancel();
    _ticker = null;
    _removePreview();
    final rows = _displayRows;
    final index = _insertIndex.clamp(0, rows.length);
    String? beforeId;
    for (var i = index; i < rows.length; i++) {
      if (rows[i].id != row?.id) {
        beforeId = rows[i].id;
        break;
      }
    }
    setState(() {
      _active = null;
    });
    if (row == null) return;
    switch (outcome) {
      case PressReleaseOutcome.openMenu:
        // 长按抬手：菜单弹在手指抬起的位置（不再固定在行左端）。
        widget.onMenu(row, rect, event.position);
      case PressReleaseOutcome.drop:
        widget.onReorder(row, beforeId);
        _flashSettled(row.id);
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
    if (mounted) setState(() => _active = null);
  }

  /// 落位高亮：320 ms 后自动消失（一次性，不循环）。
  void _flashSettled(String id) {
    _settleTimer?.cancel();
    if (mounted) setState(() => _settleId = id);
    _settleTimer = Timer(const Duration(milliseconds: 320), () {
      if (mounted) setState(() => _settleId = null);
    });
  }

  // ------------------------------------------------------------- 拖拽视觉

  void _startDragPreview() {
    final row = _active;
    if (row == null) return;
    _previewOffset = _pointer;
    final overlay = Overlay.of(context);
    final scheme = Theme.of(context).colorScheme;
    final node = row.node;
    _preview = OverlayEntry(
      builder: (_) => Positioned(
        left: 12,
        right: 12,
        top: _previewOffset.dy - 28,
        child: IgnorePointer(
          // 跟手层绝不能拦截事件（手册：跟随层必须不拦截事件）。
          child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(12),
            color: scheme.surfaceContainerHigh,
            child: ListTile(
              title: Text(node.title),
              leading: node.isGroup
                  ? Icon(Icons.folder_rounded, color: groupColor(node.color))
                  : Checkbox(value: node.done, onChanged: null),
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

  /// 手指靠近列表上下边缘时自动滚动：不这样的话，把条目拖到看不见的地方就卡住了。
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

  /// 插入位置：从上往下找第一条「中心点在手指出之下」的行，插到它前面。
  /// 拖拽中的那一行不可能落到自己前面，跳过它。
  void _updateInsertIndex() {
    final active = _active;
    final rows = _displayRows;
    var index = rows.length;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.id == active?.id) continue;
      final rect = _rectOf(row);
      if (rect == null) continue;
      if (rect.center.dy > _pointer.dy) {
        index = i;
        break;
      }
    }
    _insertIndex = index;
  }

  Rect? _rectOf(NodeRow row) {
    final box = _rowKeys[row.id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  int _indexAt(Offset position, List<NodeRow> rows) {
    for (var i = 0; i < rows.length; i++) {
      final rect = _rectOf(rows[i]);
      if (rect != null && rect.contains(position)) return i;
    }
    return -1;
  }

  // ------------------------------------------------------------- 构建

  /// 把「新的 rows」和「正在消失的旧行」拼成一个渲染列表。
  ///
  /// 幽灵行插在它原来前面那一行之后（折叠 = 组行正下方），这样收缩时
  /// 子行是贴着组行收起来的，而不是从列表底部飞过来。
  List<_ListItem> _items() {
    final newRows = widget.rows;
    if (_ghosts.isEmpty) {
      return [
        for (final r in newRows)
          _ListItem.fresh(r, entering: _entering.contains(r.id)),
      ];
    }
    final newIds = {for (final r in newRows) r.id};
    final ghostsAfter = <String?, List<NodeRow>>{};
    for (final ghost in _ghosts.values) {
      final oldIndex = _ghostOrder.indexWhere((r) => r.id == ghost.id);
      String? anchor;
      for (var i = oldIndex - 1; i >= 0; i--) {
        final candidate = _ghostOrder[i];
        if (newIds.contains(candidate.id)) {
          anchor = candidate.id;
          break;
        }
      }
      (ghostsAfter[anchor] ??= <NodeRow>[]).add(ghost);
    }
    for (final list in ghostsAfter.values) {
      list.sort(
        (a, b) => _ghostOrder
            .indexWhere((r) => r.id == a.id)
            .compareTo(_ghostOrder.indexWhere((r) => r.id == b.id)),
      );
    }
    final items = <_ListItem>[];
    void emit(String? anchor) {
      for (final ghost in ghostsAfter[anchor] ?? const <NodeRow>[]) {
        items.add(_ListItem.ghost(ghost));
      }
    }

    emit(null);
    for (final row in newRows) {
      items.add(_ListItem.fresh(row, entering: _entering.contains(row.id)));
      emit(row.id);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dragging = _machine.phase == PressPhase.dragging;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final items = _items();
    final progress = Curves.easeOutCubic.transform(_rowsAnim.value);
    final rowIndex = <String, int>{
      for (var i = 0; i < widget.rows.length; i++) widget.rows[i].id: i,
    };
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) _scrollActive = true;
        if (n is ScrollEndNotification) _scrollActive = false;
        return false;
      },
      child: ListView.builder(
        key: _viewportKey,
        controller: _scroll,
        // 静默期一过就锁住滚动：这次按压已经明确是长按，不该再让列表跟着动。
        physics: _machine.shouldLockScroll
            ? const NeverScrollableScrollPhysics()
            : null,
        // 拖拽时多一格：让「拖到最后一行之后」也能画出插入高亮。
        itemCount: items.length + (dragging ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= items.length) {
            return _insertBar(theme, reduce);
          }
          return _buildItem(
            theme: theme,
            item: items[i],
            index: rowIndex[items[i].row.id],
            dragging: dragging,
            reduce: reduce,
            progress: progress,
          );
        },
      ),
    );
  }

  Widget _buildItem({
    required ThemeData theme,
    required _ListItem item,
    required int? index,
    required bool dragging,
    required bool reduce,
    required double progress,
  }) {
    final row = item.row;
    final isActive = row.id == _active?.id;
    final elevated =
        isActive && (_machine.phase == PressPhase.granted || dragging);

    final tile = row.isGroup
        ? GroupTile(
            row: row,
            elevated: elevated,
            fading: widget.removingId == row.id,
            interactive: !_suppressTap && !item.ghost,
            urgent: widget.urgentGroups.contains(row.id),
            selecting: widget.selecting,
            selected: widget.selectedIds.contains(row.id),
            onSelect: () => widget.onSelect?.call(row),
            onToggleCollapsed: () {
              if (_suppressTap || item.ghost) return;
              widget.onCollapse(row);
            },
            onMore: (rect, at) {
              if (!item.ghost) widget.onMenu(row, rect, at);
            },
          )
        : Padding(
            // 组里的任务缩进，视觉上明确「它属于上面那个组」。
            padding: EdgeInsets.only(left: row.depth >= 2 ? 24 : 0),
            child: TaskTile(
              task: row.node,
              elevated: elevated,
              settling: _settleId == row.id,
              fading: widget.removingId == row.id,
              interactive: !_suppressTap && !item.ghost,
              now: widget.now,
              selecting: widget.selecting,
              selected: widget.selectedIds.contains(row.id),
              onSelect: () => widget.onSelect?.call(row),
              // 双保险：即便 InkWell 的识别器没被拆掉，也不会真的勾选。
              onToggle: () {
                if (_suppressTap || item.ghost) return;
                widget.onToggle(row);
              },
              onMore: (rect, at) {
                if (!item.ghost) widget.onMenu(row, rect, at);
              },
            ),
          );

    final content = Column(
      // 幽灵行不能再用 GlobalKey：同一个 id 会同时存在两份。
      key: item.ghost ? ValueKey<String>('ghost-${row.id}') : _keyFor(row.id),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!item.ghost &&
            dragging &&
            index != null &&
            _insertIndex == index)
          _insertBar(theme, reduce),
        if (row.sectionBreak)
          Divider(
            height: 1,
            indent: 52,
            endIndent: 24,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        Opacity(
          opacity: dragging && isActive ? 0.35 : 1,
          child: item.ghost
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
        ),
        const Divider(height: 1),
      ],
    );

    // 幽灵行从 1 收到 0，新出现的行从 0 长到 1；其余时候原样返回。
    var scale = 1.0;
    if (item.ghost) {
      scale = 1 - progress;
    } else if (item.entering) {
      scale = progress;
    }
    if (scale >= 0.999) return content;
    final clamped = scale.clamp(0.0, 1.0);
    // 只裁高度，不套 Opacity：Android/Impeller 上逐行 saveLayer 在收放
    // 的第一帧会闪一下（电脑上 Skia 看不出）。裁切同样是「贴着组行收起」。
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: clamped,
        child: content,
      ),
    );
  }

  /// 插入位置的高亮：2 px 的线，出现时 90 ms 淡入（只动 opacity）。
  Widget _insertBar(ThemeData theme, bool reduce) {
    final bar = Container(
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.primary,
    );
    if (reduce) return bar;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(opacity: v, child: child),
      child: bar,
    );
  }
}

/// 渲染列表里的一行：新 rows 里的「正常行」，或正在收缩的「幽灵行」。
class _ListItem {
  _ListItem.fresh(this.row, {required this.entering}) : ghost = false;

  _ListItem.ghost(this.row)
      : ghost = true,
        entering = false;

  final NodeRow row;
  final bool ghost;

  /// 新出现的行：高度从 0 长到 1。
  final bool entering;
}
