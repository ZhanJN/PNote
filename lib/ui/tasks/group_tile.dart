import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/tree.dart';

/// 分组的 8 种颜色（M12）。只存下标 0–7，换主题也不会串色。
const List<Color> kGroupPalette = [
  Color(0xFF5B8DEF),
  Color(0xFF4CAF50),
  Color(0xFFFFA726),
  Color(0xFFEF5350),
  Color(0xFFAB47BC),
  Color(0xFF26A69A),
  Color(0xFF8D6E63),
  Color(0xFF78909C),
];

Color groupColor(int index) =>
    kGroupPalette[index.clamp(0, kGroupPalette.length - 1)];

/// 列表里的「组」行：彩色文件夹 + 名字 + N 项未完成 + 折叠箭头 + ⋮。
///
/// 组不是容器，只是「视角」：它不显示完成/截止/优先级，也不参与打勾。
/// 折叠箭头是**本机偏好**，但 1.24 起这个偏好也参与同步（用户明确要求）。
class GroupTile extends StatelessWidget {
  const GroupTile({
    super.key,
    required this.row,
    required this.onToggleCollapsed,
    required this.onMore,
    this.elevated = false,
    this.fading = false,
    this.interactive = true,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.urgent = false,
  });

  final NodeRow row;
  final VoidCallback onToggleCollapsed;

  /// 打开菜单：`(这一行的矩形, 触发点或 null)`。
  final void Function(Rect rect, Offset? at) onMore;

  final bool elevated;
  final bool fading;
  final bool interactive;

  /// 多选模式（1.29）：整行点按改为「选中/取消选中」。
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  /// 折叠的组里若有「接下来 24 小时」的任务，组行亮一个小红点（1.31）。
  /// 展开后红点只出现在具体任务行，组行不再重复。
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final group = row.node;
    final color = groupColor(group.color);
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final anim = reduce ? Duration.zero : const Duration(milliseconds: 160);

    final body = Row(
      children: [
        const SizedBox(width: 12),
        if (selecting)
          Checkbox(
            value: selected,
            onChanged: (_) {
              if (interactive) onSelect?.call();
            },
          ),
        // 彩色文件夹：颜色是组的唯一装饰，不抢任务勾选框的位置。
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.folder_rounded, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                group.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (urgent) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: scheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    '${row.unfinished} 项未完成',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 折叠/展开：点整行也可以，这个箭头是显式入口。多选时藏起来，
        // 让位给勾选框（避免「点箭头却选中了」的歧义）。
        if (!selecting)
          IconButton(
            // 箭头本身转 90°，比直接换图标更像「同一个东西折叠起来」。
            icon: AnimatedRotation(
              turns: group.collapsed ? -0.25 : 0,
              duration: anim,
              curve: Curves.easeOutCubic,
              child: const Icon(Icons.expand_more),
            ),
            tooltip: group.collapsed ? '展开' : '折叠',
            onPressed: interactive ? onToggleCollapsed : null,
          ),
        if (!selecting)
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onPressed: () => onMore(_tileRect(context), null),
          ),
        const SizedBox(width: 4),
      ],
    );

    final tappable = InkWell(
      onTap: interactive
          ? (selecting ? () => onSelect?.call() : onToggleCollapsed)
          : null,
      child: body,
    );

    final withContextMenu = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: selecting
          ? null
          : (details) => onMore(_tileRect(context), details.globalPosition),
      child: tappable,
    );

    return AnimatedOpacity(
      opacity: fading ? 0 : 1,
      duration: anim,
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: anim,
        curve: Curves.easeOutCubic,
        // 组行比任务行略矮，但保持同一左缩进节奏。
        padding: EdgeInsets.only(
          top: 6,
          bottom: 6,
          left: row.depth >= 2 ? 20 : 0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(elevated ? 12 : 0),
          color: elevated ? scheme.surfaceContainerHigh : null,
          boxShadow: elevated
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : const [],
        ),
        child: Material(type: MaterialType.transparency, child: withContextMenu),
      ),
    );
  }

  Rect _tileRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
