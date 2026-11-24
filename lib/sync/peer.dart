/// 局域网里「一台对端设备」的模型，以及发现报文的编解码。
///
/// 纯 Dart，不 import Flutter —— 与 sync/ 下其它文件保持同样的可测试性。
library;

import 'dart:convert';

import 'package:pnote/sync/account.dart';

/// 发现报文（UDP）的协议号。改动即意味着新旧版本互相看不见，必须同时改文档。
///   /1 -> 只有 deviceId / deviceName / port
///   /2 -> 多一个 account（1.51 账号 / 公开同步），不同账号的设备
///         互相看不见，广播里直接过滤掉，连拨号都不会发生。
const String kDiscoveryProto = 'pnote-discover/2';

/// 发现用的 UDP 端口。两台设备都绑这个端口，才能互相听见。
const int kDiscoveryPort = 47821;

/// 同步用的 TCP（WebSocket）起始端口；占用时依次 +1 重试，最多 10 个。
const int kSyncPort = 47822;

/// 一台被发现的对端。host 是它这次的 IP，port 是它的 WebSocket 端口。
class Peer {
  const Peer({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.lastSeen,
    this.account = '',
  });

  final String deviceId;
  final String deviceName;
  final String host;
  final int port;
  final DateTime lastSeen;

  /// 对端广播里自报的账号名（1.51 起）。扫描兜底找到的候选没有这个信息，
  /// 因此是空串 —— 真正的账号要等拨号后的 state 报文才知道。
  final String account;

  Peer touched([DateTime? at]) => Peer(
        deviceId: deviceId,
        deviceName: deviceName,
        host: host,
        port: port,
        lastSeen: at ?? DateTime.now(),
        account: account,
      );

  /// 超过 ttl 没再听到广播，就认为它已经不在了（关掉 App / 离开 Wi-Fi）。
  bool isFresh({Duration ttl = const Duration(seconds: 12)}) =>
      DateTime.now().difference(lastSeen) <= ttl;

  @override
  String toString() => '$deviceName($host:$port)';
}

/// 同一台设备被听见过多个地址时，该保留哪一个。
///
/// 为什么会这样：一台装了虚拟机/多网卡的电脑会从**每个网卡**各发一份广播，
/// 于是手机可能同时听到它的 192.168.1.x（能连）与 192.168.171.1（VMware，
/// 连不上）。如果谁后到就留谁，手机会有一半概率拿到那个连不上的地址，
/// 表现就是「这台设备明明在线，却同步不到」。
///
/// 规则：
///   1. 同网段的地址优先（[isLocal] 由调用方按本机网卡判断）；
///   2. 同优先级时取更晚听见的那条。
Peer betterPeer(
  Peer known,
  Peer candidate, {
  required bool Function(String host) isLocal,
}) {
  final knownLocal = isLocal(known.host);
  final candidateLocal = isLocal(candidate.host);
  if (knownLocal != candidateLocal) return candidateLocal ? candidate : known;
  return candidate.lastSeen.isAfter(known.lastSeen) ? candidate : known;
}

/// 广播报文。故意做得极简：只有「我是谁、我在哪个端口等你、我在哪个账号」。
String encodeAnnounce({
  required String deviceId,
  required String deviceName,
  required int port,
  String account = kDefaultAccount,
}) {
  return jsonEncode(<String, Object?>{
    'proto': kDiscoveryProto,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'port': port,
    'account': account,
  });
}

/// 解析收到的广播。任何不合规的输入都返回 null（局域网里可能有别的程序的
/// 广播包，不能因为收到垃圾就报错）。
/// [fromHost] 是数据报的来源 IP，即对端地址。
Peer? decodeAnnounce(String raw, {required String fromHost}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final map = Map<String, Object?>.from(decoded);
  if (map['proto'] != kDiscoveryProto) return null;

  final deviceId = map['deviceId'];
  final port = map['port'];
  if (deviceId is! String || deviceId.isEmpty) return null;
  if (port is! int || port <= 0 || port > 65535) return null;
  final name = map['deviceName'];
  final account = map['account'];
  // 没有 account 的广播来自 /1 的老版本：按名单过滤的要求，直接当没看见，
  // 让用户先去把两台都升级（文档 7.6 写明了这是不兼容升级）。
  if (account is! String || account.isEmpty) return null;

  return Peer(
    deviceId: deviceId,
    deviceName: name is String && name.isNotEmpty ? name : '未知设备',
    host: fromHost,
    port: port,
    lastSeen: DateTime.now(),
    account: account,
  );
}
