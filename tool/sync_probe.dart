/// 一次性验证脚本（不参与 App 运行）：从电脑这边扮演「另一台设备」，
/// 看同一 Wi‑Fi 下有没有设备在广播、能不能连上它的 WebSocket、
/// 并把它的全量状态读回来。
///
/// 只读：发过去的是一份空状态，所以不会往对方库里写任何东西。
///
/// 用法（在 PNote 目录下）：
///   dart run tool/sync_probe.dart                  # 先靠 UDP 广播发现，再拨号
///   dart run tool/sync_probe.dart 192.168.1.42 47822   # 跳过发现，直接拨号
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pnote/data/models.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/transport.dart';

const String kProbeId = 'probe-device-0001';

Future<void> main(List<String> args) async {
  if (args.length >= 2) {
    await _dial(
      Peer(
        deviceId: 'direct',
        deviceName: args[0],
        host: args[0],
        port: int.parse(args[1]),
        lastSeen: DateTime.now(),
      ),
    );
    return;
  }

  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    kDiscoveryPort,
    reuseAddress: true,
  );
  socket.broadcastEnabled = true;
  stdout.writeln('监听 UDP $kDiscoveryPort …（6 秒）');

  // 同时扮演一台真实的设备：每 700 ms 广播一次自己，这样子机（手机）界面上
  // 也能看到「发现 probe」，用来验证反向的广播是否通。
  final senders = <RawDatagramSocket>[];
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  )) {
    for (final address in interface.addresses) {
      try {
        final s = await RawDatagramSocket.bind(address, 0);
        s.broadcastEnabled = true;
        senders.add(s);
      } on Exception {
        // 跳过绑不上的地址
      }
    }
  }
  final announceBytes = encodeAnnounce(
    deviceId: kProbeId,
    deviceName: 'probe',
    port: 47999,
  ).codeUnits;
  final announcer = Timer.periodic(const Duration(milliseconds: 700), (_) {
    for (final s in senders) {
      try {
        s.send(announceBytes, InternetAddress('255.255.255.255'), kDiscoveryPort);
      } on SocketException {
        // 忽略
      }
    }
  });

  final found = <String, Map<String, Object?>>{};
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final text = utf8.decode(datagram.data, allowMalformed: true);
    if (!text.contains(kDiscoveryProto)) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, Object?>.from(decoded);
    if (map['deviceId'] == kProbeId) return;
    found['${map['deviceId']}'] = {
      ...map,
      'host': datagram.address.address,
    };
    stdout.writeln(
      '发现：${map['deviceName']}  host=${datagram.address.address}  port=${map['port']}',
    );
  });

  await Future<void>.delayed(const Duration(seconds: 6));
  announcer.cancel();
  for (final s in senders) {
    s.close();
  }
  if (found.isEmpty) {
    stdout.writeln('6 秒内没收到任何广播 —— 对端没开 App，或不在同一网段。');
    exitCode = 1;
    socket.close();
    return;
  }

  for (final entry in found.values) {
    final peer = Peer(
      deviceId: '${entry['deviceId']}',
      deviceName: '${entry['deviceName']}',
      host: '${entry['host']}',
      port: entry['port'] as int,
      lastSeen: DateTime.now(),
    );
    stdout.writeln('拨号 ${peer.host}:${peer.port} …');
    await _dial(peer);
  }
  socket.close();
}

/// 拨号并读回对端状态。发过去的是一份空状态，因此不会改动对方数据。
Future<void> _dial(Peer peer) async {
  stdout.writeln('拨号 ${peer.host}:${peer.port} …');
  try {
    final remote = await exchangeWithPeer(
      peer: peer,
      local: SyncState(
        deviceId: kProbeId,
        deviceName: 'probe',
        tasks: const {},
      ),
    );
    stdout.writeln('握手成功：对端 deviceId=${remote.deviceId}  '
        'deviceName=${remote.deviceName}  任务数=${remote.tasks.length}');
    for (final task in remote.visibleTasks) {
      stdout.writeln('  - ${task.title}  ${task.done ? '[x]' : '[ ]'}');
    }
  } on Exception catch (e) {
    stdout.writeln('拨号失败：$e');
    exitCode = 2;
  }
}
