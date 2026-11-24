import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 端到端的「一次同步」：真开一个 WebSocket 服务端（127.0.0.1），
/// 两个独立的数据库各代表一台设备，验证 A 改的东西能到 B、B 改的能回 A、
/// 删除会以墓碑同步过去。对应《PNote项目说明》9.4 的 A/B/E 三组。
///
/// 发现（UDP 广播）不在这里测：它依赖真实网卡，测试环境不稳定，
/// 用 test/peer_test.dart 覆盖报文的编解码，真机验证交给用户。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_sync_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
    );
    paths.add(path);
    return path;
  }

  Future<TaskDao> newDao() async {
    final db = await openAppDatabase(overridePath: nextPath());
    opened.add(db);
    return TaskDao.attach(db);
  }

  final servers = <SyncServer>[];

  tearDown(() async {
    for (final server in servers) {
      await server.stop();
    }
    servers.clear();
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    for (final path in paths) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    paths.clear();
  });

  /// 起一台「B 机」：收到 A 的状态就合并，再把合并结果回给 A。
  Future<Peer> startB(TaskDao daoB) async {
    final server = SyncServer(
      deviceId: daoB.clock.deviceId,
      onRemoteState: (remote) async {
        await daoB.applyRemote(remote);
        return daoB.exportState(deviceName: 'B');
      },
    );
    await server.start();
    servers.add(server);
    return Peer(
      deviceId: daoB.clock.deviceId,
      deviceName: 'B',
      host: '127.0.0.1',
      port: server.boundPort!,
      lastSeen: DateTime.now(),
    );
  }

  /// A 点一次「同步」。
  Future<void> syncAto(TaskDao daoA, Peer peer) async {
    final remote = await exchangeWithPeer(
      peer: peer,
      local: await daoA.exportState(deviceName: 'A'),
    );
    await daoA.applyRemote(remote);
  }

  test('A 新建的任务，同步后 B 也能看到', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('买菜');
    final peer = await startB(daoB);

    await syncAto(daoA, peer);

    final a = await daoA.visibleTasks();
    final b = await daoB.visibleTasks();
    expect(a.map((t) => t.title), ['买菜']);
    expect(b.map((t) => t.title), ['买菜']);
    // 两台设备的 ID 不同，说明它们在各自独立地标识自己。
    expect(daoA.clock.deviceId, isNot(daoB.clock.deviceId));
  });

  test('B 改标题后同步，A 拿到新标题（反向）', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('跑步');
    final peer = await startB(daoB);
    await syncAto(daoA, peer);

    final id = (await daoB.visibleTasks()).single.id;
    await daoB.renameTask(id, '跑步 3 公里');
    await syncAto(daoA, peer);

    expect((await daoA.visibleTasks()).single.title, '跑步 3 公里');
  });

  test('同一条任务两边都改标题：最后改的那一次赢', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('原标题');
    final peer = await startB(daoB);
    await syncAto(daoA, peer);

    final id = (await daoA.visibleTasks()).single.id;
    await daoA.renameTask(id, 'A 改的');
    await daoB.renameTask(id, 'B 改的'); // B 的时钟已被 A 推进，因此 B 更晚
    await syncAto(daoA, peer);

    final a = (await daoA.visibleTasks()).single.title;
    final b = (await daoB.visibleTasks()).single.title;
    expect(a, 'B 改的');
    expect(b, 'B 改的');
  });

  test('B 删除后同步，A 也看不到这条任务（墓碑）', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('要删掉的');
    final peer = await startB(daoB);
    await syncAto(daoA, peer);

    final id = (await daoB.visibleTasks()).single.id;
    await daoB.softDelete(id);
    await syncAto(daoA, peer);

    expect(await daoA.visibleTasks(), isEmpty);
    expect(await daoB.visibleTasks(), isEmpty);
  });

  test('重复同步不产生重复任务（幂等）', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('只加一次');
    final peer = await startB(daoB);

    await syncAto(daoA, peer);
    await syncAto(daoA, peer);
    await syncAto(daoA, peer);

    expect((await daoA.visibleTasks()).length, 1);
    expect((await daoB.visibleTasks()).length, 1);
  });
}
