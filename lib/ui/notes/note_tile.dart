/// 笔记列表里的一行（1.45 → 1.46 起和待办页同一套手感）。
///
/// 和待办页的 `TaskTile` 一个思路：无状态，所有动作回调给页面。
/// 长按**不在这里处理**：长按要区分「拖拽」和「弹菜单」，由列表层
/// （`NoteListBody`）统一识别，识别到以后再回调 [onMore]。
/// 这里只保留电脑右键（鼠标没有长按）和行尾 ⋮ 两个入口。
///
/// 抬起来的样子与待办行一致：轻微上浮 + 放大 1.5% + 阴影 + 圆角，
/// 落位后闪一下主题色，删除时淡出。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/notes_format.dart';
import 'package:pnote/notes/notes_model.dart';

class NoteTile extends StatelessWidget {
  const NoteTile({
    super.key,
    required this.note,
    required this.now,
    required this.onOpen,
    required this.onMore,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.elevated = false,
    this.settling = false,
    this.fading = false,
    this.interactive = true,
  });

  final NoteFile note;

  /// 相对时间的基准；测试传固定值，运行时用 `DateTime.now()`。
  final DateTime now;

  final VoidCallback onOpen;

  /// `(这一行的矩形, 触发点或 null)`。
  final void Function(Rect rect, Offset? at) onMore;

  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  /// 长按已授予资格 / 正在拖：行抬起。
  final bool elevated;

  /// 刚落地：闪一下主题色，回答「它落到哪了」。
  final bool settling;

  /// 正在被删除（160 ms 淡出）。
  final bool fading;

  /// false 时这一手势不再响应点击（长按抬手不能顺手把笔记打开）。
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final anim = reduce ? Duration.zero : const Duration(milliseconds: 160);

    final tile = ListTile(
      selected: selecting && selected,
      leading: selecting
          ? Checkbox(
              value: selected,
              onChanged: interactive ? (_) => onSelect?.call() : null,
            )
          : const Icon(Icons.article_outlined),
      title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatRelative(note.modified, now)} · ${formatSize(note.size)}',
      ),
      onTap: !interactive
          ? null
          : (selecting ? () => onSelect?.call() : onOpen),
      trailing: selecting
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多',
              onPressed:
                  interactive ? () => onMore(_tileRect(context), null) : null,
            ),
    );

    // 电脑右键：鼠标没有长按，这里单独接（带鼠标位置）。
    final withMenu = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: interactive && !selecting
          ? (details) => onMore(_tileRect(context), details.globalPosition)
          : null,
      child: Material(
        type: MaterialType.transparency,
        child: ListTileTheme.merge(
          selectedColor: scheme.primary,
          child: tile,
        ),
      ),
    );

    return AnimatedOpacity(
      opacity: fading ? 0 : 1,
      duration: anim,
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
                  : const <BoxShadow>[],
            ),
            child: withMenu,
          ),
        ),
      ),
    );
  }

  Rect _tileRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
