import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/pe_markdown.dart';

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
      document: peDocumentFromMarkdown(
        widget.initialText,
        resolveImage: widget.assetPath,
      ),
    );
    _sub = _editorState.transactionStream.listen((_) => _onTransaction());
    widget.controller?._attach(this);
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

  /// 1.65：`/` 菜单里的「图片」原本是贴网络图片 URL，这里换成选本地素材。
  List<CharacterShortcutEvent>? _characterShortcuts(ThemeData theme) {
    if (widget.onPickImage == null) {
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
    return [
      for (final item in standardSelectionMenuItems)
        if (item.name != imageLabel)
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
    ];
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

  /// 1.65：图片块悬停时显示「替换 / 删除」，用的是 appflowy 的 menuBuilder。
  Map<String, BlockComponentBuilder> _blockBuilders() {
    if (widget.onPickImage == null || widget.readOnly) {
      return standardBlockComponentBuilderMap;
    }
    return {
      ...standardBlockComponentBuilderMap,
      ImageBlockKeys.type: ImageBlockComponentBuilder(
        showMenu: true,
        menuBuilder: _buildImageMenu,
      ),
    };
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
    if (widget.onPasteImage == null ||
        widget.onImportImageBytes == null ||
        widget.readOnly) {
      return null;
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
    widget.controller?._detach(this);
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
      characterShortcutEvents: _characterShortcuts(theme),
      commandShortcutEvents: _commandShortcuts(),
      blockComponentBuilders: _blockBuilders(),
    );
    final surface = _withImageDrop(
      ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurface, fontFamily: 'NotoSansSC'),
          child: editor,
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
