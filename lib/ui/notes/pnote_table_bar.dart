import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

/// 1.65.6：手机上改表格太隐蔽（要先点单元格、再从底部工具条找「表格」按钮、
/// 再选弹窗项）。这里在表格**正下方**常驻一排按钮：加行 / 加列 / 删行 / 删列，
/// 只在编辑模式出现（只读、预览、源码模式都不出现）。
///
/// 做法是给上游 `TableBlockComponentBuilder` 套一层：原样渲染表格，再在下面
/// 追加一条操作栏。这样不改 fork 里的表格实现，也保留上游行的重排逻辑。
class PnoteTableBlockComponentBuilder extends TableBlockComponentBuilder {
  PnoteTableBlockComponentBuilder({
    required this.editorState,
    super.configuration,
    super.tableStyle,
    super.menuBuilder,
  });

  final EditorState editorState;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final tableWidget = super.build(blockComponentContext);
    final node = blockComponentContext.node;
    return _PnoteTableBlockWidget(
      node: node,
      configuration: configuration,
      tableWidget: tableWidget,
      bar: _PnoteTableActionBar(node: node, editorState: editorState),
    );
  }
}

/// 极薄的容器：把上游表格 widget 和我们的操作栏竖着排。
class _PnoteTableBlockWidget extends BlockComponentStatelessWidget {
  const _PnoteTableBlockWidget({
    super.key,
    required super.node,
    required super.configuration,
    required this.tableWidget,
    required this.bar,
  });

  final BlockComponentWidget tableWidget;
  final Widget bar;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tableWidget,
        bar,
      ],
    );
  }
}

class _PnoteTableActionBar extends StatelessWidget {
  const _PnoteTableActionBar({
    required this.node,
    required this.editorState,
  });

  final Node node;
  final EditorState editorState;

  int get _rowsLen => (node.attributes[TableBlockKeys.rowsLen] as int?) ?? 1;

  int get _colsLen => (node.attributes[TableBlockKeys.colsLen] as int?) ?? 1;

  int get _row {
    final path = editorState.selection?.end.path;
    if (path != null && path.length >= 3 && path.first == node.path.first) {
      return path[1].clamp(0, _rowsLen - 1);
    }
    return _rowsLen - 1;
  }

  int get _col {
    final path = editorState.selection?.end.path;
    if (path != null && path.length >= 3 && path.first == node.path.first) {
      return path[2].clamp(0, _colsLen - 1);
    }
    return _colsLen - 1;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: editorState.selectionNotifier,
      builder: (context, _) {
        final row = _row;
        final col = _col;
        return Padding(
          padding: const EdgeInsets.only(left: 10, right: 10, top: 2, bottom: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _button(
                  context,
                  icon: Icons.add,
                  label: '加行',
                  tooltip: '在下方加一行',
                  onTap: () => TableActions.add(
                    node,
                    row + 1,
                    editorState,
                    TableDirection.row,
                  ),
                ),
                _button(
                  context,
                  icon: Icons.add,
                  label: '加列',
                  tooltip: '在右边加一列',
                  onTap: () => TableActions.add(
                    node,
                    col + 1,
                    editorState,
                    TableDirection.col,
                  ),
                ),
                if (_rowsLen > 1)
                  _button(
                    context,
                    icon: Icons.remove,
                    label: '删行',
                    tooltip: '删掉这一行',
                    onTap: () => TableActions.delete(
                      node,
                      row,
                      editorState,
                      TableDirection.row,
                    ),
                  ),
                if (_colsLen > 1)
                  _button(
                    context,
                    icon: Icons.remove,
                    label: '删列',
                    tooltip: '删掉这一列',
                    onTap: () => TableActions.delete(
                      node,
                      col,
                      editorState,
                      TableDirection.col,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _button(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
