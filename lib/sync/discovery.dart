/// 局域网发现：UDP 广播，不用 mDNS。
///
/// 为什么不用 mDNS（ADR 变更，见《PNote项目说明》7.1）：
///   mDNS 需要一个原生插件（nsd）在 Windows 上跑 WinRT、在 Android 上跑
///   NsdManager，两边都要额外的服务注册/解析流程，出错时只报一个错误码。
///   而我们需要的信息只有「对端 IP + 端口」，用 UDP 广播几十行就能拿到，
///   且 Windows 与 Android 都原生支持，不引入任何插件与构建风险。
///
/// 为什么发包要按网卡逐个发（这是 Android 上的关键细节）：
///   手机同时连着 Wi‑Fi 和移动数据时，默认路由可能走移动数据；直接往
///   255.255.255.255 发，包会从移动数据出去，局域网里谁也收不到。
///   所以每个本地 IPv4 地址各开一个「发送用 socket」并绑定该地址，
///   这样包一定从对应网卡出去。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pnote/sync/peer.dart';

/// 广播间隔。太快浪费电与带宽，太慢用户点「同步」后要等。
const Duration kAnnounceInterval = Duration(milliseconds: 700);

class LanDiscovery {
  LanDiscovery({
    required this.deviceId,
    required this.deviceName,
    required this.servicePort,
  });

  final String deviceId;
  final String deviceName;

  /// 本机 WebSocket 端口，随广播发出去，对端据此拨号。
  final int servicePort;

  final Map<String, Peer> _peers = {};

  /// 本机「真实网卡」的 /24 前缀（如 `192.168.1.`）。
  ///
  /// 用途：一台多网卡的电脑会从每个网卡各发一份广播，手机会同时听到
  /// 192.168.1.x（能连）和 VMware 的地址（连不上）。靠这份前缀把
  /// 「同网段的地址」排在前面，见 [betterPeer]。
  final Set<String> _localPrefixes = {};

  /// 接收用 socket（绑 anyIPv4:47821，所有网卡都收）。
  RawDatagramSocket? _receiver;

  /// 发送用 socket：每个本地 IPv4 地址一个，绑在该地址上强制走对应网卡。
  /// [address] 是该 socket 绑定的本机地址，用来算「定向广播地址」。
  final List<({InternetAddress? address, RawDatagramSocket socket})> _senders =
      [];

  final StreamController<List<Peer>> _peerChanges =
      StreamController<List<Peer>>.broadcast();

  Timer? _timer;
  bool _disposed = false;

  /// 当前还活着的对端（每次变化都会推一次）。
  Stream<List<Peer>> get peerChanges => _peerChanges.stream;

  List<Peer> get peers => List.unmodifiable(_freshPeers());

  Future<void> start() async {
    if (_receiver != null) return;

    final receiver = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
    );
    _receiver = receiver;
    receiver.broadcastEnabled = true;
    receiver.listen(
      (event) {
        if (event == RawSocketEvent.read) _onReadable();
      },
      onError: (Object _) {},
    );

