import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/merge.dart';
import 'package:pnote/sync/mesh.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/sync_result.dart';
import 'package:pnote/sync/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 多设备（1.14 起）：同一局域网里三台以上的设备互相同步。
///
/// 关键性质：合并是幂等 + 交换律 + 结合的（NFR-01 / NFR-02），
/// 所以「一台按下同步、依次和其余设备交换」就能让所有设备收敛到同一份数据。
/// 这里跑的是生产代码 [syncWithPeers]，不是测试自己拼的循环。
///
/// 发现（UDP 广播）仍不在单测里测：依赖真实网卡，交给真机验证。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <Database>[];
  final paths = <String>[];
  final servers = <SyncServer>[];
  var seq = 0;

  String nextPath() {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_multi_${DateTime.now().microsecondsSinceEpoch}_${seq++}.db',
    );
    paths.add(path);
    return path;
  }

  Future<TaskDao> newDao() async {
    final db = await openAppDatabase(overridePath: nextPath());
    opened.add(db);
    return TaskDao.attach(db);
  }

  /// 起一台「被拨号方」：收到状态就合并，再把合并后的全量回给对方。
  Future<Peer> serve(TaskDao dao, String name) async {
    final server = SyncServer(
      deviceId: dao.clock.deviceId,
      onRemoteState: (remote) async {
        await dao.applyRemote(remote);
        return dao.exportState(deviceName: name);
      },
    );
    await server.start();
    servers.add(server);
    return Peer(
      deviceId: dao.clock.deviceId,
      deviceName: name,
      host: '127.0.0.1',
      port: server.boundPort!,
      lastSeen: DateTime.now(),
    );
  }

  /// 生产代码里的「按一次同步」。
  Future<List<SyncResult>> pressSync(
    TaskDao dao,
    String name,
    List<Peer> peers,
  ) =>
      syncWithPeers(dao: dao, deviceName: name, peers: peers);

  List<String> titlesOf(List tasks) => [for (final t in tasks) t.title as String];

  bool sameTitles(List<String> a, List<String> b) {
    final x = [...a]..sort();
    final y = [...b]..sort();
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

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

  test('一台按下同步，其余两台都拿到它的改动（一次按完全部）', () async {
    final a = await newDao();
    final b = await newDao();
    final c = await newDao();
    final peerB = await serve(b, 'B');
    final peerC = await serve(c, 'C');

    await a.addTask('A 的任务');
    final results = await pressSync(a, 'A', [peerB, peerC]);

    expect(results.length, 2);
    expect(results.every((r) => r.ok), isTrue);
    expect(titlesOf(await a.visibleTasks()), ['A 的任务']);
    expect(titlesOf(await b.visibleTasks()), ['A 的任务']);
    expect(titlesOf(await c.visibleTasks()), ['A 的任务']);
  });

  test('三台各自新增，任一台上按一次同步，三台内容一致', () async {
    final a = await newDao();
    final b = await newDao();
    final c = await newDao();
    final peerB = await serve(b, 'B');
    final peerC = await serve(c, 'C');

    await a.addTask('A 买的');
    await b.addTask('B 买的');
    await c.addTask('C 买的');

    // 只从 A 按一次。
    await pressSync(a, 'A', [peerB, peerC]);

    const expected = ['A 买的', 'B 买的', 'C 买的'];
    expect(sameTitles(titlesOf(await a.visibleTasks()), expected), isTrue);
    expect(sameTitles(titlesOf(await b.visibleTasks()), expected), isTrue);
    expect(sameTitles(titlesOf(await c.visibleTasks()), expected), isTrue);
  });

  test('交换顺序反过来（先 C 后 B），结果相同', () async {
    final a = await newDao();
    final b = await newDao();
    final c = await newDao();
    final peerB = await serve(b, 'B');
    final peerC = await serve(c, 'C');

    await a.addTask('A 买的');
    await b.addTask('B 买的');
    await c.addTask('C 买的');

    await pressSync(a, 'A', [peerC, peerB]);

    const expected = ['A 买的', 'B 买的', 'C 买的'];
    expect(sameTitles(titlesOf(await a.visibleTasks()), expected), isTrue);
    expect(sameTitles(titlesOf(await b.visibleTasks()), expected), isTrue);
    expect(sameTitles(titlesOf(await c.visibleTasks()), expected), isTrue);
  });

  test('三台里一台删除，其余两台同步后都看不到它', () async {
    final a = await newDao();
    final b = await newDao();
    final c = await newDao();
    final peerB = await serve(b, 'B');
    final peerC = await serve(c, 'C');

    await a.addTask('要删的');
    await a.addTask('留着的');
    await pressSync(a, 'A', [peerB, peerC]);

    final target =
        (await b.visibleTasks()).firstWhere((t) => t.title == '要删的');
    await b.softDelete(target.id);

    // B 把删除推给 C，然后 A 再按一次 —— 三台都该只剩「留着的」。
    await pressSync(b, 'B', [peerC]);
    await pressSync(a, 'A', [peerB]);

    for (final dao in [a, b, c]) {
      expect(titlesOf(await dao.visibleTasks()), ['留着的']);
    }
  });

  test('连着同步多轮不会产生重复任务（幂等）', () async {
    final a = await newDao();
    final b = await newDao();
    final c = await newDao();
    final peerB = await serve(b, 'B');
    final peerC = await serve(c, 'C');

    await a.addTask('只加一次');
    for (var i = 0; i < 3; i++) {
      await pressSync(a, 'A', [peerB, peerC]);
    }
    expect((await a.visibleTasks()).length, 1);
    expect((await b.visibleTasks()).length, 1);
    expect((await c.visibleTasks()).length, 1);
  });

  test('第二次按同步时统计归零（没有新变化就不会乱报）', () async {
    final a = await newDao();
    final b = await newDao();
    await a.addTask('一条');
    final peerB = await serve(b, 'B');

    await pressSync(a, 'A', [peerB]);
    final second = await pressSync(a, 'A', [peerB]);
    expect(second.single.stats!.isNoop, isTrue);
  });

  group('SyncBatch 的结果文案', () {
    test('一台成功', () {
      final batch = SyncBatch.single(
        const SyncResult.success(
          peerName: '手机',
          stats: MergeStats(addedTasks: 2),
        ),
      );
      expect(batch.message, '本机已与「手机」同步：新增 2 · 更新 0 · 删除 0');
    });

    test('多台成功：合并统计、按台数说', () {
      const batch = SyncBatch([
        SyncResult.success(peerName: '手机', stats: MergeStats(addedTasks: 2)),
        SyncResult.success(peerName: '平板', stats: MergeStats(addedTasks: 1)),
      ]);
      expect(batch.message, '本机已与 2 台设备同步：新增 3 · 更新 0 · 删除 0');
      expect(batch.okCount, 2);
    });

    test('部分失败：说清哪台没成功、什么原因', () {
      const batch = SyncBatch([
        SyncResult.success(peerName: '手机', stats: MergeStats(addedTasks: 1)),
        SyncResult.failed(SyncFailure.timeout, peerName: '平板'),
      ]);
      expect(
        batch.message,
        '本机已与「手机」同步：新增 1 · 更新 0 · 删除 0（「平板」没成功：连接超时）',
      );
    });

    test('全部失败：用第一台的原因，并说明还有几台也没成', () {
      const batch = SyncBatch([
        SyncResult.failed(SyncFailure.connectFailed, peerName: '手机'),
        SyncResult.failed(SyncFailure.timeout, peerName: '平板'),
      ]);
      expect(batch.message, contains('「手机」'));
      expect(batch.message, contains('另外 1 台也没成功'));
      expect(batch.okCount, 0);
    });

    test('一台都没发现', () {
      const batch = SyncBatch.empty();
      expect(batch.message, contains('没找到另一台设备'));
    });
  });

  group('1.15 边同步边重新收集（用户反馈：有的设备扫不到）', () {
    test('第一轮没听见、第二轮才出现的设备，也会被带进这一趟', () async {
      final a = await newDao();
      final b = await newDao();
      final c = await newDao();
      final peerB = await serve(b, 'B');
      final peerC = await serve(c, 'C');

      await a.addTask('A 的');
      await b.addTask('B 的');
      await c.addTask('C 的');

      var lastPass = -1;
      final results = await syncMesh(
        dao: a,
        deviceName: 'A',
        collectPeers: (pass) async {
          lastPass = pass;
          // C 在第一轮"还没被听见"，第二轮才出现。
          return pass == 0 ? [peerB] : [peerB, peerC];
        },
      );

      const expected = ['A 的', 'B 的', 'C 的'];
      expect(results.length, 2, reason: '两台都要出现在结果里');
      expect(results.every((r) => r.ok), isTrue);
      expect(lastPass, greaterThanOrEqualTo(1), reason: '应该真的收集了第二轮');
      // 三台都要收敛（B 靠最后一轮"推回"拿到 C 的数据）。
      expect(sameTitles(titlesOf(await a.visibleTasks()), expected), isTrue);
      expect(sameTitles(titlesOf(await b.visibleTasks()), expected), isTrue);
      expect(sameTitles(titlesOf(await c.visibleTasks()), expected), isTrue);
    });

    test('收集一直没结果时不报错、也不无限循环', () async {
      final a = await newDao();
      await a.addTask('只有我');
      final results = await syncMesh(
        dao: a,
        deviceName: 'A',
        collectPeers: (pass) async => const <Peer>[],
      );
      expect(results, isEmpty);
      expect(titlesOf(await a.visibleTasks()), ['只有我']);
    });

    test('一台连不上不影响另一台，失败项会出现在结果里', () async {
      final a = await newDao();
      final b = await newDao();
      final peerB = await serve(b, 'B');
      // 127.0.0.1:1 几乎必定被拒绝，用来模拟"这台已经关了 App"。
      final deadPeer = Peer(
        deviceId: 'dead-device',
        deviceName: '关掉的平板',
        host: '127.0.0.1',
        port: 1,
        lastSeen: DateTime.now(),
      );

      await a.addTask('A 的');
      final results = await syncMesh(
        dao: a,
        deviceName: 'A',
        collectPeers: (pass) async => pass == 0 ? [peerB, deadPeer] : const [],
      );

      expect(results.length, 2);
      expect(results.where((r) => r.ok).length, 1);
      final failed = results.firstWhere((r) => !r.ok);
      expect(failed.peerName, '关掉的平板');
      expect(titlesOf(await b.visibleTasks()), ['A 的']);
    });
  });
}
