/// 设置页（1.18 引入，1.19 增加"跟随系统"与"连接设备"二级页）。
///
/// 为什么单独开一页而不是塞进底部栏：设置是"偶尔来一次、看完就走"的东西，
/// 放在高频路径上（底栏）会挤掉同步按钮；齿轮放右上角是通用直觉。
library;

import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/sync/sync_service.dart';
import 'package:pnote/theme/theme_controller.dart';
import 'package:pnote/ui/devices/devices_page.dart';
import 'package:pnote/ui/reminders/reminder_section.dart';
import 'package:pnote/ui/settings/account_dialog.dart';
import 'package:pnote/ui/settings/notes_prefs.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.sync});

  /// 只用来给"连接设备"页展示设备名/端口，可为空（测试里就不传）。
  final SyncService? sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ThemeScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionTitle('外观'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            // Flutter 3.32 起 RadioListTile 的 groupValue/onChanged 被弃用，
            // 改由外层 RadioGroup 统一管选中值（flutter analyze 会盯着这条）。
            child: RadioGroup<ThemeMode>(
              groupValue: controller.mode,
              onChanged: (mode) {
                if (mode != null) controller.setMode(mode);
              },
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.light,
                    title: Text('白底黑字'),
                    secondary: Icon(Icons.light_mode_outlined),
                  ),
                  Divider(height: 1),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.dark,
                    title: Text('黑底白字'),
                    secondary: Icon(Icons.dark_mode_outlined),
                  ),
                  Divider(height: 1),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.system,
                    title: Text('跟随系统主题颜色'),
                    secondary: Icon(Icons.brightness_auto_outlined),
                  ),
                ],
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            // 1.22：「减少动效」放在这里，而不是只依赖系统无障碍开关 ——
            // 系统那个开关在 HyperOS 上不一定找得到（用户反馈过）。
            child: SwitchListTile(
              secondary: const Icon(Icons.motion_photos_off_outlined),
              title: const Text('减少动效'),
              subtitle: const Text('关掉抬起、淡出、拖拽追赶等装饰动画，功能不变'),
              value: controller.reduceMotion,
              onChanged: (v) => controller.setReduceMotion(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '主题与动效只保存在这台设备上，不会同步到其它设备。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          // 1.51：账号 = 一个名字。只在本机保存（meta），不随同步走 ——
          // 否则两台设备会互相把对方的名字改成自己的。
          _SectionTitle('账号'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            child: _AccountTile(dao: controller.dao, sync: sync),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '只有账号名相同的设备才会互相同步（任务和笔记都算）。'
              '没有密码，换设备时把名字填成一样的就行。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          // 1.36：完成项清理。开关存 meta 表（只在本机生效、不随同步走），
          // 因为「要不要把完成项立刻收起来」是使用习惯，不是待办内容。
          _SectionTitle('任务'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            child: _AutoDeleteDoneTile(dao: controller.dao),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '开启后，勾掉的任务会立刻移入回收站，并给一次「撤销」的机会。'
              '这个开关只保存在本机。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          // 1.37：提醒只做手机端；桌面端这个组件直接返回空，不会多出一节。
          ReminderSection(dao: controller.dao),
          if (ReminderSection.supported) const Divider(),
          // 1.41：笔记库就一个普通文件夹，摆在这里方便用户自己去翻、去备份。
          const Divider(),
          _SectionTitle('笔记'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const _NotesLibraryTile(),
                const Divider(height: 1),
                _NoteListPreviewTile(dao: controller.dao),
                const Divider(height: 1),
                _EditorKernelTile(dao: controller.dao),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '每篇笔记都是笔记库里的一个 .md 文件，素材放在同名 .assets 目录里。'
              '整个文件夹拷到别处就能带走，不需要 PNote。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          _SectionTitle('关于'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('PNote'),
            subtitle: const Text('纯局域网同步的待办与笔记 · v1.64.2 (16402)'),
          ),
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('连接设备'),
            subtitle: const Text('本机信息、端口、局域网内已发现的设备'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      DevicesPage(dao: controller.dao, sync: sync),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 「完成后自动移入回收站」开关（1.36）。
///
/// 设置存在 meta 表（键 auto_delete_done），与主题一样是本机偏好，不参与同步。
/// 初值异步读库；读到之前先禁用，避免用户点下去又被回写覆盖。
class _AutoDeleteDoneTile extends StatefulWidget {
  const _AutoDeleteDoneTile({required this.dao});

  final TaskDao dao;

  @override
  State<_AutoDeleteDoneTile> createState() => _AutoDeleteDoneTileState();
}

class _AutoDeleteDoneTileState extends State<_AutoDeleteDoneTile> {
  bool? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await widget.dao.readSetting('auto_delete_done');
    if (!mounted) return;
    setState(() => _value = raw == '1');
  }

  Future<void> _set(bool value) async {
    setState(() => _value = value);
    await widget.dao.writeSetting('auto_delete_done', value ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.cleaning_services_outlined),
      title: const Text('完成后自动移入回收站'),
      subtitle: const Text('勾掉就收起，可在回收站恢复'),
      value: _value ?? false,
      onChanged: _value == null ? null : _set,
    );
  }
}

/// 「列表显示笔记首行」（1.59）。
///
/// 开启后笔记列表在时间/大小那一行下面再显示标题后的第一段文字。
/// 键 note_list_preview，本机偏好、不参与同步。
class _NoteListPreviewTile extends StatefulWidget {
  const _NoteListPreviewTile({required this.dao});

  final TaskDao dao;

  @override
  State<_NoteListPreviewTile> createState() => _NoteListPreviewTileState();
}

class _NoteListPreviewTileState extends State<_NoteListPreviewTile> {
  bool? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await widget.dao.readSetting(kNoteListPreviewKey);
    if (!mounted) return;
    final value = raw == '1';
    noteListPreview.value = value;
    setState(() => _value = value);
  }

  Future<void> _set(bool value) async {
    setState(() => _value = value);
    noteListPreview.value = value;
    await widget.dao.writeSetting(kNoteListPreviewKey, value ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.article_outlined),
      title: const Text('列表显示笔记首行'),
      subtitle: const Text('在标题下多显示一行正文摘要'),
      value: _value ?? false,
      onChanged: _value == null ? null : _set,
    );
  }
}

/// 「使用新编辑器内核（实验）」（1.64）。
///
/// 打开后笔记编辑页改用 appflowy_editor 的 PEditor；出问题可以随时关掉，
/// 已经保存的 Markdown 文件不受影响。键 editor_kernel，本机偏好、不同步。
class _EditorKernelTile extends StatefulWidget {
  const _EditorKernelTile({required this.dao});

  final TaskDao dao;

  @override
  State<_EditorKernelTile> createState() => _EditorKernelTileState();
}

class _EditorKernelTileState extends State<_EditorKernelTile> {
  bool? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await widget.dao.readSetting(kEditorKernelKey);
    if (!mounted) return;
    final value = raw == kEditorKernelPe;
    editorKernel.value = value ? kEditorKernelPe : kEditorKernelLegacy;
    setState(() => _value = value);
  }

  Future<void> _set(bool value) async {
    setState(() => _value = value);
    editorKernel.value = value ? kEditorKernelPe : kEditorKernelLegacy;
    await widget.dao.writeSetting(
      kEditorKernelKey,
      value ? kEditorKernelPe : kEditorKernelLegacy,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.auto_awesome_outlined),
      title: const Text('使用新编辑器内核（实验）'),
      subtitle: const Text('appflowy_editor；出问题可关掉，笔记文件不受影响'),
      value: _value ?? false,
      onChanged: _value == null ? null : _set,
    );
  }
}

