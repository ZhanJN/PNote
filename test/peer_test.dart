import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/sync/peer.dart';

/// 发现报文（UDP）的编解码。局域网里会收到别的程序的广播包，
/// 所以「不认识就返回 null」比「抛异常」更重要。
void main() {
  test('广播报文能原样回来', () {
    final raw = encodeAnnounce(
      deviceId: 'dev-1',
      deviceName: '电脑',
      port: 47822,
    );
    final peer = decodeAnnounce(raw, fromHost: '192.168.1.7');
    expect(peer, isNotNull);
    expect(peer!.deviceId, 'dev-1');
    expect(peer.deviceName, '电脑');
    expect(peer.host, '192.168.1.7');
    expect(peer.port, 47822);
  });

  test('别的程序的广播（协议号不对）被忽略', () {
    expect(
      decodeAnnounce('{"proto":"other-app/2","deviceId":"x","port":1}',
          fromHost: '1.2.3.4'),
      isNull,
    );
  });

  test('坏 JSON 被忽略而不是抛异常', () {
    expect(decodeAnnounce('not json at all', fromHost: '1.2.3.4'), isNull);
    expect(decodeAnnounce('[]', fromHost: '1.2.3.4'), isNull);
    expect(decodeAnnounce('{}', fromHost: '1.2.3.4'), isNull);
  });

  test('缺字段或端口非法被忽略', () {
    expect(
      decodeAnnounce('{"proto":"$kDiscoveryProto","deviceId":"d"}',
          fromHost: '1.2.3.4'),
      isNull,
    );
    expect(
      decodeAnnounce(
          '{"proto":"$kDiscoveryProto","deviceId":"d","port":70000}',
          fromHost: '1.2.3.4'),
      isNull,
    );
  });

  test('超过 ttl 没再听到，就认为对端已经离开', () {
    final stale = Peer(
      deviceId: 'old',
      deviceName: '旧设备',
      host: '10.0.0.2',
      port: 47822,
      lastSeen: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(stale.isFresh(), isFalse);
    expect(stale.touched().isFresh(), isTrue);
  });

  test('中文设备名走真实字节链路（UTF-8）后仍然正确', () {
    // 真机上踩过的坑：早期用 String.codeUnits 直接当字节发，中文字符被截成
    // 低 8 位（"手机" 变成 "K:"），对端要么解析出乱码，要么直接判为坏包。
    // 这条用例把「编码 → 字节 → 解码 → 解析」整条链路串起来测。
    final payload = encodeAnnounce(
      deviceId: 'dev-中文',
      deviceName: '手机',
      port: kSyncPort,
    );
    final bytes = utf8.encode(payload); // 必须与 discovery.dart 发送时一致
    expect(utf8.decode(bytes), payload, reason: '做一次字节往返，确认无损');

    final peer = decodeAnnounce(utf8.decode(bytes), fromHost: '192.168.1.42');
    expect(peer, isNotNull);
    expect(peer!.deviceName, '手机');
    expect(peer.deviceId, 'dev-中文');
    expect(peer.port, kSyncPort);
  });

  group('同一台设备被听见多个地址时选哪个（1.15）', () {
    Peer make(String host, {int secondsAgo = 0}) => Peer(
          deviceId: 'dev-1',
          deviceName: '电脑',
          host: host,
          port: kSyncPort,
          lastSeen: DateTime.now().subtract(Duration(seconds: secondsAgo)),
        );
    bool sameSubnet(String host) => host.startsWith('192.168.1.');

    test('同网段优先：哪怕异网段那条更晚到', () {
      final known = make('192.168.1.42', secondsAgo: 3); // 能连的地址
      final candidate = make('192.168.171.1'); // VMware，刚听到但连不上
      final chosen = betterPeer(known, candidate, isLocal: sameSubnet);
      expect(chosen.host, '192.168.1.42');
    });

    test('已知的是异网段、新来的是同网段时，换过去', () {
      final known = make('192.168.171.1', secondsAgo: 1);
      final candidate = make('192.168.1.42');
      final chosen = betterPeer(known, candidate, isLocal: sameSubnet);
      expect(chosen.host, '192.168.1.42');
    });

    test('同为同网段时取更晚听见的那条（端口可能变了）', () {
      final known = make('192.168.1.42', secondsAgo: 2);
      final candidate = Peer(
        deviceId: 'dev-1',
        deviceName: '电脑',
        host: '192.168.1.42',
        port: kSyncPort + 1,
        lastSeen: DateTime.now(),
      );
      final chosen = betterPeer(known, candidate, isLocal: sameSubnet);
      expect(chosen.port, kSyncPort + 1);
    });

    test('两个都是异网段时，仍然取更晚听见的（不做无谓丢弃）', () {
      final known = make('10.0.0.5', secondsAgo: 5);
      final candidate = make('10.0.0.6');
      final chosen = betterPeer(known, candidate, isLocal: sameSubnet);
      expect(chosen.host, '10.0.0.6');
    });
  });
}
