// 临时验证脚本（用完可删）：扮演「第三台设备」，往对方推一条新任务，
// 用来在没有点击能力（HyperOS 禁 adb 注入）的情况下，验证手机端的
// 「接收 → 合并 → 落库 → 回发」整条链路是真的通的。
//
// 用法：
//   dart run tool/push_probe.dart <host> <port> [标题]
//
// 它不会改动本机数据库：状态是内存里现造的，HLC 从当前时间起步。
import 'dart:io';

import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/transport.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法：dart run tool/push_probe.dart <host> <port> [标题]');
    exit(64);
  }
  final host = args[0];
  final port = int.parse(args[1]);
  final title = args.length > 2 ? args[2] : '来自电脑的测试任务';

  const probeId = '00000000-0000-4000-8000-00000000beef';
  final clock = HlcClock(deviceId: probeId);
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final hlc = clock.send();

  final task = TaskState(
    id: const Uuid().v4(),
    createdAt: nowMs,
    fields: {
      TaskField.title: FieldValue(title, hlc),
      TaskField.done: FieldValue(0, hlc),
    },
  );
  final local = SyncState(
    deviceId: probeId,
    deviceName: 'push-probe',
    tasks: {task.id: task},
  );

  final peer = Peer(
    deviceId: 'unknown',
    deviceName: 'target',
    host: host,
    port: port,
    lastSeen: DateTime.now(),
  );

  stdout.writeln('拨号 ws://$host:$port/ ，推送 1 条任务「$title」…');
  final remote = await exchangeWithPeer(peer: peer, local: local);
  stdout.writeln('对端：deviceName=${remote.deviceName} 任务数=${remote.tasks.length}');
  final echoed = remote.tasks[task.id];
  if (echoed == null) {
    stderr.writeln('失败：对端回发的状态里没有这条任务，说明它没有接受。');
    exit(1);
  }
  stdout.writeln('成功：对端接受了这条任务，标题=${echoed.title} 完成=${echoed.done}');
}
