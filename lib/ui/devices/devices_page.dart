/// 「连接设备」页（1.19）：把"我是谁、我在哪、对面有谁"摊开给用户看。
///
/// 为什么单独一页而不是塞进设置页：设置页是"改开关"的地方，这里是
/// "看状态"的地方，字段多且会变（设备会来会走），混在一起两边都不清爽。
/// 入口放在设置页的"关于"里，二级菜单的形式符合用户要求（m04681）。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/payload.dart';
import 'package:pnote/sync/sync_service.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.dao, this.sync});

  final TaskDao dao;
  final SyncService? sync;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<Peer> _peers = const [];
  StreamSubscription<List<Peer>>? _sub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _peers = widget.sync?.peers ?? const [];
    _sub = widget.sync?.peerChanges.listen((list) {
      if (mounted) setState(() => _peers = list);
    });
    // 「最后发现 12 秒前」要自己走字，否则界面停在打开那一刻。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sync = widget.sync;
    final deviceId = widget.dao.clock.deviceId;

    return Scaffold(
      appBar: AppBar(title: const Text('连接设备')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionTitle('本机'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('设备名称'),
                  subtitle: Text(sync?.deviceName ?? '本机'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: const Text('设备 ID'),
                  subtitle: SelectableText(deviceId),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.memory_outlined),
                  title: const Text('系统'),
                  subtitle: Text(_platformLine()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.router_outlined),
                  title: const Text('监听端口'),
                  subtitle: Text(_portLine(sync)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.swap_horiz_outlined),
                  title: const Text('同步协议'),
                  subtitle: Text('$kProto · 数据库 schema v$kSchemaVersion'),
                ),
              ],
            ),
          ),
          if (sync != null && sync.startError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                '同步服务没启动成功：${sync.startError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const Divider(),
          _SectionTitle('同一局域网内的其它设备（${_peers.length}）'),
          if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                sync == null
                    ? '同步未启用，看不到其它设备。'
                    : '还没发现其它设备。让另一台设备也打开 PNote、连同一个 Wi-Fi，'
                          '每台设备每秒都会广播一次自己。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < _peers.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _PeerTile(peer: _peers[i]),
                  ],
                ],
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '设备 ID 随安装生成，重装 App 会换一个新的；它只用于区分设备，'
              '不包含任何个人信息。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _platformLine() {
    if (Platform.isAndroid) return 'Android ${Platform.operatingSystemVersion}';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  String _portLine(SyncService? sync) {
    final syncPort = sync?.servicePort;
    final portText = syncPort == null ? '未启动' : 'WS $syncPort';
    return '发现 UDP $kDiscoveryPort · 同步 $portText';
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = peer.deviceId.length >= 8
        ? peer.deviceId.substring(0, 8)
        : peer.deviceId;
    return ListTile(
      leading: const Icon(Icons.devices_other_outlined),
      title: Text(peer.deviceName),
      subtitle: Text('$id · ${peer.host}:${peer.port}'),
      trailing: Text(
        _ago(peer.lastSeen),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 「最后听见」的相对时间。广播每 700 ms 一次、12 秒过期，
  /// 所以这里的数字基本就是"几秒前"。
  String _ago(DateTime seen) {
    final seconds = DateTime.now().difference(seen).inSeconds;
    if (seconds <= 1) return '刚刚';
    if (seconds < 60) return '$seconds 秒前';
    return '${(seconds / 60).floor()} 分钟前';
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
