/// 兜底发现：UDP 广播被路由器或防火墙吞掉时，直接扫本网段的同步端口。
///
/// 为什么要这个兜底（真机实测得出）：
///   在某些路由器/系统组合上，255.255.255.255 的广播根本过不去（AP 的
///   广播/多播过滤、Windows 防火墙的入站规则、手机的节电策略都可能吞掉），
///   但「单播 TCP」一直是通的。既然一次同步本来就要建 WebSocket，
///   那就干脆把「找个能连上的邻居」变成暴力尝试：对本网段 /24 的每个
///   地址试一次握手，400 ms 内连不上就跳过。
///   代价：按下同步后最多多花几秒；收益：不依赖广播是否通。
library;

import 'dart:async';
import 'dart:io';

import 'package:pnote/sync/peer.dart';

/// 同时在飞的探测数。太大安卓会报 EMFILE，太小又太慢。
const int kScanConcurrency = 64;

/// 单个地址的握手超时。局域网内正常 < 50 ms。
const Duration kScanPerHostTimeout = Duration(milliseconds: 350);

/// 扫出「这个端口能握上手」的邻居。
///
/// 返回的 Peer 里 deviceId/deviceName 是占位的，真正的名字要等同步
/// 握手时对方报文里带回来 —— 所以界面显示请用握手结果里的 deviceName。
Future<List<Peer>> scanLanForPeers({
  int port = kSyncPort,
  Duration budget = const Duration(seconds: 8),
}) async {
  final targets = await _candidateHosts();
  if (targets.isEmpty) return const [];

  final found = <Peer>[];
  final deadline = DateTime.now().add(budget);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (DateTime.now().isAfter(deadline)) return;
      final index = next++;
      if (index >= targets.length) return;
      final host = targets[index];
      if (!await _probe(host, port)) continue;
      found.add(
        Peer(
          deviceId: '',
          deviceName: '设备',
          host: host,
          port: port,
          lastSeen: DateTime.now(),
        ),
      );
    }
  }

  await Future.wait([
    for (var i = 0; i < kScanConcurrency; i++) worker(),
  ]);
  return found;
}

/// 试一次 WebSocket 握手，成功就说明这个地址上跑着 PNote。
Future<bool> _probe(String host, int port) async {
  WebSocket? socket;
  try {
    socket = await WebSocket.connect('ws://$host:$port/')
        .timeout(kScanPerHostTimeout);
    return true;
  } on Exception {
    return false;
  } finally {
    try {
      await socket?.close();
    } on Exception {
      // 关闭失败无所谓，握手已经说明问题。
    }
  }
}

/// 本机所在各网段的全部候选地址（跳过自己和回环、链路本地）。
Future<List<String>> _candidateHosts() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
  } on Exception {
    return const [];
  }

  final targets = <String>[];
  final seen = <String>{};
  for (final interface in interfaces) {
    if (_isVirtualAdapter(interface.name)) continue;
    for (final address in interface.addresses) {
      final octets = address.address.split('.');
      if (octets.length != 4) continue;
      final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
      // 按 /24 扫。家用路由器基本都是 /24；不是的话最坏也就是白扫一遍。
      for (var host = 1; host <= 254; host++) {
        final candidate = '$prefix.$host';
        if (candidate == address.address) continue;
        if (seen.add(candidate)) targets.add(candidate);
      }
    }
  }
  return targets;
}

/// 排除虚拟机/虚拟网卡。它们的 /24 里不可能有手机，扫了纯属浪费时间
/// （本机装了 VMware，会多出两个 192.168.x 网段，扫描时间直接翻三倍）。
bool _isVirtualAdapter(String name) {
  final lower = name.toLowerCase();
  const markers = [
    'vmware',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'tap-',
    'tun',
    'loopback',
    'bluetooth',
    'wan miniport',
  ];
  return markers.any(lower.contains);
}
