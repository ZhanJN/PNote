/// 笔记列表的本机显示偏好（1.59）。
///
/// 目前只有一项「列表显示笔记首行」。设置页写库后立刻更新这个全局值，
/// 笔记页监听它重扫，不需要重新读数据库——也避免在 widget 测试里
/// 因真 sqflite 而挂住（见移交说明 7.40）。
library;

import 'package:material_ui/material_ui.dart';

/// meta 键：`1` 开启，其它为关闭。
const String kNoteListPreviewKey = 'note_list_preview';

/// 当前是否在列表里显示笔记首行。
final ValueNotifier<bool> noteListPreview = ValueNotifier<bool>(false);

/// 1.64：编辑器内核。`legacy` = 现有块编辑器；`pe` = appflowy_editor。
const String kEditorKernelKey = 'editor_kernel';
const String kEditorKernelLegacy = 'legacy';
const String kEditorKernelPe = 'pe';

/// 当前使用哪套编辑器内核（全局，切页即时生效）。
final ValueNotifier<String> editorKernel = ValueNotifier<String>(
  kEditorKernelLegacy,
);
