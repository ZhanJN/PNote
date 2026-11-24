import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/merge.dart';

/// 构造一个字段值：fv(值, 毫秒, 计数器, 设备)。
FieldValue fv(Object? value, int ms, int c, [String dev = 'dev-A']) =>
    FieldValue(value, Hlc(ms, c, dev));

/// 构造一个任务：[fields] 直接给字段版本。
TaskState task(
  String id, {
  int createdAt = 100,
  Map<TaskField, FieldValue>? fields,
}) =>
    TaskState(id: id, createdAt: createdAt, fields: fields ?? const {});

SyncState state(String device, List<TaskState> tasks) => SyncState(
      deviceId: device,
      deviceName: device,
      tasks: {for (final t in tasks) t.id: t},
    );

void main() {
  const id = '11111111-1111-4111-8111-111111111111';

  test('TC-01 远端新增的任务会出现在合并结果里', () {
    final local = state('A', []);
    final remote = state('B', [
      task(id, fields: {
        TaskField.title: fv('买菜', 100, 0, 'B'),
        TaskField.done: fv(0, 100, 1, 'B'),
      }),
    ]);

    final out = mergeStates(local, remote);
    expect(out.merged.tasks.keys, contains(id));
    expect(out.merged.tasks[id]!.title, '买菜');
    expect(out.stats.addedTasks, 1);
  });

  test('TC-02 同一字段：HLC 大的胜（远端更新）', () {
    final local = state('A', [
      task(id, fields: {TaskField.title: fv('旧标题', 100, 0)}),
    ]);
    final remote = state('B', [
      task(id, fields: {TaskField.title: fv('新标题', 200, 0, 'B')}),
    ]);

    final out = mergeStates(local, remote);
    expect(out.merged.tasks[id]!.title, '新标题');
    expect(out.stats.updatedFields, 1);
  });

  test('TC-03 同一字段：本地更新的不被覆盖', () {
    final local = state('A', [
      task(id, fields: {TaskField.title: fv('我更新', 300, 0)}),
    ]);
    final remote = state('B', [
      task(id, fields: {TaskField.title: fv('他更新', 200, 0, 'B')}),
    ]);

    final out = mergeStates(local, remote);
    expect(out.merged.tasks[id]!.title, '我更新');
    expect(out.stats.updatedFields, 0);
  });

  test('TC-04 不同字段互不干扰：一个任务同时被改名和勾选', () {
    final local = state('A', [
      task(id, fields: {
        TaskField.title: fv('改名后', 300, 0),
        TaskField.done: fv(0, 100, 0),
      }),
    ]);
    final remote = state('B', [
      task(id, fields: {
        TaskField.title: fv('旧名', 100, 0, 'B'),
        TaskField.done: fv(1, 200, 0, 'B'),
      }),
    ]);

    final merged = mergeStates(local, remote).merged.tasks[id]!;
    expect(merged.title, '改名后');
    expect(merged.done, isTrue);
  });

  test('TC-05 删除墓碑会传播过去，且不会把任务"复活"', () {
    final local = state('A', [
      task(id, fields: {
        TaskField.title: fv('跑步', 100, 0),
        TaskField.deletedAt: fv(150, 150, 0),
      }),
    ]);
    final remote = state('B', [
      task(id, fields: {
        TaskField.title: fv('跑步', 100, 0, 'B'),
      }),
    ]);

    final out = mergeStates(remote, local); // 本地是 B，收到 A 的墓碑
    final merged = out.merged.tasks[id]!;
    expect(merged.isDeleted, isTrue);
    expect(out.stats.deletedTasks, 1);
  });

  test('TC-06 一端删除、另一端之后改标题：仍然保持删除状态', () {
    // A 在 150 删除；B 在 900（更晚）改标题。字段不同，因此不构成冲突：
    // title 取 B 的新值，deleted_at 仍然有值 -> 任务依旧不可见。
    final afterDelete = state('A', [
      task(id, fields: {
        TaskField.title: fv('跑步', 100, 0),
        TaskField.deletedAt: fv(150, 150, 0),
      }),
    ]);
    final laterRename = state('B', [
      task(id, fields: {
        TaskField.title: fv('跑步 5 公里', 900, 0, 'B'),
        TaskField.done: fv(0, 100, 1, 'B'),
      }),
    ]);

    final merged = mergeStates(afterDelete, laterRename).merged.tasks[id]!;
    expect(merged.title, '跑步 5 公里'); // 标题确实更新了
    expect(merged.isDeleted, isTrue); // 但仍然不可见
  });

  test('TC-07 幂等：把同一远端再合并一次不会产生任何变化', () {
    final local = state('A', [
      task(id, fields: {TaskField.title: fv('甲', 100, 0)}),
    ]);
    final remote = state('B', [
      task(id, fields: {TaskField.title: fv('乙', 200, 0, 'B')}),
      task('22222222-2222-4222-8222-222222222222', fields: {
        TaskField.title: fv('新增', 300, 0, 'B'),
      }),
    ]);

    final once = mergeStates(local, remote).merged;
    final twice = mergeStates(once, remote);
    expect(twice.stats.isNoop, isTrue);
    expect(twice.merged.tasks[id]!.title, '乙');
  });

  test('TC-08 交换律：merge(a,b) 与 merge(b,a) 数据一致', () {
    final a = state('A', [
      task(id, fields: {TaskField.title: fv('甲', 100, 0)}),
      task('33333333-3333-4333-8333-333333333333', fields: {
        TaskField.title: fv('只有 A 有', 100, 0),
      }),
    ]);
    final b = state('B', [
      task(id, fields: {TaskField.title: fv('乙', 200, 0, 'B')}),
      task('44444444-4444-4444-8444-444444444444', fields: {
        TaskField.title: fv('只有 B 有', 100, 0, 'B'),
      }),
    ]);

    final ab = mergeStates(a, b).merged;
    final ba = mergeStates(b, a).merged;

    expect(ab.tasks.length, ba.tasks.length);
    for (final id in ab.tasks.keys) {
      expect(ab.tasks[id]!.title, ba.tasks[id]!.title, reason: '任务 $id 不一致');
      expect(ab.tasks[id]!.done, ba.tasks[id]!.done, reason: '任务 $id 完成态不一致');
      expect(ab.tasks[id]!.isDeleted, ba.tasks[id]!.isDeleted);
    }
  });

  test('TC-09 完全相同 HLC 时由 deviceId 决出胜者（不会随机）', () {
    final local = state('A', [
      task(id, fields: {TaskField.title: fv('A 的', 500, 0, 'dev-A')}),
    ]);
    final remote = state('B', [
      task(id, fields: {TaskField.title: fv('B 的', 500, 0, 'dev-B')}),
    ]);

    final ab = mergeStates(local, remote).merged.tasks[id]!.title;
    final ba = mergeStates(remote, local).merged.tasks[id]!.title;
    expect(ab, 'B 的'); // 'dev-B' > 'dev-A'
    expect(ba, ab);
  });

  test('TC-10 两侧各自独有的任务都会保留', () {
    const other = '55555555-5555-4555-8555-555555555555';
    final local = state('A', [
      task(id, fields: {TaskField.title: fv('本地独有', 100, 0)}),
    ]);
    final remote = state('B', [
      task(other, fields: {TaskField.title: fv('远端独有', 100, 0, 'B')}),
    ]);

    final merged = mergeStates(local, remote).merged;
    expect(merged.tasks.keys, containsAll([id, other]));
    expect(merged.visibleTasks.length, 2);
  });
}
