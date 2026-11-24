import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_sync.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/mesh.dart';
import 'package:pnote/sync/peer.dart';
import 'package:pnote/sync/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 端到端：两台设备（各自一个笔记库 + 一个数据库）通过真 WebSocket 交换
/// 笔记与附件 —— 对应《PNote项目说明》9.31 的验收步骤。
void main() {
  setUpAll(sqfliteFfiInit);

  final dbs = <Database>[];
  final dirs = <Directory>[];
  final servers = <SyncServer>[];

  Future<TaskDao> newDao() async {
    final path = p.join(
      Directory.systemTemp.path,
      'pnote_notessync_${DateTime.now().microsecondsSinceEpoch}_${dbs.length}.db',
    );
    final db = await openAppDatabase(overridePath: path);
    dbs.add(db);
    return TaskDao.attach(db);
  }

  Directory newLibrary() {
    final dir = Directory.systemTemp.createTempSync('pnote_lib_');
    dirs.add(dir);
    return dir;
  }

  NotesSync newNotesSync(Directory root, TaskDao dao, {int? clockSeed}) =>
      NotesSync(
        clock: clockSeed == null
            ? dao.clock
            : HlcClock(deviceId: dao.clock.deviceId, lastMs: clockSeed),
        persistClock: () async {},
        rootOf: () async => root,
      );

  File writeInto(Directory root, String rel, String content) {
    final file = File(p.join(root.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  tearDown(() async {
    for (final server in servers) {
      await server.stop();
    }
    servers.clear();
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
    for (final dir in dirs) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上句柄可能还没释放，临时目录残留不影响结果。
      }
    }
    dirs.clear();
  });

  test('A 的新笔记与附件能同步到 B，B 的改动也能回到 A', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    final rootA = newLibrary();
    final rootB = newLibrary();
    final notesA = newNotesSync(rootA, daoA);
    final notesB = newNotesSync(rootB, daoB);

    // B 侧开服务端，带笔记通道。
    final server = SyncServer(
      deviceId: daoB.clock.deviceId,
      onRemoteState: (remote) async {
        await daoB.applyRemote(remote);
        return daoB.exportState(deviceName: 'B');
      },
      notes: notesB.toChannel(),
    );
    await server.start();
    servers.add(server);
    final peerB = Peer(
      deviceId: daoB.clock.deviceId,
      deviceName: 'B',
      host: '127.0.0.1',
      port: server.boundPort!,
      lastSeen: DateTime.now(),
    );

    // A 上写一篇笔记 + 一个附件（图片用假字节，同步不看内容格式）。
    writeInto(rootA, '2026/11/2026-11-24 0100 白板复盘.md', '# 白板复盘\n\n- 三件事');
    final png = File(p.join(rootA.path, '2026/11/2026-11-24 0100 白板复盘.assets/白板.png'));
    png.parent.createSync(recursive: true);
    png.writeAsBytesSync(List<int>.generate(64, (i) => i));

    final first = await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    expect(first.ok, isTrue, reason: first.message);
    expect(first.notes, isNotNull);
    // A 是发送方，自己没拉取内容；B 那边应该收到了 2 个文件。
    expect(File(p.join(rootB.path, '2026/11/2026-11-24 0100 白板复盘.md')).existsSync(), isTrue);
    expect(
      File(p.join(rootB.path, '2026/11/2026-11-24 0100 白板复盘.assets/白板.png'))
          .readAsBytesSync()
          .length,
      64,
    );

    // B 改这篇笔记（版本更新），A 再同步一次应该拿到 B 的版本。
    final onB = File(p.join(rootB.path, '2026/11/2026-11-24 0100 白板复盘.md'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    onB.writeAsStringSync('# 白板复盘\n\n- B 改的两件事');

    final second = await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    expect(second.ok, isTrue, reason: second.message);
    expect(second.notes!.written, 1);
    expect(
      File(p.join(rootA.path, '2026/11/2026-11-24 0100 白板复盘.md')).readAsStringSync(),
      '# 白板复盘\n\n- B 改的两件事',
    );
  });

  test('A 删掉的笔记会在 B 上进 .trash（不是无声消失）', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    final rootA = newLibrary();
    final rootB = newLibrary();
    final notesA = newNotesSync(rootA, daoA);
    final notesB = newNotesSync(rootB, daoB);

    final server = SyncServer(
      deviceId: daoB.clock.deviceId,
      onRemoteState: (remote) async {
        await daoB.applyRemote(remote);
        return daoB.exportState(deviceName: 'B');
      },
      notes: notesB.toChannel(),
    );
    await server.start();
    servers.add(server);
    final peerB = Peer(
      deviceId: daoB.clock.deviceId,
      deviceName: 'B',
      host: '127.0.0.1',
      port: server.boundPort!,
      lastSeen: DateTime.now(),
    );

    writeInto(rootA, '2026/11/x.md', '# x');
    await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    expect(File(p.join(rootB.path, '2026/11/x.md')).existsSync(), isTrue);

    // A 删掉文件，再同步：墓碑要传过去。
    File(p.join(rootA.path, '2026/11/x.md')).deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    expect(second.ok, isTrue, reason: second.message);
    expect(File(p.join(rootB.path, '2026/11/x.md')).existsSync(), isFalse);
    final trash = Directory(p.join(rootB.path, '.trash'))
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(trash.length, 1);
    expect(trash.single.readAsStringSync(), '# x');
  });

  test('A 把回收站清空后，B 的回收站里那份也跟着消失（1.49）', () async {
    final daoA = await newDao();
    final daoB = await newDao();
    final rootA = newLibrary();
    final rootB = newLibrary();
    final notesA = newNotesSync(rootA, daoA);
    final notesB = newNotesSync(rootB, daoB);

    final server = SyncServer(
      deviceId: daoB.clock.deviceId,
      onRemoteState: (remote) async {
        await daoB.applyRemote(remote);
        return daoB.exportState(deviceName: 'B');
      },
      notes: notesB.toChannel(),
    );
    await server.start();
    servers.add(server);
    final peerB = Peer(
      deviceId: daoB.clock.deviceId,
      deviceName: 'B',
      host: '127.0.0.1',
      port: server.boundPort!,
      lastSeen: DateTime.now(),
    );

    writeInto(rootA, '2026/11/y.md', '# y');
    await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );

    // A 删掉它 → B 的回收站里出现一份。
    File(p.join(rootA.path, '2026/11/y.md')).deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    List<File> trashOf(Directory root) {
      final dir = Directory(p.join(root.path, '.trash'));
      if (!dir.existsSync()) return const [];
      return dir.listSync(recursive: true).whereType<File>().toList();
    }

    expect(trashOf(rootB).length, 1);

    // A 在回收站里「彻底删除」：文件早已不在，只留暂存清单 → 下一趟同步带上 purged。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    File(p.join(rootA.path, kPurgeQueueFileName))
        .writeAsStringSync('["y.md"]');
    final third = await exchangeWithDao(
      dao: daoA,
      deviceName: 'A',
      peer: peerB,
      notes: notesA.toChannel(),
    );
    expect(third.ok, isTrue, reason: third.message);
    expect(trashOf(rootB), isEmpty, reason: 'B 的回收站副本应该被彻底删掉');
  });
}
