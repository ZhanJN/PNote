import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/pe_markdown.dart';

/// 1.64 PEditor 地基：用 appflowy_editor 内核替代原块编辑器。
///
/// 只负责「文本进、Markdown 出」这一层；图片、Markdown 源码模式、预览仍由
/// 外面的 note_editor_page 管。默认先挂在「实验内核」开关后面，验证稳定
/// 后再把开关默认值改过去。
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
  StreamSubscription<EditorTransactionValue>? _sub;
  Timer? _debounce;
  late String _lastMarkdown;

  /// 给外面（比如源码模式切换前）强制把当前文档刷成 Markdown。
  String flush() {
    final markdown = peMarkdownFromDocument(_editorState.document);
    _lastMarkdown = markdown;
    return markdown;
  }

  @override
  void initState() {
    super.initState();
    _editorState = EditorState(
      document: peDocumentFromMarkdown(widget.initialText),
    );
    _lastMarkdown = widget.initialText;
    _sub = _editorState.transactionStream.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 120), _emit);
    });
  }

  void _emit() {
    if (!mounted) return;
    final markdown = peMarkdownFromDocument(_editorState.document);
    if (markdown == _lastMarkdown) return;
    _lastMarkdown = markdown;
    widget.onChanged(markdown);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final style =
        width < 600 ? const EditorStyle.mobile() : const EditorStyle.desktop();
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111111),
        fontFamily: 'NotoSansSC',
      ),
      child: AppFlowyEditor(
        editorState: _editorState,
        editorStyle: style,
        editable: !widget.readOnly,
        autoFocus: widget.autoFocus,
        shrinkWrap: false,
      ),
    );
  }
}
