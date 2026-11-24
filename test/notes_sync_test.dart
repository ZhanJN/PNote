import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_sync.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/notes_channel.dart';

/// 笔记同步的「文件那一侧」：打版本、判胜负、落删除。
///
/// 这些用例不碰网络，只碰两个临时目录 —— 网络那一段由
/// test/sync_notes_roundtrip_test.dart 覆盖。
void main() {
  late Directory root;
  late HlcClock clock;
  var persisted = 0;

  NotesSync makeSync() => NotesSync(
        clock: clock,
        persistClock: () async => persisted++,
        rootOf: () async => root,
      );

  File write(String rel, String content) {
    final file = File(p.join(root.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('pnote_notesync_');
    clock = HlcClock(deviceId: 'devA');
    persisted = 0;
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('第一次扫描给每个文件打版本，再次扫描不变就不动版本', () async {
    write('2026/11/a.md', '# a');
    write('2026/11/a.md.assets/x.png', 'PNG');

    final sync = makeSync();
    final first = await sync.scan();
    expect(first.files.keys.toList()..sort(),
        ['2026/11/a.md', '2026/11/a.md.assets/x.png']);
    final ip = first.files['2026/11/a.md']!.hlc;

    final second = await sync.scan();
    expect(second.files['2026/11/a.md']!.hlc, ip,
        reason: '内容没变，版本不应该推进');
  });

  test('改了内容才推进版本，并记住新的指纹', () async {
    write('2026/11/a.md', '# a');
    final sync = makeSync();
    final first = await sync.scan();
    final before = first.files['2026/11/a.md']!;

    write('2026/11/a.md', '# a\n\n改过了');
    final second = await sync.scan();
    final after = second.files['2026/11/a.md']!;

    expect(after.hlc > before.hlc, isTrue);
    expect(after.sha, isNot(before.sha));
  });

  test('删掉文件留下墓碑，且不会在下一轮被自己复活', () async {
    final file = write('2026/11/a.md', '# a');
    final sync = makeSync();
    await sync.scan();

    file.deleteSync();
    final state = await sync.scan();
    expect(state.files.containsKey('2026/11/a.md'), isFalse);
    expect(state.deleted.containsKey('2026/11/a.md'), isTrue);

    final again = await sync.scan();
    expect(again.deleted.containsKey('2026/11/a.md'), isTrue);
    expect(again.files, isEmpty);
  });

  test('.trash 与点文件不参与同步', () async {
    write('.trash/2026-11-24 0100/a.md', '# 删掉的');
    write('.order.json', '{}');
    write('2026/11/b.md', '# b');

    final state = await makeSync().scan();
    expect(state.files.keys.toList(), ['2026/11/b.md']);
  });

  test('wantFrom 只挑「远端更新或本机没有」的路径', () {
    final older = Hlc(100, 0, 'x');
    final newer = Hlc(200, 0, 'x');
    final local = NotesSyncState(files: {
      'same.md': NoteVersion(hlc: newer, sha: 's', size: 1),
      'stale.md': NoteVersion(hlc: older, sha: 's', size: 1),
    }, deleted: {
      'gone.md': newer,
    });
    final remote = NotesSyncState(files: {
      'same.md': NoteVersion(hlc: older, sha: 's', size: 1),
      'stale.md': NoteVersion(hlc: newer, sha: 's', size: 1),
      'new.md': NoteVersion(hlc: older, sha: 's', size: 1),
      'gone.md': NoteVersion(hlc: older, sha: 's', size: 1),
    });

    expect(local.wantFrom(remote), ['new.md', 'stale.md']);
  });

  test('应用远端内容：新的覆盖旧的，旧的被跳过', () async {
    write('2026/11/a.md', '本地版');
    final sync = makeSync();
    await sync.scan();
    final local = await sync.readState();
    final localHlc = local.files['2026/11/a.md']!.hlc;

    final oldBlob = NoteBlob(
      path: '2026/11/a.md',
      hlc: Hlc(localHlc.ms - 1000, 0, 'devB'),
      sha: 'x',
      bytes: utf8.encode('远端旧版'),
    );
    final skip = await sync.apply(const NotesSyncState(), [oldBlob]);
    expect(skip.skippedOld, 1);
    expect(File(p.join(root.path, '2026/11/a.md')).readAsStringSync(), '本地版');

    final newBlob = NoteBlob(
      path: '2026/11/a.md',
      hlc: Hlc(localHlc.ms + 1000, 0, 'devB'),
      sha: 'y',
      bytes: utf8.encode('远端新版'),
    );
    final report = await sync.apply(const NotesSyncState(), [newBlob]);
    expect(report.written, 1);
    expect(File(p.join(root.path, '2026/11/a.md')).readAsStringSync(), '远端新版');

    final after = await sync.readState();
    expect(after.files['2026/11/a.md']!.sha, fnv1a64(utf8.encode('远端新版')));
  });

  test('远端的删除会把文件挪进 .trash，而不是直接抹掉', () async {
    write('2026/11/a.md', '# a');
    final sync = makeSync();
    await sync.scan();

    final mine = (await sync.readState()).files['2026/11/a.md']!;
    final tomb = Hlc(mine.hlc.ms + 500, 0, 'devB');
    final report = await sync.apply(
      NotesSyncState(deleted: {'2026/11/a.md': tomb}),
      const [],
    );

    expect(report.deleted, 1);
    expect(File(p.join(root.path, '2026/11/a.md')).existsSync(), isFalse);
    final trashed = Directory(p.join(root.path, '.trash'))
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(trashed.length, 1);
    expect(trashed.single.readAsStringSync(), '# a');
  });

  test('.sync.json 坏掉时按「没有版本」处理，库仍能打开', () async {
    write('2026/11/a.md', '# a');
    File(p.join(root.path, kSyncStateFileName)).writeAsStringSync('{ 坏掉的');

    final sync = makeSync();
    final state = await sync.readState();
    expect(state.files, isEmpty);

    final scanned = await sync.scan();
    expect(scanned.files.containsKey('2026/11/a.md'), isTrue);
  });

  test('扫描会推进时钟并落库（persistClock 被调用）', () async {
    write('2026/11/a.md', '# a');
    final sync = makeSync();
    await sync.scan();
    expect(persisted, greaterThan(0));

    final before = persisted;
    await sync.scan();
    expect(persisted, before, reason: '没有变化就不该再写时钟');
  });

  test('彻底删除的暂存清单会变成 purged 记录，并清掉同名墓碑（1.49）', () async {
    write('2026/11/2026-11-24 0200 a.md', '# a');
    final sync = makeSync();
    await sync.scan();

    // 模拟「回收站里彻底删除」：文件已经没了，只留下暂存清单。
    File(p.join(root.path, '2026/11/2026-11-24 0200 a.md')).deleteSync();
    File(p.join(root.path, kPurgeQueueFileName))
        .writeAsStringSync(jsonEncode(['2026-11-24 0200 a.md']));

    final state = await sync.scan();
    expect(state.purged.keys, contains('2026-11-24 0200 a.md'));
    expect(state.deleted, isEmpty, reason: '彻底删了就不该再留一条「进回收站」的墓碑');
    expect(File(p.join(root.path, kPurgeQueueFileName)).existsSync(), isFalse,
        reason: '清单读一次就删掉，别重复处理');
  });

  test('对端彻底删除后，本机的正文与回收站副本一起消失（1.49）', () async {
    write('2026/11/2026-11-24 0200 a.md', '# a');
    write('2026/11/2026-11-24 0200 a.assets/图.png', 'PNG');
    final sync = makeSync();
    await sync.scan();

    // 先模拟「本机也删过它」：挪进回收站。
    final stamp = Hlc(DateTime.now().millisecondsSinceEpoch + 1000, 0, 'devB');
    await sync.apply(
      NotesSyncState(deleted: {'2026/11/2026-11-24 0200 a.md': stamp}),
      const [],
    );
    expect(
      Directory(p.join(root.path, '.trash')).existsSync(),
      isTrue,
      reason: '前置条件：回收站里应该有一份',
    );

    final purge = Hlc(stamp.ms + 1000, 0, 'devB');
    final report = await sync.apply(
      NotesSyncState(purged: {'2026-11-24 0200 a.md': purge}),
      const [],
    );

    expect(report.purged, 1);
    final left = Directory(root.path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('2026-11-24 0200 a'))
        .toList();
    expect(left, isEmpty, reason: '正文、素材、回收站副本都应该没了');
    expect((await sync.readState()).purged.keys, contains('2026-11-24 0200 a.md'));
  });

  test('彻底删除过的路径不会再被 wantFrom 拉回来（1.49）', () {
    final state = NotesSyncState(purged: {'a.md': Hlc(100, 0, 'devA')});
    final remote = NotesSyncState(
      files: {'2026/11/a.md': NoteVersion(hlc: Hlc(90, 0, 'devB'), sha: 'x', size: 1)},
    );
    expect(state.wantFrom(remote), isEmpty);
    expect(remote.wantFrom(state), isEmpty, reason: '对端的彻底删除同样拦住拉取');
  });
}
