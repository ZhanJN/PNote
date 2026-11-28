import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/pe_code_block.dart';
import '../../notes/pe_markdown.dart';
import 'pnote_code_block.dart';

/// 外层页面持有的 PEditor 句柄：插入图片、回写 Markdown。
///
/// 编辑区本身用 `ValueKey('pe-…')` 控制重建，不能再挂第二个 Key，
/// 所以页面通过这个句柄而不是 GlobalKey 触达编辑器。
class PeEditorController {
  PEditorState? _state;

  bool get attached => _state != null;

  void _attach(PEditorState state) {
    _state = state;
  }

  void _detach(PEditorState state) {
    if (_state == state) {
      _state = null;
    }
  }

  /// 把已经导入笔记库的素材插到光标处；没有光标时追加到文末。
  Future<void> insertImage(String name) async {
    await _state?.insertImage(name);
  }

  /// 把 `[[笔记名]]` 插到光标处；没有光标时追加到文末。
  Future<void> insertNoteLink(String raw) async {
    await _state?.insertNoteLink(raw);
  }

  /// 在光标处插一个 2×2 空表格；没有光标时追加到文末。
  Future<void> insertTable() async {
    await _state?.insertTable();
  }

  /// 把编辑器里还没回写的输入转成 Markdown；没有编辑器时返回 null。
  String? flush() => _state?.flush();
}

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
    this.controller,
    this.onPickImage,
    this.assetPath,
    this.onPasteImage,
    this.onImportImageBytes,
    this.onDropImage,
    this.onPickLink,
    this.onOpenNote,
  });

  final String initialText;
  final ValueChanged<String> onChanged;
  final bool readOnly;
  final bool autoFocus;

  /// 外层页面的句柄（插入图片、flush）。
  final PeEditorController? controller;

  /// 选图并导入笔记库，返回素材名；为空表示这个内核不收图片。
  final Future<String?> Function()? onPickImage;

  /// 素材名 → 磁盘绝对路径，渲染 `![[素材名]]` 时用。
  final String? Function(String name)? assetPath;

  /// 1.65：读系统剪贴板里的图片（png 字节）；没有图片返回 null。
  final Future<Uint8List?> Function()? onPasteImage;

  /// 1.65：把图片字节存进笔记库，返回素材名。
  final Future<String?> Function(Uint8List bytes, String? fileName)?
  onImportImageBytes;

  /// 1.65：把拖进窗口的文件存进笔记库，返回素材名。
  final Future<String?> Function(String path)? onDropImage;

  /// 1.65：选一篇笔记，返回 `[[名字]]` 片段（插入笔记引用用）。
  final Future<String?> Function()? onPickLink;

  /// 1.65：点 `[[名字]]` 时打开那篇笔记（参数是 `[[名字]]` 原串）。
  final void Function(String raw)? onOpenNote;

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

  /// 1.65：`[[名字]]` 的点击识别器，每次重建前统一释放（和预览页一个套路）。
  final List<TapGestureRecognizer> _linkRecognizers = <TapGestureRecognizer>[];

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  /// 1.65：`[[名字]]` 单击直接打开那篇笔记；上游默认单击只弹「编辑链接」。
  InlineSpan _decorateSpan(
    BuildContext context,
    Node node,
    int index,
    TextInsert text,
    TextSpan before,
    TextSpan after,
  ) {
    final href = text.attributes?[AppFlowyRichTextKeys.href];
    final open = widget.onOpenNote;
    if (href is String && open != null) {
      final raw = peNoteRefRaw(href);
      if (raw != null) {
        final recognizer = TapGestureRecognizer()..onTap = () => open(raw);
        _linkRecognizers.add(recognizer);
        return TextSpan(
          text: text.text,
          style: before.style,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        );
      }
    }
    return defaultTextSpanDecoratorForAttribute(
      context,
      node,
      index,
      text,
      before,
      after,
    );
  }

  @override
  void initState() {
    super.initState();
    _lastMarkdown = widget.initialText;
    _editorState = EditorState(
      document: peDocumentFromMarkdown(
        widget.initialText,
        resolveImage: widget.assetPath,
      ),
    );
    _sub = _editorState.transactionStream.listen((_) => _onTransaction());
    widget.controller?._attach(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _registerNewlineInterceptor(),
    );
  }

  /// 1.65.3：桌面回车兜底。
  /// 上游只把回车当「字符」处理（字符快捷键 `'\n'`），一旦这层 IME 通道掉线
  /// （切过预览/源码、点过工具条或弹窗），键盘上的 Enter 就完全没反应。
  /// 这里注册一个键盘服务拦截器：引擎发 `performAction(newline)` 时自己插入
  /// 新段落——上游对该动作的内置实现只打一行日志，等于什么都不做。
  AppFlowyKeyboardServiceInterceptor? _newlineInterceptor;

  void _registerNewlineInterceptor() {
    if (!mounted || _newlineInterceptor != null) {
      return;
    }
    final service = _editorState.service.keyboardService;
    if (service == null) {
      return;
    }
    final interceptor = _NewlineInterceptor(() => widget.readOnly);
    _newlineInterceptor = interceptor;
    service.registerInterceptor(interceptor);
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

  /// 1.65：把已导入的素材插到光标处，并在图片后留一个空段落。
  ///
  /// 素材地址在这里才换成绝对路径——磁盘上的 Markdown 仍然只有素材名。
  Future<void> insertImage(String name) async {
    if (widget.readOnly) {
      return;
    }
    final src = widget.assetPath?.call(name) ?? name;
    final image = imageNode(url: src);
    final paragraph = paragraphNode();
    final selection = _editorState.selection;
    final anchor = (selection == null || !selection.isCollapsed)
        ? null
        : _editorState.getNodeAtPath(selection.end.path);
    if (anchor == null) {
      final count = _editorState.document.root.children.length;
      final transaction = _editorState.transaction
        ..insertNode([count], image)
        ..insertNode([count + 1], paragraph);
      await _editorState.apply(transaction);
      return;
    }
    final transaction = _editorState.transaction;
    if (anchor.type == ParagraphBlockKeys.type &&
        (anchor.delta?.isEmpty ?? false)) {
      // 光标所在是空段落：图片顶替它，后面补一个新的空段落。
      transaction
        ..insertNode(anchor.path, image)
        ..deleteNode(anchor)
        ..insertNode(anchor.path.next, paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: anchor.path.next),
      );
      await _editorState.apply(transaction);
      return;
    }
    // 否则插在当前块后面，光标落到新补的空段落里。
    transaction
      ..insertNode(anchor.path.next, image)
      ..insertNode(anchor.path.next.next, paragraph);
    transaction.afterSelection = Selection.collapsed(
      Position(path: anchor.path.next.next),
    );
    await _editorState.apply(transaction);
  }

  /// 1.65：把 `[[笔记名]]` 插到光标处；带 `href` 属性，点了能打开那篇笔记。
  ///
  /// 显示的是不带方括号的笔记名（方括号只在磁盘上的 Markdown 里）。
  /// 没有光标（例如刚切换内核）时追加到文末，不丢用户已经选好的引用。
  Future<void> insertNoteLink(String raw) async {
    if (widget.readOnly) {
      return;
    }
    final text = peNoteRefBody(raw);
    if (text.isEmpty) {
      return;
    }
    final attributes = <String, Object>{
      AppFlowyRichTextKeys.href: peNoteRefHref(text),
    };
    final selection = _editorState.selection;
    final node = (selection == null || !selection.isCollapsed)
        ? null
        : _editorState.getNodeAtPath(selection.start.path);
    if (selection == null || node == null || node.delta == null) {
      final count = _editorState.document.root.children.length;
      final paragraph = paragraphNode(
        delta: Delta()..insert(text, attributes: attributes),
      );
      final transaction = _editorState.transaction
        ..insertNode([count], paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: [count], offset: text.length),
      );
      await _editorState.apply(transaction);
      return;
    }
    final plain = node.delta!.toPlainText();
    final start = selection.start.offset.clamp(0, plain.length);
    final end = selection.end.offset.clamp(0, plain.length);
    final transaction = _editorState.transaction;
    if (end > start) {
      transaction.deleteText(node, start, end - start);
    }
    transaction.insertText(node, start, text, attributes: attributes);
    transaction.afterSelection = Selection.collapsed(
      Position(path: selection.start.path, offset: start + text.length),
    );
    await _editorState.apply(transaction);
  }

  /// 1.65：在光标处插入一个空代码块，后面补一个空段落（方便继续写正文）。
  Future<void> insertCodeBlock() async {
    if (widget.readOnly) {
      return;
    }
    final code = pnoteCodeNode();
    final paragraph = paragraphNode();
    final selection = _editorState.selection;
    final anchor = (selection == null || !selection.isCollapsed)
        ? null
        : _editorState.getNodeAtPath(selection.end.path);
    if (anchor == null) {
      final count = _editorState.document.root.children.length;
      final transaction = _editorState.transaction
        ..insertNode([count], code)
        ..insertNode([count + 1], paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: [count + 1]),
      );
      await _editorState.apply(transaction);
      return;
    }
    final transaction = _editorState.transaction;
    final isEmptyParagraph = anchor.type == ParagraphBlockKeys.type &&
        (anchor.delta?.isEmpty ?? false);
    if (isEmptyParagraph) {
      transaction
        ..insertNode(anchor.path, code)
        ..deleteNode(anchor)
        ..insertNode(anchor.path.next, paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: anchor.path.next),
      );
      await _editorState.apply(transaction);
      return;
    }
    transaction
      ..insertNode(anchor.path.next, code)
      ..insertNode(anchor.path.next.next, paragraph);
    transaction.afterSelection = Selection.collapsed(
      Position(path: anchor.path.next.next),
    );
    await _editorState.apply(transaction);
  }

  /// 1.65：在光标处插入一个 2×2 的空表格，后面补一个空段落，光标落进左上角。
  Future<void> insertTable() async {
    if (widget.readOnly) {
      return;
    }
    final table = TableNode.fromList([
      ['', ''],
      ['', ''],
    ]).node;
    final paragraph = paragraphNode();
    final selection = _editorState.selection;
    final anchor = (selection == null || !selection.isCollapsed)
        ? null
        : _editorState.getNodeAtPath(selection.end.path);
    if (anchor == null) {
      final count = _editorState.document.root.children.length;
      final transaction = _editorState.transaction
        ..insertNode([count], table)
        ..insertNode([count + 1], paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: [count, 0, 0]),
      );
      await _editorState.apply(transaction);
      return;
    }
    final transaction = _editorState.transaction;
    final isEmptyParagraph = anchor.type == ParagraphBlockKeys.type &&
        (anchor.delta?.isEmpty ?? false);
    if (isEmptyParagraph) {
      transaction
        ..insertNode(anchor.path, table)
        ..deleteNode(anchor)
        ..insertNode(anchor.path.next, paragraph);
      transaction.afterSelection = Selection.collapsed(
        Position(path: [...anchor.path, 0, 0]),
      );
      await _editorState.apply(transaction);
      return;
    }
    transaction
      ..insertNode(anchor.path.next, table)
      ..insertNode(anchor.path.next.next, paragraph);
    transaction.afterSelection = Selection.collapsed(
      Position(path: [...anchor.path.next, 0, 0]),
    );
    await _editorState.apply(transaction);
  }

  /// 1.65：`/` 菜单里的「图片」原本是贴网络图片 URL，这里换成选本地素材。
  List<CharacterShortcutEvent>? _characterShortcuts(ThemeData theme) {
    if (widget.readOnly) {
      return null;
    }
    return [
      ...standardCharacterShortcutEvents.where(
        (event) => event.key != 'show the slash menu',
      ),
      customSlashCommand(
        _slashMenuItems(),
        style: theme.brightness == Brightness.dark
            ? SelectionMenuStyle.dark
            : SelectionMenuStyle.light,
      ),
    ];
  }

  List<SelectionMenuItem> _slashMenuItems() {
    final imageLabel = AppFlowyEditorL10n.current.image;
    final tableLabel = AppFlowyEditorL10n.current.table;
    return [
      for (final item in standardSelectionMenuItems)
        if (item.name == tableLabel)
          _tableMenuItem()
        else if (item.name != imageLabel || widget.onPickImage == null)
          item
        else
          SelectionMenuItem(
            getName: () => item.name,
            icon: item.icon,
            keywords: item.keywords,
            handler: (editorState, menuService, context) {
              unawaited(_pickAndInsertImage());
            },
          ),
      if (widget.onPickLink != null) _noteLinkMenuItem(),
      _codeBlockMenuItem(),
    ];
  }

  /// 1.65：`/` 菜单里的「表格」——插一个 2×2 空表，光标落进左上角格子。
  SelectionMenuItem _tableMenuItem() {
    return SelectionMenuItem(
      getName: () => '表格',
      icon: (editorState, onSelected, style) => Icon(
        Icons.table_view,
        size: 20,
        color: onSelected
            ? style.selectionMenuItemSelectedIconColor
            : style.selectionMenuItemIconColor,
      ),
      keywords: const ['表格', 'table', 'sheet', '|'],
      handler: (editorState, menuService, context) {
        unawaited(_insertTable());
      },
    );
  }

  Future<void> _insertTable() async {
    if (widget.readOnly) {
      return;
    }
    await insertTable();
  }

  /// 手机工具条上的「表格」按钮：光标在表格里就弹操作面板，否则插一张新表。
  MobileToolbarItem _tableMobileToolbarItem() {
    return MobileToolbarItem.action(
      itemIconBuilder: (context, editorState, service) => Icon(
        Icons.table_chart_outlined,
        size: 24,
        color: MobileToolbarTheme.of(context).iconColor,
      ),
      actionHandler: (context, editorState) {
        final inside = _tableUnderSelection(editorState.selection);
        if (inside != null) {
          unawaited(_showTableActions(inside));
        } else {
          unawaited(_insertTable());
        }
      },
    );
  }

  /// 光标所在的表格（不在表格里返回 null）。
  Node? _tableUnderSelection(Selection? selection) {
    if (selection == null) {
      return null;
    }
    final path = selection.start.path;
    if (path.length < 3) {
      return null;
    }
    final node = _editorState.document.nodeAtPath([path.first]);
    if (node == null || node.type != TableBlockKeys.type) {
      return null;
    }
    return node;
  }

  Future<void> _showTableActions(Node table) async {
    final selection = _editorState.selection;
    if (selection == null) {
      return;
    }
    final path = selection.start.path;
    final rowsLen = table.attributes[TableBlockKeys.rowsLen] as int? ?? 0;
    final colsLen = table.attributes[TableBlockKeys.colsLen] as int? ?? 0;
    final row = path[1].clamp(0, rowsLen <= 0 ? 0 : rowsLen - 1);
    final col = path[2].clamp(0, colsLen <= 0 ? 0 : colsLen - 1);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (sheetContext) {
        Widget item(String value, IconData icon, String label) {
          return ListTile(
            leading: Icon(icon, color: scheme.onSurfaceVariant),
            title: Text(label),
            onTap: () => Navigator.of(sheetContext).pop(value),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Text(
                      '表格操作',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '第 ${row + 1} 行 · 第 ${col + 1} 列',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              item('rowAdd', Icons.add_box_outlined, '下面加一行'),
              item('colAdd', Icons.add_box_outlined, '右边加一列'),
              if (rowsLen > 1)
                item('rowDel', Icons.indeterminate_check_box_outlined, '删掉这一行'),
              if (colsLen > 1)
                item('colDel', Icons.indeterminate_check_box_outlined, '删掉这一列'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'rowAdd':
        TableActions.add(table, row + 1, _editorState, TableDirection.row);
      case 'colAdd':
        TableActions.add(table, col + 1, _editorState, TableDirection.col);
      case 'rowDel':
        TableActions.delete(table, row, _editorState, TableDirection.row);
      case 'colDel':
        TableActions.delete(table, col, _editorState, TableDirection.col);
    }
  }

  /// 1.65：`/` 菜单里的「代码块」——插入一个空代码块，点它就能写代码。
  SelectionMenuItem _codeBlockMenuItem() {
    return SelectionMenuItem(
      getName: () => '代码块',
      icon: (editorState, onSelected, style) => Icon(
        Icons.code,
        size: 20,
        color: onSelected
            ? style.selectionMenuItemSelectedIconColor
            : style.selectionMenuItemIconColor,
      ),
      keywords: const ['代码', '代码块', 'code', 'fence', '```'],
      handler: (editorState, menuService, context) {
        unawaited(_insertCodeBlock());
      },
    );
  }

  Future<void> _insertCodeBlock() async {
    if (widget.readOnly) {
      return;
    }
    await insertCodeBlock();
  }

  /// 手机工具条上的「代码块」按钮（和上游的行内代码按钮区分开，用终端图标）。
  MobileToolbarItem _codeBlockMobileToolbarItem() {
    return MobileToolbarItem.action(
      itemIconBuilder: (context, editorState, service) => Icon(
        Icons.terminal,
        size: 24,
        color: MobileToolbarTheme.of(context).iconColor,
      ),
      actionHandler: (context, editorState) {
        unawaited(_insertCodeBlock());
      },
    );
  }

  /// 1.65：`/` 菜单里的「笔记引用」——选一篇笔记，插入 `[[名字]]`。
  SelectionMenuItem _noteLinkMenuItem() {
    return SelectionMenuItem(
      getName: () => '笔记引用',
      icon: (editorState, onSelected, style) => Icon(
        Icons.article_outlined,
        size: 20,
        color: onSelected
            ? style.selectionMenuItemSelectedIconColor
            : style.selectionMenuItemIconColor,
      ),
      keywords: const ['引用', '笔记', 'note', 'link', 'reference', 'ref'],
      handler: (editorState, menuService, context) {
        unawaited(_pickAndInsertNoteLink());
      },
    );
  }

  /// 手机工具条上的「笔记引用」按钮。
  MobileToolbarItem _noteLinkMobileToolbarItem() {
    return MobileToolbarItem.action(
      itemIconBuilder: (context, editorState, service) => Icon(
        Icons.article_outlined,
        size: 24,
        color: MobileToolbarTheme.of(context).iconColor,
      ),
      actionHandler: (context, editorState) {
        unawaited(_pickAndInsertNoteLink());
      },
    );
  }

  Future<void> _pickAndInsertNoteLink() async {
    final pick = widget.onPickLink;
    if (pick == null || widget.readOnly) {
      return;
    }
    final saved = _editorState.selection;
    final raw = await pick();
    if (raw == null || raw.trim().isEmpty || !mounted) {
      return;
    }
    // 选笔记期间编辑器可能丢焦点，回来先把光标放回去再插入。
    if (_editorState.selection == null && saved != null) {
      _editorState.updateSelectionWithReason(saved);
    }
    await insertNoteLink(raw);
  }

  /// 手机工具条上的插图按钮（appflowy 自带的图标集里没有图片图标）。
  MobileToolbarItem _imageMobileToolbarItem() {
    return MobileToolbarItem.action(
      itemIconBuilder: (context, editorState, service) => Icon(
        Icons.image_outlined,
        size: 24,
        color: MobileToolbarTheme.of(context).iconColor,
      ),
      actionHandler: (context, editorState) {
        unawaited(_pickAndInsertImage());
      },
    );
  }

  /// 1.65：图片块悬停时显示「替换 / 删除」，用的是 appflowy 的 menuBuilder；
  /// 代码块用自定义组件（上游 6.2.0 只有 Markdown 编解码，没有界面）。
  Map<String, BlockComponentBuilder> _blockBuilders() {
    final builders = <String, BlockComponentBuilder>{
      ...standardBlockComponentBuilderMap,
      PnoteCodeBlockKeys.type: PnoteCodeBlockComponentBuilder(
        editorState: _editorState,
        editable: !widget.readOnly,
      ),
    };
    if (widget.onPickImage != null && !widget.readOnly) {
      builders[ImageBlockKeys.type] = ImageBlockComponentBuilder(
        showMenu: true,
        menuBuilder: _buildImageMenu,
      );
    }
    return builders;
  }

  Widget _buildImageMenu(Node node, ImageBlockComponentWidgetState state) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 6,
      right: 6,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        elevation: 2,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _imageMenuButton(
              Icons.swap_horiz,
              '替换图片',
              scheme.onSurfaceVariant,
              () => unawaited(_replaceImage(node)),
            ),
            _imageMenuButton(
              Icons.delete_outline,
              '删除图片',
              scheme.onSurfaceVariant,
              () => unawaited(_deleteImage(node)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageMenuButton(
    IconData icon,
    String tooltip,
    Color color,
    VoidCallback onPressed,
  ) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: color,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }

  Future<void> _replaceImage(Node node) async {
    final pick = widget.onPickImage;
    if (pick == null || widget.readOnly) {
      return;
    }
    final name = await pick();
    if (!mounted || name == null || name.isEmpty) {
      return;
    }
    final src = widget.assetPath?.call(name) ?? name;
    final transaction = _editorState.transaction
      ..updateNode(node, {ImageBlockKeys.url: src});
    await _editorState.apply(transaction);
  }

  Future<void> _deleteImage(Node node) async {
    if (widget.readOnly) {
      return;
    }
    final transaction = _editorState.transaction..deleteNode(node);
    await _editorState.apply(transaction);
    if (!mounted) {
      return;
    }
    if (_editorState.document.root.children.isEmpty) {
      final restore = _editorState.transaction
        ..insertNode([0], paragraphNode());
      await _editorState.apply(restore);
    }
  }

  /// 选图 → 导入笔记库（外层页面做）→ 插到光标处。
  ///
  /// 选文件会弹系统对话框，回调里编辑器多半已经失去选区，所以先记住，
  /// 回来发现没有选区就还原。
  Future<void> _pickAndInsertImage() async {
    final pick = widget.onPickImage;
    if (pick == null || widget.readOnly) {
      return;
    }
    final savedSelection = _editorState.selection;
    final name = await pick();
    if (!mounted || name == null || name.isEmpty) {
      return;
    }
    if (_editorState.selection == null && savedSelection != null) {
      _editorState.selection = savedSelection;
    }
    await insertImage(name);
  }

  /// 1.65：Ctrl/Cmd+V —— 剪贴板里是图片就存进笔记库再插图，否则退回上游的文本粘贴。
  ///
  /// 不能靠外层 Shortcuts：上游把 `ctrl+v` 写进了 [standardCommandShortcutEvents]，
  /// 编辑器内的按键处理会先把它消费掉，外层永远收不到。
  CommandShortcutEvent _pasteWithImageCommand() {
    return CommandShortcutEvent(
      key: 'pnote paste the content with image',
      getDescription: () => AppFlowyEditorL10n.current.cmdPasteContent,
      command: 'ctrl+v',
      macOSCommand: 'cmd+v',
      handler: (editorState) {
        final read = widget.onPasteImage;
        final save = widget.onImportImageBytes;
        if (read == null || save == null) {
          return pasteCommand.handler(editorState);
        }
        unawaited(_pasteImage(editorState, read, save));
        return KeyEventResult.handled;
      },
    );
  }

  List<CommandShortcutEvent>? _commandShortcuts() {
    if (widget.readOnly) return null;
    if (widget.onPasteImage == null || widget.onImportImageBytes == null) {
      return standardCommandShortcutEvents;
    }
    return [
      for (final event in standardCommandShortcutEvents)
        if (event == pasteCommand) _pasteWithImageCommand() else event,
    ];
  }

  Future<void> _pasteImage(
    EditorState editorState,
    Future<Uint8List?> Function() read,
    Future<String?> Function(Uint8List bytes, String? fileName) save,
  ) async {
    Uint8List? bytes;
    try {
      bytes = await read();
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      pasteCommand.handler(editorState);
      return;
    }
    final savedSelection = editorState.selection;
    final name = await save(bytes, '粘贴图片.png');
    if (!mounted) {
      return;
    }
    if (name == null || name.isEmpty) {
      pasteCommand.handler(editorState);
      return;
    }
    if (editorState.selection == null && savedSelection != null) {
      editorState.selection = savedSelection;
    }
    await insertImage(name);
  }

  /// 1.65：从资源管理器拖进来的文件 → 存进笔记库 → 插到光标处。
  Future<void> _dropImage(String path) async {
    final drop = widget.onDropImage;
    if (drop == null || widget.readOnly) {
      return;
    }
    final savedSelection = _editorState.selection;
    final name = await drop(path);
    if (!mounted || name == null || name.isEmpty) {
      return;
    }
    if (_editorState.selection == null && savedSelection != null) {
      _editorState.selection = savedSelection;
    }
    await insertImage(name);
    if (mounted) {
      widget.onChanged(flush());
    }
  }

  /// 把拖拽接在编辑区外面（粘贴走 [AppFlowyEditor.commandShortcutEvents]）。
  Widget _withImageDrop(Widget child) {
    if (widget.onDropImage == null || widget.readOnly) {
      return child;
    }
    return DropTarget(
      onDragDone: (details) {
        if (details.files.isEmpty) {
          return;
        }
        final path = details.files.first.path;
        if (path.isNotEmpty) {
          unawaited(_dropImage(path));
        }
      },
      child: child,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    final interceptor = _newlineInterceptor;
    if (interceptor != null) {
      _editorState.service.keyboardService?.unregisterInterceptor(interceptor);
      _newlineInterceptor = null;
    }
    _disposeLinkRecognizers();
    widget.controller?._detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeLinkRecognizers();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    final style = _buildStyle(theme, mobile);
    final editor = AppFlowyEditor(
      editorState: _editorState,
      editorStyle: style,
      editable: !widget.readOnly,
      autoFocus: widget.autoFocus,
      characterShortcutEvents: _characterShortcuts(theme),
      commandShortcutEvents: _commandShortcuts(),
      blockComponentBuilders: _blockBuilders(),
    );
    // 图片块在没有 width 属性时按 `MediaQuery.size.width` 铺满，而编辑区两侧
    // 还有内边距——直接铺满会画到编辑区外面（手机上尤其明显，选中图片时的
    // 选框也会跟着跑出去）。这里把编辑区内部的 MediaQuery 宽度收窄到可用宽度。
    final horizontalPadding = mobile ? 32.0 : 48.0;
    final surface = _withImageDrop(
      ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final media = MediaQuery.of(context);
            final available = (constraints.maxWidth - horizontalPadding)
                .clamp(120.0, constraints.maxWidth);
            return MediaQuery(
              data: media.copyWith(
                size: Size(available, media.size.height),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: scheme.onSurface,
                  fontFamily: 'NotoSansSC',
                ),
                child: editor,
              ),
            );
          },
        ),
      ),
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
      if (widget.onPickImage != null) _imageMobileToolbarItem(),
      if (widget.onPickLink != null) _noteLinkMobileToolbarItem(),
      if (!widget.readOnly) _codeBlockMobileToolbarItem(),
      if (!widget.readOnly) _tableMobileToolbarItem(),
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
        textSpanDecorator: _decorateSpan,
      );
    }
    return EditorStyle.desktop(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.30),
      textStyleConfiguration: config,
      textSpanDecorator: _decorateSpan,
    );
  }
}

/// 回车兜底：引擎发 `performAction(newline)` 时插入新段落。
/// 上游对这个动作的内置实现只写日志，桌面端 Enter 掉线时会导致「打不出换行」。
class _NewlineInterceptor extends AppFlowyKeyboardServiceInterceptor {
  _NewlineInterceptor(this._isReadOnly);

  final bool Function() _isReadOnly;

  @override
  Future<bool> interceptPerformAction(
    TextInputAction action,
    EditorState editorState,
  ) async {
    if (action != TextInputAction.newline && action != TextInputAction.done) {
      return false;
    }
    if (_isReadOnly()) {
      return false;
    }
    final selection = editorState.selection;
    if (selection == null) {
      return false;
    }
    if (!selection.isCollapsed) {
      await editorState.deleteSelection(selection);
    }
    final current = editorState.selection;
    if (current == null || !current.isCollapsed) {
      return true;
    }
    await editorState.insertNewLine(position: current.start);
    return true;
  }
}
