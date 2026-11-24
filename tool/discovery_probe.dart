// 临时验证脚本（用完可删）：直接实例化 App 里真正的 LanDiscovery，
// 用来区分「发现类本身有 bug」还是「App 里的接线有问题」。
//
// 用法：dart run tool/discovery_probe.dart [监听秒数]
import 'dart:async';
import 'dart:io';

import 'package:pnote/sync/discovery.dart';

Future<void> main(List<String> args) async {
  final seconds = args.isEmpty ? 8 : int.parse(args[0]);
  final discovery = LanDiscovery(
    deviceId: '00000000-0000-4000-8000-00000000d15c',
    deviceName: '电脑',
    servicePort: 47822,
  );

  discovery.peerChanges.listen((peers) {
    stdout.writeln('peerChanges: ${peers.length} 台');
    for (final peer in peers) {
      stdout.writeln('  发现 ${peer.deviceName} @ ${peer.host}:${peer.port}');
    }
  });

  try {
    await discovery.start();
    stdout.writeln('LanDiscovery 已启动，监听 $seconds 秒…');
  } on Object catch (e, st) {
    stderr.writeln('start() 抛异常：$e\n$st');
    await discovery.dispose();
    exit(1);
  }

  await Future<void>.delayed(Duration(seconds: seconds));
  stdout.writeln('最终：${discovery.peers.length} 台设备');
  await discovery.dispose();
}
