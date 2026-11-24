/// 一次性验证脚本：单独跑网段扫描，看能不能在真机网络里找到邻居。
/// 用法：dart run tool/scan_probe.dart [额外探测的地址]
library;

import 'dart:io';

import 'package:pnote/sync/scan.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    final host = args.first;
    final sw = Stopwatch()..start();
    try {
      final ws = await WebSocket.connect('ws://$host:47822/')
          .timeout(const Duration(milliseconds: 400));
      stdout.writeln('单点探测 $host：成功 ${sw.elapsedMilliseconds} ms');
      await ws.close();
    } on Exception catch (e) {
      stdout.writeln('单点探测 $host：失败 ${sw.elapsedMilliseconds} ms $e');
    }
  }

  final started = DateTime.now();
  stdout.writeln('开始扫本网段（20 秒预算）…');
  final peers = await scanLanForPeers(budget: const Duration(seconds: 20));
  final elapsed = DateTime.now().difference(started);
  stdout.writeln('耗时 ${elapsed.inMilliseconds} ms，命中 ${peers.length} 台');
  for (final peer in peers) {
    stdout.writeln('  ${peer.host}:${peer.port}');
  }
  exit(0);
}
