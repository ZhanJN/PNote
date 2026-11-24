import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/repeat.dart';

/// 列表里的一行。故意做成无状态的：所有动作都回调给页面，
/// 这样 UI 不持有业务逻辑，测试与排查都只看一处。
///
/// 1.20 起行尾只留一个「更多」按钮（⋮）：它是长按菜单之外的**第二入口**。
///
/// 1.21 起 [interactive] 为 false 时整行与复选框都不响应 —— 长按接管后
/// 抬手时不能再顺带把任务勾上。
///
/// 1.23 起：
///   * 抬起效果加大（位移约 5 px + 轻微放大 + 阴影），1.21 的 2 px 用户
///     反馈「没啥效果」；
///   * 支持**右键**（电脑）：`onSecondaryTapDown` 直接把菜单弹在鼠标位置。
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onMore,
    this.elevated = false,
    this.settling = false,
    this.fading = false,
    this.interactive = true,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.now,
  });

  final TaskState task;
  final VoidCallback onToggle;

  /// 打开这一行的菜单：`(这一行的矩形, 触发点或 null)`。
  /// 触发点为空表示不是指针触发的（⋮ 按钮），菜单自己找位置。
  final void Function(Rect rect, Offset? at) onMore;

  /// 长按「授予资格」或拖拽中：视觉上抬起 + 阴影加深。
  final bool elevated;

  /// 拖拽落位后的短暂高亮：让用户看清「它落到了这里」。
  final bool settling;

  /// 正在被删除：160 ms 淡出后再真正从列表里消失。
  final bool fading;

  /// 这一行是否还接受点击（长按判定接管后置 false）。
  final bool interactive;

  /// 多选模式（1.29）：勾选框变成「选中」而不是「完成」。
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  /// 时间文案的基准时刻；测试可以传固定值，运行时用 DateTime.now()。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = task.done;
    final current = now ?? DateTime.now();
    final dueLabel = done ? '' : formatDue(task, current);
    final urgent = !done && isUrgent(task, current);
    final overdue = !done && isOverdue(task, current);
    // 1.34：重复规则与时间挤在同一行小字里，比如「明天 · 每周」。
    // 完成之后仍显示规则，用户能看出这一条当初是怎么来的。
    final rule = parseRepeatRule(task.repeatRule);
    final repeatLabel = rule == null ? '' : describeRepeat(rule);
    final subtitle = [
      dueLabel,
      repeatLabel,
    ].where((s) => s.isNotEmpty).join(' · ');

    // 系统/设置里开了「减少动效」时，所有装饰性动画直接归零。
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final anim = reduce ? Duration.zero : const Duration(milliseconds: 160);

    final tile = ListTile(
      leading: Checkbox(
        value: selecting ? selected : done,
        // 不用 onChanged: null —— 那会把复选框画成禁用灰。
        onChanged: (_) {
          if (!interactive) return;
          if (selecting) {
            onSelect?.call();
          } else {
            onToggle();
          }
        },
      ),
      title: Text(
        task.title,
        style: done && !selecting
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: scheme.outline,
              )
            : null,
      ),
      // 时间行（1.31）：接下来 24 小时内亮红点；逾期用红字（1.38 用户要求更明显）。
      subtitle: subtitle.isEmpty
          ? null
          : Row(
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
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: overdue ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      trailing: selecting
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多',
              onPressed: () => onMore(_tileRect(context), null),
            ),
      // onTap 为 null 时 ListTile 不建 InkWell 的点击识别，
      // 长按抬手时就不会再触发一次 onToggle。
      onTap: interactive
          ? (selecting ? () => onSelect?.call() : onToggle)
          : null,
    );

    // 右键：电脑上最自然的开菜单方式（用户要求「pc的菜单触发绑定右键」）。
    // 用 GestureDetector 而不是 Listener，是为了只在真的「右键按下」时触发，
    // 不和长按 / 拖拽的指针监听抢事件。多选时机不再弹菜单。
    final withContextMenu = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: selecting
          ? null
          : (details) => onMore(_tileRect(context), details.globalPosition),
      child: tile,
    );

    // 抬起：位移约 5 px（-0.09 × 行高）+ 放大 1.5% + 阴影 + 圆角底色。
    // 全部只影响绘制，不触发布局。
    return AnimatedOpacity(
      opacity: fading ? 0 : 1,
      duration: reduce ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: elevated ? const Offset(0, -0.09) : Offset.zero,
        duration: anim,
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: elevated ? 1.015 : 1,
          duration: anim,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: anim,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(elevated ? 12 : 0),
              color: elevated
                  ? scheme.surfaceContainerHigh
                  : settling
                      ? scheme.primary.withValues(alpha: 0.10)
                      : Colors.transparent,
              boxShadow: elevated
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : const [],
            ),
            // Material 只提供水波纹画布，背景与圆角交给上面的容器。
            child: Material(type: MaterialType.transparency, child: withContextMenu),
          ),
        ),
      ),
    );
  }

  /// 这一行在屏幕上的位置：菜单要贴着它弹。
  Rect _tileRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
