import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/pe_markdown.dart';

/// PNote 的新编辑器内核：appflowy_editor（fork 在 third_party/）。
///
/// 只负责「Markdown 文本 ⇄ 文档」和编辑体验；保存仍由外层页面的
/// `_controller` 负责，切换前调用 [PEditorState.flush]。
class PEditor extends StatefulWidget {
  const PEditor({
    super.key,
    required this.initialText,
    required this.onChanged,
    this.readOnly = false,
    this.autoFocus = false,
  });

  final String initialText;
  final ValueChanged<String> onChanged;
  final bool readOnly;
  final bool autoFocus;

  @override
  State<PEditor> createState() => PEditorState();
}

class PEditorState extends State<PEditor> {
  late final EditorState _editorState;

  /// 测试用：拿到内部 EditorState（例如验证图片后自动补段落）。
  @visibleForTesting
  EditorState get editorState => _editorState;
  StreamSubscription<EditorTransactionValue>? _sub;
  Timer? _debounce;
  late String _lastMarkdown;
  bool _fixingTrailing = false;

  @override
  void initState() {
    super.initState();
    _lastMarkdown = widget.initialText;
    _editorState = EditorState(
      document: peDocumentFromMarkdown(widget.initialText),
    );
    _sub = _editorState.transactionStream.listen((_) => _onTransaction());
  }

  void _onTransaction() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _emit);
    _ensureParagraphAfterImage();
  }

  void _emit() {
    final markdown = peMarkdownFromDocument(_editorState.document);
    if (markdown == _lastMarkdown) {
      return;
    }
    _lastMarkdown = markdown;
    widget.onChanged(markdown);
  }

  /// 图片节点后面必须能继续输入：如果文档最后一个节点是图片，补一个空段落。
  Future<void> _ensureParagraphAfterImage() async {
    if (_fixingTrailing || widget.readOnly) {
      return;
    }
    // transactionStream 可能在文档真正落盘前触发，等一帧再检查。
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted || _fixingTrailing) {
      return;
    }
    final root = _editorState.document.root;
    if (root.children.isEmpty) {
      return;
    }
    final last = root.children.last;
    if (last.type != ImageBlockKeys.type) {
      return;
    }
    _fixingTrailing = true;
    try {
      final transaction = _editorState.transaction
        ..insertNode([root.children.length], paragraphNode());
      await _editorState.apply(transaction);
    } catch (_) {
      // 补段落失败不影响编辑，用户仍可点空白处或撤销。
    } finally {
      _fixingTrailing = false;
    }
  }

  /// 把当前文档转成 Markdown 并返回，同时同步给 onChanged。
  String flush() {
    _debounce?.cancel();
    final markdown = peMarkdownFromDocument(_editorState.document);
    if (markdown != _lastMarkdown) {
      _lastMarkdown = markdown;
      widget.onChanged(markdown);
    }
    return markdown;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    final style = _buildStyle(theme, mobile);
    final editor = AppFlowyEditor(
      editorState: _editorState,
      editorStyle: style,
      editable: !widget.readOnly,
      autoFocus: widget.autoFocus,
    );
    final surface = ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: editor,
    );

    if (!mobile) {
      return surface;
    }
    return Column(
      children: [
        Expanded(child: surface),
        if (!widget.readOnly)
          MobileToolbar(
            editorState: _editorState,
            toolbarItems: _mobileToolbarItems(),
            backgroundColor: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurfaceVariant,
            itemOutlineColor: scheme.outlineVariant,
            itemHighlightColor: scheme.primary,
            primaryColor: scheme.primary,
            onPrimaryColor: scheme.onPrimary,
            tabbarSelectedBackgroundColor: scheme.primary.withValues(
              alpha: 0.12,
            ),
            tabbarSelectedForegroundColor: scheme.onSurface,
            outlineColor: scheme.outlineVariant,
          ),
      ],
    );
  }

  List<MobileToolbarItem> _mobileToolbarItems() {
    return [
      blocksMobileToolbarItem,
      textDecorationMobileToolbarItem,
      headingMobileToolbarItem,
      listMobileToolbarItem,
      todoListMobileToolbarItem,
      quoteMobileToolbarItem,
      dividerMobileToolbarItem,
      codeMobileToolbarItem,
      linkMobileToolbarItem,
    ];
  }

  EditorStyle _buildStyle(ThemeData theme, bool mobile) {
    final scheme = theme.colorScheme;
    final on = scheme.onSurface;
    final config = TextStyleConfiguration(
      text: TextStyle(
        fontSize: 15,
        height: 1.6,
        color: on,
        fontFamily: 'NotoSansSC',
      ),
      bold: TextStyle(fontWeight: FontWeight.w700, color: on),
      italic: TextStyle(fontStyle: FontStyle.italic, color: on),
      underline: TextStyle(decoration: TextDecoration.underline, color: on),
      strikethrough: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: on,
      ),
      href: TextStyle(
        color: scheme.primary,
        decoration: TextDecoration.underline,
      ),
      code: TextStyle(
        fontFamily: 'Consolas',
        color: on,
        backgroundColor: on.withValues(alpha: 0.10),
      ),
      autoComplete: TextStyle(color: scheme.onSurfaceVariant),
      lineHeight: 1.6,
    );
    if (mobile) {
      return EditorStyle.mobile(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        cursorColor: scheme.primary,
        dragHandleColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.30),
        textStyleConfiguration: config,
      );
    }
    return EditorStyle.desktop(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.30),
      textStyleConfiguration: config,
    );
  }
}
