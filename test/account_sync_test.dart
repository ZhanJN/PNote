import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/sync/payload.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/sync_service.dart';
import 'package:pnote/sync/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.51 账号：同名才同步。
///
/// 这里不测广播（UDP 在 CI 上不稳），只测「报文里带账号」和
/// 「账号不同时握手直接失败、数据不落库」——真正的局域网行为留给手验。
void main() {
  setUpAll(sqfliteFfiInit);

  final servers = <SyncServer>[];
  final opened = <Database>[];
  final paths = <String>[];

  Future<TaskDao> newDao() async {
    final dir = await Directory.systemTemp.createTemp('pnote_account_');
    final path = '${dir.path}/account.db';
    paths.add(path);
    final db = await openAppDatabase(overridePath: path);
    opened.add(db);
    return TaskDao.attach(db);
  }

  tearDown(() async {
    for (final s in servers) {
      await s.stop();
    }
    servers.clear();
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    for (final path in paths) {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    }
    paths.clear();
  });

  test('state 帧带上 account，解出来还是同一个', () {
    final state = SyncState(
      deviceId: 'dev-a',
      deviceName: 'A',
      tasks: const {},
      purged: const {},
    );
    final wire = encodeState(state, account: '学习小组');
    expect(wire, contains('"account":"学习小组"'));
    final envelope = decodeEnvelope(wire);
    expect(envelope.account, '学习小组');
  });

  test('旧备份转成的 state 没有 account 时按空串读，不抛', () {
    final state = SyncState(
      deviceId: 'dev-a',
      deviceName: 'A',
      tasks: const {},
      purged: const {},
    );
    final wire = encodeState(state, account: '');
    final envelope = decodeEnvelope(wire);
    expect(envelope.account, isEmpty);
  });

  Future<(TaskDao, Peer)> startB(TaskDao daoB, String account) async {
    final server = SyncServer(
      deviceId: daoB.clock.deviceId,
      account: account,
      onRemoteState: (remote) async {
        await daoB.applyRemote(remote);
        return daoB.exportState(deviceName: 'B');
      },
    );
    await server.start();
    servers.add(server);
    return (
      daoB,
      Peer(
        deviceId: daoB.clock.deviceId,
        deviceName: 'B',
        host: '127.0.0.1',
        port: server.boundPort!,
        lastSeen: DateTime.now(),
      ),
    );
  }

  test('同名账号可以正常互换', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('买菜');
    final (_, peer) = await startB(daoB, '学习小组');

    final remote = await exchangeWithPeerFull(
      peer: peer,
      local: await daoA.exportState(deviceName: 'A'),
      account: '学习小组',
    );
    await daoA.applyRemote(remote.state);

    expect((await daoB.visibleTasks()).map((t) => t.title), ['买菜']);
    expect((await daoA.visibleTasks()).map((t) => t.title), ['买菜']);
  });

  test('账号不同：握手抛 AccountMismatch，对方数据没被改', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    await daoA.addTask('不该同步过去');
    final (_, peer) = await startB(daoB, '我的 PNote');

    await expectLater(
      exchangeWithPeerFull(
        peer: peer,
        local: await daoA.exportState(deviceName: 'A'),
        account: '公开同步',
      ),
      throwsA(isA<AccountMismatch>()),
    );
    expect(await daoB.visibleTasks(), isEmpty);
  });

  test('SyncService 的 account 取归一化后的值，setAccount 立即生效', () async {
    final dao = await newDao();
    final service = SyncService(
      dao: dao,
      deviceName: 'A',
      account: '  学习小组  ',
    );
    expect(service.account, '学习小组');
    service.setAccount('  ');
    expect(service.account, kDefaultAccount);
    service.setAccount('公开同步');
    expect(service.account, kPublicAccount);
  });
}
