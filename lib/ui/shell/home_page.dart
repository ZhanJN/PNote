import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/backup.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/sync_service.dart';
import 'package:pnote/ui/devices/devices_page.dart';
import 'package:pnote/ui/notes/notes_view.dart';
import 'package:pnote/ui/trash/trash_page.dart';
import 'package:pnote/ui/settings/settings_page.dart';
import 'package:pnote/ui/tasks/tasks_view.dart';

/// 构建期开关，只给"给用户截某一块的图"用，运行期零成本：
///   flutter build windows --release --dart-define=PNOTE_START=notes
///   flutter build windows --release --dart-define=PNOTE_START=settings
/// 不传时永远是待办（用户看到的正常行为）。
const String _kStartSection =
    String.fromEnvironment('PNOTE_START', defaultValue: 'tasks');

/// App 的外壳：顶栏（含功能栏）+ 内容区 + 底栏（同步条）。
///
/// 1.17 起 PNote 从「一个待办列表」变成「两个模块」：
///   顶栏下方是功能栏（待办 / 笔记），点它切换内容区；
///   底栏的「同步」按钮是全局的 —— 同步的永远是整个本地库。
///
/// 顶栏右侧：回收站两个页签都能进（1.45 起是「任务 / 笔记」两页签的统一回收站）；
/// 删除完成项 / 导出 / 导入仍只属于待办模块 —— 笔记是磁盘上的独立 Markdown
/// 文件，不进任务库，也不参与任务备份（1.41，见项目说明 8.12）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.dao, this.sync, this.notesStore});

  final TaskDao dao;

  /// 笔记库读写门面。留空用真实磁盘库；测试里换成假实现，
  /// 免得在 FakeAsync 里等真实文件 IO（见 7.40 / 7.45）。
  final NotesStore? notesStore;

  /// 同步服务。为空时（单测/降级）同步按钮保持禁用。
  final SyncService? sync;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final GlobalKey<TasksViewState> _tasksKey = GlobalKey<TasksViewState>();
  final GlobalKey<NotesViewState> _notesKey = GlobalKey<NotesViewState>();

  List<Peer> _peers = const [];
  int _taskCount = 0;
  int _noteCount = 0;
  bool _busy = false;
  bool _syncing = false;
  StreamSubscription<List<Peer>>? _peerSub;
  StreamSubscription<SyncApplied>? _appliedSub;

  @override
  void initState() {
    super.initState();
    if (_kStartSection == 'notes') _tabs.index = 1;
    if (_kStartSection == 'settings') {
      // 只为截图：等首帧画完再推设置页，否则 Navigator 还没挂好。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openSettings());
      });
    }
    if (_kStartSection == 'devices') {
      // 同样只为截图：直接落到"连接设备"二级页。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openDevices());
      });
    }
    _tabs.addListener(_onTabChanged);
    final sync = widget.sync;
    if (sync != null) {
      unawaited(sync.start());
      _peerSub = sync.peerChanges.listen((_) {
        if (mounted) setState(() => _peers = sync.peers);
      });
      _appliedSub = sync.applied.listen((applied) async {
        await _tasksKey.currentState?.reload();
        // 1.47 起笔记也走同一条同步通道，对端可能刚改过库里的文件。
        await _notesKey.currentState?.reload();
        _toast('「${applied.peerName}」推来了改动：${applied.stats}');
      });
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _appliedSub?.cancel();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() {}); // 换 tab 时刷新顶栏图标与底栏文案
    // 切到笔记时顺手重扫一遍库：用户可能在资源管理器里拖进了新文件。
    if (!_onTasks) unawaited(_notesKey.currentState?.reload() ?? Future<void>.value());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 打开回收站（1.45）：一个页面两个页签，从哪个模块进来就落在哪个页签上。
  Future<void> _openRecycleBin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TrashPage(
          dao: widget.dao,
          store: widget.notesStore ?? const NotesStore(),
          initialTab: _onTasks ? 0 : 1,
        ),
      ),
    );
    await _tasksKey.currentState?.reload();
    await _notesKey.currentState?.reload();
  }

  /// 打开设置页（1.18）。主题切换在页面内部完成，回来后不需要刷新数据。
  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SettingsPage(sync: widget.sync)),
    );
  }

  /// 打开"连接设备"页（1.19）。目前只有设置页里的入口会用到；
  /// 另外 `--dart-define=PNOTE_START=devices` 时由 initState 直接调用（截图用）。
  Future<void> _openDevices() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DevicesPage(dao: widget.dao, sync: widget.sync),
      ),
    );
  }

  /// 导出全部数据（含墓碑与永久删除记录）成一个 JSON 文件。
  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = await widget.dao.exportState(
        deviceName: widget.sync?.deviceName ?? '本机',
      );
      final json = encodeBundle(state);
      final path = await saveBundleToFile(json);
      if (path == null) {
        _toast('已取消导出');
      } else {
        _toast('已导出 ${state.tasks.length} 条到：$path');
      }
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入一个备份文件：走和同步完全相同的合并算法，幂等、不会冲掉新数据。
  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = await pickAndReadBundle();
      if (state == null) {
        _toast('已取消导入');
        return;
      }
      final stats = await widget.dao.importBundle(state);
      await _tasksKey.currentState?.reload();
      _toast(
        stats.isNoop ? '导入完成：没有发现新内容' : '导入完成：${stats.describe()}',
      );
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除所有完成项（1.36）：一次确认，全部软删除进回收站。
  ///
  /// 只动任务不动组（组的 done 恒为 0）；数量以点击那一刻的库为准，
  /// 提示里写清楚「可在回收站恢复」，避免误以为永久删除。
  Future<void> _deleteAllDone() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ids = await widget.dao.completedTaskIds();
      if (ids.isEmpty) {
        _toast('没有已完成的任务');
        return;
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除所有完成项？'),
          content: Text('共 ${ids.length} 项，会移入回收站，之后可在回收站恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await widget.dao.softDeleteMany(ids);
      await _tasksKey.currentState?.reload();
      _toast('已删除 ${ids.length} 项完成项，可在回收站恢复');
    } catch (e) {
      _toast('删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 手动同步：找出所有对端 → 逐个互换全部状态 → 合并落库 → 提示结果。
  /// 第一版只有这一个触发点（OUT-01：不做后台自动同步）。
  Future<void> _syncNow() async {
    final sync = widget.sync;
    if (sync == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      final batch = await sync.syncNow();
      await _tasksKey.currentState?.reload();
      await _notesKey.currentState?.reload();
      _toast(batch.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  bool get _onTasks => _tabs.index == 0;

  String _peerLabel() {
    final sync = widget.sync;
    if (sync == null) return '同步未启用';
    if (sync.startError != null) return '同步启动失败';
    final count = _peers.length;
    if (count == 0) {
      final others = sync.otherAccountPeers.length;
      return others > 0 ? '发现 $others 台其它账号' : '还没发现设备';
    }
    if (count == 1) return '发现 ${_peers.first.deviceName}';
    final names = _peers.map((p) => p.deviceName).toSet();
    if (names.length <= 3) return '发现 ${names.join('、')}';
    return '发现 $count 台设备';
  }

  String _syncHint() {
    final sync = widget.sync;
    if (sync == null) return '同步未启用';
    if (sync.startError != null) return sync.startError!;
    if (_peers.isEmpty) {
      final others = sync.otherAccountPeers.length;
      if (others > 0) {
        return '发现了 $others 台其它账号的设备；把两边的账号名改成一样才能同步';
      }
      return '按下后会在同一 Wi‑Fi 里找所有开着 PNote 的设备';
    }
    if (_peers.length == 1) {
      return '与 ${_peers.first.deviceName} 互换修改（${_peers.first.host}）';
    }
    return '与 ${_peers.length} 台设备逐个互换修改';
  }

  String _countLabel() {
    if (_onTasks) return '共 $_taskCount 条 · ${_peerLabel()}';
    return '笔记 $_noteCount 篇 · ${_peerLabel()}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PNote'),
        centerTitle: false,
        actions: [
          // 回收站两个页签都能进（1.45），进去自动落在当前模块那个页签。
          IconButton(
            tooltip: '回收站',
            onPressed: _busy ? null : _openRecycleBin,
            icon: const Icon(Icons.delete_outline),
          ),
          if (_onTasks)
            ...[
              IconButton(
                tooltip: '删除所有完成项',
                onPressed: _busy ? null : _deleteAllDone,
                icon: const Icon(Icons.cleaning_services_outlined),
              ),
              IconButton(
                tooltip: '导出备份',
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.upload_file_outlined),
              ),
              IconButton(
                tooltip: '导入备份',
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.download_outlined),
              ),
            ],
          // 齿轮一直在最右边，两个页签都能进设置（1.18）。
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.check_circle_outline), text: '待办'),
            Tab(icon: Icon(Icons.sticky_note_2_outlined), text: '笔记'),
          ],
        ),
      ),
      // 用 IndexedStack 而不是 TabBarView：两个模块的状态（输入框、滚动位置、
      // 已加载的列表）在切换时都保留，切回来不会重新读库、也不会闪一下加载圈。
      body: IndexedStack(
        index: _tabs.index,
        children: [
          TasksView(
            key: _tasksKey,
            dao: widget.dao,
            onCountChanged: (n) {
              if (mounted && n != _taskCount) setState(() => _taskCount = n);
            },
          ),
          NotesView(
            key: _notesKey,
            store: widget.notesStore ?? const NotesStore(),
            onCountChanged: (n) {
              if (mounted && n != _noteCount) setState(() => _noteCount = n);
            },
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Tooltip(
                message: _syncHint(),
                child: FilledButton.tonalIcon(
                  onPressed: (widget.sync == null || _busy || _syncing)
                      ? null
                      : _syncNow,
                  icon: _syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(_syncing ? '同步中…' : '同步'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _countLabel(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Text(
                widget.sync?.displayName ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