    await _openSenders();
    _announce();
    _timer = Timer.periodic(kAnnounceInterval, (_) {
      _announce();
      _expirePeers();
    });
  }

  /// 为每个非回环 IPv4 地址开一个发送 socket。
  ///
  /// 虚拟网卡（VMware / VirtualBox / Hyper-V / VPN / 隧道）不参与发送：
  /// 从它们发出的广播会被对端当成「这台设备的另一个地址」，而那个地址
  /// 对端根本连不上（见 7.33）。
  Future<void> _openSenders() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } on Exception {
      _senders.add((address: null, socket: _receiver!));
      return;
    }
    for (final interface in interfaces) {
      final virtual = _isVirtualAdapter(interface.name);
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        if (virtual) continue; // 虚拟网卡：既不发广播，也不算「同网段」
        _localPrefixes.add(_prefixOf(address.address));
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          socket.broadcastEnabled = true;
          _senders.add((address: address, socket: socket));
        } on Exception {
          // 某个地址绑不上就跳过，不影响其它网卡。
        }
      }
    }
    if (_senders.isEmpty) _senders.add((address: null, socket: _receiver!));
    // ignore: avoid_print
    print('[pnote] 广播发送 socket 就绪：${_senders.length} 个');
  }

  /// 网卡名是否属于虚拟/隧道网卡（按名字判断，无需平台分支）。
  bool _isVirtualAdapter(String name) {
    final n = name.toLowerCase();
    const markers = <String>[
      'vmware',
      'virtualbox',
      'vbox',
      'hyper-v',
      'vethernet',
      'tap-',
      'tun',
      'loopback',
      'bluetooth',
      'wan miniport',
      'npcap',
      'zerotier',
      'tailscale',
      'wireguard',
      'openvpn',
      'docker',
    ];
    return markers.any(n.contains);
  }

  /// `192.168.1.42` → `192.168.1.`（家用网络基本都是 /24）。
  String _prefixOf(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return host;
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  /// 这个地址是否与本机某块真实网卡同网段。
  bool isSameSubnet(String host) {
    if (_localPrefixes.isEmpty) return true; // 拿不到网卡信息时不作区分
    final prefix = _prefixOf(host);
    return _localPrefixes.contains(prefix);
  }

  void _onReadable() {
    final receiver = _receiver;
    if (receiver == null) return;
    Datagram? datagram;
    while ((datagram = receiver.receive()) != null) {
      final data = datagram!;
      final raw = utf8.decode(data.data, allowMalformed: true);
      final peer = decodeAnnounce(raw, fromHost: data.address.address);
      if (peer == null) continue;
      if (peer.deviceId == deviceId) continue; // 自己发的广播，忽略

      final known = _peers[peer.deviceId];
      if (known == null) {
        _peers[peer.deviceId] = peer;
        _emit();
        // 单播回应：广播可能是单向的（部分路由器 / AP 隔离场景）。
        _sendTo(data.address);
        continue;
      }

      // 同一台设备可能有多个地址（多网卡对端）：同网段优先，见 betterPeer。
      // 无论最终用哪个地址，只要听见了就算它还活着 —— 这里刷新 lastSeen，
      // 否则「只发来差地址」的设备 12 秒后会被误判成离线。
      final chosen = betterPeer(known, peer, isLocal: isSameSubnet);
      final refreshed = chosen.host == known.host ? chosen.touched() : chosen;
      _peers[peer.deviceId] = refreshed;
      // 只在新出现或地址变化时回调，避免每 700 ms 刷一次界面。
      if (refreshed.host != known.host ||
          refreshed.port != known.port ||
          refreshed.deviceName != known.deviceName) {
        _emit();
      }
    }
  }

  void _announce() {
    // 同时发两种广播地址：
    //   255.255.255.255 —— 受限广播，最常见的写法；
    //   x.y.z.255       —— 定向广播，有些路由器/AP 只放过这一种。
    // 两种情况都试，成本只是多一个包。
    final payload = encodeAnnounce(
      deviceId: deviceId,
      deviceName: deviceName,
      port: servicePort,
    );
    final bytes = utf8.encode(payload);
    for (final sender in _senders) {
      _sendBytes(sender.socket, bytes, InternetAddress('255.255.255.255'));
      final directed = _directedBroadcast(sender.address);
      if (directed != null) _sendBytes(sender.socket, bytes, directed);
    }
    // 对已经认识的邻居单播一次，保证它不会因为错过广播而被判"离线"。
    if (_sentCount % 4 == 0) {
      for (final peer in _peers.values) {
        if (peer.isFresh()) _sendTo(InternetAddress(peer.host));
      }
    }
    if (_sentCount % (20 * _senders.length * 2) == 0 && _sentCount > 0) {
      // ignore: avoid_print
      print('[pnote] 已发送 $_sentCount 个广播包，sender=${_senders.length}');
    }
  }

  /// 由本机地址推 /24 的定向广播地址（家用路由器几乎都是 /24）。
  InternetAddress? _directedBroadcast(InternetAddress? address) {
    if (address == null) return null;
    final octets = address.address.split('.');
    if (octets.length != 4) return null;
    return InternetAddress('${octets[0]}.${octets[1]}.${octets[2]}.255');
  }

  int _sentCount = 0;
  bool _loggedOnce = false;

  void _sendBytes(RawDatagramSocket socket, List<int> bytes, InternetAddress to) {
    try {
      socket.send(bytes, to, kDiscoveryPort);
      _sentCount++;
    } on SocketException catch (e) {
      if (!_loggedOnce) {
        _loggedOnce = true;
        // ignore: avoid_print
        print('[pnote] 广播发送失败到 $to：${e.message}');
      }
    }
  }

  void _sendTo(InternetAddress address) {
    if (_senders.isEmpty) return;
    final payload = encodeAnnounce(
      deviceId: deviceId,
      deviceName: deviceName,
      port: servicePort,
    );
    final bytes = utf8.encode(payload);
    for (final sender in _senders) {
      _sendBytes(sender.socket, bytes, address);
    }
  }

  /// 把超时未再出现的对端踢掉，并推一次变化。
  void _expirePeers() {
    final before = _peers.length;
    _peers.removeWhere((_, peer) => !peer.isFresh());
    if (_peers.length != before) _emit();
  }

  /// 过滤掉已经超时的对端（不修改 map，避免读操作暗中改状态）。
  List<Peer> _freshPeers() {
    return [
      for (final peer in _peers.values)
        if (peer.isFresh()) peer,
    ];
  }

  void _emit() {
    if (_disposed) return;
    _peerChanges.add(peers);
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final sender in _senders) {
      sender.socket.close();
    }
    _senders.clear();
    _receiver?.close();
    _receiver = null;
    await _peerChanges.close();
  }
}
