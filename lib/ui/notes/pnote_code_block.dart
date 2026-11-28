import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pnote/notes/pe_code_block.dart';
import 'package:pnote/notes/pnote_code_highlight.dart';

/// 1.65 第③项：编辑器里的代码块。
///
/// appflowy_editor 6.2.0 只留了 Markdown 的代码块编解码、没留界面组件，这里
/// 自己补一个：
/// - 只读展示，按语言着色（[highlightCode]），左上角标语言；
/// - 点一下弹出编辑框，改正文和语言后写回节点属性；
/// - 块级选择/删除走上游的 `BlockSelectionContainer`。
///
/// 为什么不做「块内直接打字」：上游的富文本块一按回车就拆成两个段落，多行
/// 代码会散架；等把回车绑到代码块上再说（记录在 ADR 里）。
class PnoteCodeBlockComponentBuilder extends BlockComponentBuilder {
  PnoteCodeBlockComponentBuilder({
    required this.editorState,
    super.configuration,
    this.editable = true,
  });

  final EditorState editorState;

  /// 只读笔记里不给「点开编辑」的入口。
  final bool editable;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return PnoteCodeBlockComponentWidget(
      key: node.key,
      node: node,
      editorState: editorState,
      editable: editable,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate => (node) => node.delta != null;
}

class PnoteCodeBlockComponentWidget extends BlockComponentStatefulWidget {
  const PnoteCodeBlockComponentWidget({
    super.key,
    required super.node,
    required this.editorState,
    this.editable = true,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  final EditorState editorState;
  final bool editable;

  @override
  State<PnoteCodeBlockComponentWidget> createState() =>
      _PnoteCodeBlockComponentWidgetState();
}

class _PnoteCodeBlockComponentWidgetState
    extends State<PnoteCodeBlockComponentWidget>
    with SelectableMixin, BlockComponentConfigurable {
  final GlobalKey _codeKey = GlobalKey(debugLabel: 'pnote_code_block');

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  static const TextStyle _codeStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Consolas', 'Courier New'],
    fontSize: 13,
    height: 1.55,
  );

  @override
  Widget build(BuildContext context) {
    final editorState = widget.editorState;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final language = pnoteCodeLanguage(node);
    final code = pnoteCodeText(node);
    final label = language.isEmpty ? '代码' : language.toUpperCase();

    Widget child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.editable
          ? () => _editCode(context, editorState)
          : null,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (widget.editable) ...[
                  Icon(Icons.edit_outlined, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    '编辑',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            if (code.trim().isEmpty)
              Text(
                '点一下写代码',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              )
            else
              Text.rich(
                TextSpan(
                  children: highlightCode(
                    code,
                    language,
                    style: _codeStyle.copyWith(color: scheme.onSurface),
                    colors: CodeHighlightColors(
                      keyword: scheme.primary,
                      string: scheme.tertiary,
                      comment: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      number: scheme.secondary,
                    ),
                  ),
                ),
                style: _codeStyle.copyWith(color: scheme.onSurface),
              ),
          ],
        ),
      ),
    );

    child = Padding(
      key: _codeKey,
      padding: padding,
      child: child,
    );

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      cursorColor: editorState.editorStyle.cursorColor,
      selectionColor: editorState.editorStyle.selectionColor,
      supportTypes: const [
        BlockSelectionType.block,
        BlockSelectionType.cursor,
        BlockSelectionType.selection,
      ],
      child: child,
    );

    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: child,
      );
    }

    return child;
  }

  Future<void> _editCode(BuildContext context, EditorState editorState) async {
    final result = await showDialog<_CodeEditResult>(
      context: context,
      builder: (dialogContext) => _EditCodeDialog(
        language: pnoteCodeLanguage(node),
        code: pnoteCodeText(node),
        codeStyle: _codeStyle,
      ),
    );
    if (result == null) {
      return;
    }
    final delta = Delta();
    if (result.code.isNotEmpty) {
      delta.insert(result.code);
    }
    final transaction = editorState.transaction
      ..updateNode(node, {
        PnoteCodeBlockKeys.delta: delta.toJson(),
        PnoteCodeBlockKeys.language: result.language,
      });
    await editorState.apply(transaction);
  }

  @override
  Position start() => Position(path: node.path, offset: 0);

  @override
  Position end() => Position(path: node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset start) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    return getRectsInSelection(Selection.invalid()).first;
  }

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) {
      return null;
    }
    return getRectsInSelection(
      Selection.collapsed(position),
      shiftWithBaseOffset: shiftWithBaseOffset,
    ).firstOrNull;
  }

  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) {
      return [];
    }
    final parentBox = context.findRenderObject();
    final codeBox = _codeKey.currentContext?.findRenderObject();
    if (parentBox is RenderBox && codeBox is RenderBox) {
      return [
        (shiftWithBaseOffset
                ? codeBox.localToGlobal(Offset.zero, ancestor: parentBox)
                : Offset.zero) &
            codeBox.size,
      ];
    }
    return [Offset.zero & _renderBox!.size];
  }

  @override
  Selection getSelectionInRange(Offset start, Offset end) => Selection.single(
        path: node.path,
        startOffset: 0,
        endOffset: 1,
      );

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      _renderBox!.localToGlobal(offset);

  @override
  TextDirection textDirection() => TextDirection.ltr;
}

class _CodeEditResult {
  const _CodeEditResult(this.language, this.code);

  final String language;
  final String code;
}

/// 编辑弹窗自己持有控制器，避免弹窗退场动画期间还在使用已 dispose 的控制器。
class _EditCodeDialog extends StatefulWidget {
  const _EditCodeDialog({
    required this.language,
    required this.code,
    required this.codeStyle,
  });

  final String language;
  final String code;
  final TextStyle codeStyle;

  @override
  State<_EditCodeDialog> createState() => _EditCodeDialogState();
}

class _EditCodeDialogState extends State<_EditCodeDialog> {
  late final TextEditingController _language =
      TextEditingController(text: widget.language);
  late final TextEditingController _code =
      TextEditingController(text: widget.code);

  @override
  void dispose() {
    _language.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('编辑代码块'),
      content: SizedBox(
        width: 520,
        height: 320,
        child: Column(
          children: [
            TextField(
              controller: _language,
              decoration: const InputDecoration(
                labelText: '语言',
                hintText: 'dart / python / sql …（可留空）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _code,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: widget.codeStyle.copyWith(color: scheme.onSurface),
                decoration: const InputDecoration(
                  hintText: '代码',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _CodeEditResult(_language.text.trim(), _code.text),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
