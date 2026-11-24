import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/payload.dart';

TaskState sampleTask() => TaskState(
      id: '11111111-1111-4111-8111-111111111111',
      createdAt: 1700000000000,
      fields: {
        TaskField.title: FieldValue('买菜', const Hlc(1700000000001, 0, 'dev-A')),
        TaskField.done: FieldValue(1, const Hlc(1700000000002, 0, 'dev-A')),
      },
    );

void main() {
  test('编解码往返：任务、值、版本都还在', () {
    final state = SyncState(
      deviceId: 'dev-A',
      deviceName: '电脑',
      tasks: {sampleTask().id: sampleTask()},
    );

    final raw = encodeState(state, sentAt: DateTime.fromMillisecondsSinceEpoch(1700000000999));
    final back = decodeState(raw);

    expect(back.deviceId, 'dev-A');
    expect(back.deviceName, '电脑');
    expect(back.tasks.length, 1);
    final t = back.tasks.values.first;
    expect(t.title, '买菜');
    expect(t.done, isTrue);
    expect(t.fields[TaskField.title]!.hlc.ms, 1700000000001);
    expect(t.fields[TaskField.title]!.hlc.deviceId, 'dev-A');
  });

  test('协议版本不符必须报错，不能"尽力解析"', () {
    final bad = '{"proto":"pnote-sync/9","type":"state","deviceId":"x","tasks":[]}';
    expect(() => decodeState(bad), throwsA(isA<PayloadException>()));
  });

  test('不是 JSON 必须报错', () {
    expect(() => decodeState('这不是json'), throwsA(isA<PayloadException>()));
  });

  test('任务 ID 重复必须报错', () {
    final t = sampleTask();
    final raw = '{"proto":"$kProto","type":"state","deviceId":"d","tasks":'
        '[${_jsonOf(t)},${_jsonOf(t)}]}';
    expect(() => decodeState(raw), throwsA(isA<PayloadException>()));
  });
}

String _jsonOf(TaskState t) {
  // 借助 encodeState 生成单任务 JSON 片段，避免手写字符串出错。
  final single = SyncState(deviceId: 'd', deviceName: 'n', tasks: {t.id: t});
  final full = encodeState(single);
  final start = full.indexOf('"tasks":[') + '"tasks":['.length;
  final end = full.lastIndexOf(']}');
  return full.substring(start, end);
}