/// 笔记库位置（1.41）：显示真实路径，点一下就到文件夹。
///
/// 电脑上直接用资源管理器打开；手机上私有目录不能直接浏览，
/// 于是退一步——把路径复制到剪贴板，并说明可以怎么取出来。
class _NotesLibraryTile extends StatefulWidget {
  const _NotesLibraryTile();

  @override
  State<_NotesLibraryTile> createState() => _NotesLibraryTileState();
}

class _NotesLibraryTileState extends State<_NotesLibraryTile> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await notesRoot();
      if (mounted) setState(() => _path = dir.path);
    } on Exception {
      if (mounted) setState(() => _path = '取不到笔记库位置');
    }
  }

  Future<void> _open() async {
    final path = _path;
    if (path == null) return;
    if (Platform.isWindows) {
      await Process.run('explorer', [path]);
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('路径已复制到剪贴板')));
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_open_outlined),
      title: const Text('笔记库位置'),
      subtitle: Text(
        _path ?? '读取中…',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _path == null ? null : _open,
    );
  }
}

/// 账号行（1.51）：显示当前名字，点开改。
///
/// 名字只存本机 meta；改完立刻让 [SyncService] 用新名字广播，
/// 不用重启 App —— 否则用户改完还要重开才生效，很容易以为没改成功。
class _AccountTile extends StatefulWidget {
  const _AccountTile({required this.dao, this.sync});

  final TaskDao dao;
  final SyncService? sync;

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  String? _name;
  String _lastPrivate = kDefaultAccount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await widget.dao.readSetting(kAccountKey);
    final private = await widget.dao.readSetting(kAccountPrivateKey);
    if (!mounted) return;
    setState(() {
      _name = normalizeAccount(raw ?? kDefaultAccount);
      _lastPrivate = normalizeAccount(private ?? kDefaultAccount);
    });
  }

  Future<void> _edit() async {
    final current = _name;
    if (current == null) return;
    final next = await showAccountDialog(
      context,
      current: current,
      lastPrivate: _lastPrivate,
    );
    if (next == null || next == current) return;
    // 切到「公开同步」时把当前名字记成私有名；切回私有名时更新记忆。
    final lastPrivate = isPublicAccount(next) ? current : next;
    await widget.dao.writeSetting(kAccountKey, next);
    await widget.dao.writeSetting(kAccountPrivateKey, lastPrivate);
    widget.sync?.setAccount(next);
    if (!mounted) return;
    setState(() {
      _name = next;
      _lastPrivate = lastPrivate;
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已切换到「$next」')));
  }

  @override
  Widget build(BuildContext context) {
    final name = _name;
    return ListTile(
      leading: const Icon(Icons.badge_outlined),
      title: const Text('账号'),
      subtitle: Text(name ?? '读取中…'),
      trailing: const Icon(Icons.chevron_right),
      onTap: name == null ? null : _edit,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
