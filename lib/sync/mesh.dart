/// 「一次按下同步」到底做了什么：和**每一台**被发现的设备交换状态。
///
/// 抽成独立文件的原因：这段逻辑要在单测里跑真实的三台设备
/// （test/multi_device_sync_test.dart），而 SyncService 依赖 UDP 广播，
/// 测试环境里不好稳定复现。逻辑在这里，编排（发现/扫描/流）在 SyncService。
library;

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/sync/notes_channel.dart';
import 'package:pnote/sync/payload.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/sync_result.dart';
import 'package:pnote/sync/transport.dart';

/// 一次「同步」最多收集/交换几轮。
///
/// 为什么要多轮：设备是一台一台被听见的，按下按钮那一刻没听见的设备，
/// 可能在这几十毫秒里刚好发出一声广播。一轮定死就会漏掉它
/// （用户反馈："多设备互通时，有的设备不会被扫描到"，见 7.34）。
const int kMeshMaxPasses = 3;

/// 每一轮开始时「现在能和谁同步」。传 0 表示第一轮，1、2… 表示补充轮。
typedef PeerCollector = Future<List<Peer>> Function(int pass);

/// 一次「同步」的完整过程：**边同步边重新收集对端**，直到没有新设备出现。
///
/// 和 [syncWithPeers] 的区别：这里的对端列表是每一轮现取的，所以
/// 「按下按钮时还没听见」「交换途中才上线」的设备也能被带进这一趟。
///
/// 每轮都会和**所有已知设备**交换（而不是只和新出现的那台），
/// 因为新设备的数据必须被推回给先前同步过的设备；最后一轮如果没有新设备，
/// 会再走一圈把并集推回去（≥2 台时），这与 [kMeshPasses] 的收敛约束一致。
Future<List<SyncResult>> syncMesh({
  required TaskDao dao,
  required String deviceName,
  required PeerCollector collectPeers,
  NotesChannel? notes,
  int maxPasses = kMeshMaxPasses,
  String account = kDefaultAccount,
}) async {
  final known = <String, Peer>{};
  final best = <String, SyncResult>{};
  var pushedBack = false;

  Future<void> exchangeKnown() async {
    for (final peer in known.values.toList()) {
      final key = peerKey(peer);
      final result = await exchangeWithDao(
        dao: dao,
        deviceName: deviceName,
        peer: peer,
        notes: notes,
        account: account,
      );
      final prev = best[key];
      // 每台只保留「最能代表这一趟」的那次：优先第一次成功的。
      if (prev == null || (!prev.ok && result.ok)) best[key] = result;
    }
  }

  for (var pass = 0; pass < maxPasses; pass++) {
    final peers = await collectPeers(pass);
    var added = 0;
    for (final peer in peers) {
      final key = peerKey(peer);
      if (!known.containsKey(key)) {
        known[key] = peer;
        added++;
      }
    }
    if (known.isEmpty) return const [];

    if (added == 0 && pass > 0) {
      // 这一轮没有新设备了：如果是多台，再推回一圈让所有人拿到并集，然后收工。
      if (known.length >= 2 && !pushedBack) {
        pushedBack = true;
        await exchangeKnown();
      }
      break;
    }
    await exchangeKnown();
  }

  return [
    for (final key in known.keys)
      if (best[key] != null) best[key]!,
  ];
}

/// 依次和给定的一组对端互换状态，返回每台一条结果。
///
/// 为什么有时要走两轮：
///   一轮结束后，**本机**拿到了所有人的并集，但先被拨的那台只拿到
///   「本机 + 它自己」的并集，还缺后来那台的改动。所以对端有两个及以上时
///   再走一圈，把并集推回去，所有设备才真正一致。
///   只有一台设备时不需要第二轮：一次交换双方都拿到对方的全量。
///
/// 这个函数是 [syncMesh] 的「固定名单」版本，主要给单测和一次性拨号用。
Future<List<SyncResult>> syncWithPeers({
  required TaskDao dao,
  required String deviceName,
  required List<Peer> peers,
  NotesChannel? notes,
  int? passes,
  String account = kDefaultAccount,
}) {
  return syncMesh(
    dao: dao,
    deviceName: deviceName,
    notes: notes,
    maxPasses: passes ?? kMeshMaxPasses,
    account: account,
    collectPeers: (pass) async => pass == 0 ? peers : const <Peer>[],
  );
}

/// 同一台设备的唯一标识：扫描出来的候选还没有 deviceId，用 host:port 兜底。
String peerKey(Peer peer) =>
    peer.deviceId.isEmpty ? '${peer.host}:${peer.port}' : peer.deviceId;

/// 与指定对端互换一次状态。所有网络异常在这里翻译成可读结果。
Future<SyncResult> exchangeWithDao({
  required TaskDao dao,
  required String deviceName,
  required Peer peer,
  NotesChannel? notes,
  String account = kDefaultAccount,
}) async {
  final SyncExchange exchange;
  try {
    exchange = await exchangeWithPeerFull(
      peer: peer,
      local: await dao.exportState(deviceName: deviceName),
      notes: notes,
      account: account,
    );
  } on TimeoutException catch (e) {
    return SyncResult.failed(SyncFailure.timeout, detail: e.message);
  } on AccountMismatch catch (e) {
    return SyncResult.failed(
      SyncFailure.account,
      detail: e.peerAccount,
      peerName: peer.deviceName,
    );
  } on PayloadException catch (e) {
    return SyncResult.failed(SyncFailure.protocol, detail: e.message);
  } on SocketException catch (e) {
    return SyncResult.failed(
      SyncFailure.connectFailed,
      detail: e.message,
      peerName: peer.deviceName,
    );
  } on Exception catch (e) {
    return SyncResult.failed(
      SyncFailure.connectFailed,
      detail: '$e',
      peerName: peer.deviceName,
    );
  }

  final remote = exchange.state;
  try {
    final stats = await dao.applyRemote(remote);
    // 名字以对方报文里自报的为准（扫描出来的候选并不知道对面叫什么）。
    return SyncResult.success(
      peerName: remote.deviceName,
      stats: stats,
      notes: exchange.notes,
    );
  } catch (e) {
    return SyncResult.failed(SyncFailure.localError, detail: '$e');
  }
}
