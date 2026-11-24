import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/sync/payload.dart' show kProto;
import 'package:pnote/ui/devices/devices_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.19「连接设备」页：本机信息要给全，没设备时要说人话。
///
/// 这里不传 `SyncService`（sync == null）：真服务要开真实端口、跑真实广播，
/// 在单测里没必要。null 分支正好覆盖"同步没启用"这种真实会出现的状态
/// （比如同步服务启动失败）。页面里有个 1 秒的 Timer 在走字，所以每条用例
/// 结束都要把页面拆掉（pumpWidget(SizedBox.shrink())）并让 dispose 取消它，
/// 否则会报 "A Timer is still pending"。
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late Database db;
  late TaskDao dao;
  final paths = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pnote_devices_');
    final path = '${dir.path}/devices.db';
    paths.add(path);
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    for (final path in paths.reversed) {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    }
    paths.clear();
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }

  Future<void> boot(WidgetTester tester) async {
    // 1.51 加了「账号」行，默认 800×600 会把页面底部的说明挤出视口。
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: DevicesPage(dao: dao)),
    );
    await settleIo(tester);
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> teardownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleIo(tester);
  }

  testWidgets('本机信息齐全：名称、完整设备 ID、系统、端口、协议版本', (tester) async {
    await boot(tester);

    expect(find.text('连接设备'), findsOneWidget);
    // 「本机」出现两次：小节标题 + 设备名称的取值
    expect(find.text('本机'), findsNWidgets(2));
    expect(find.text('设备名称'), findsOneWidget);
    expect(find.text('设备 ID'), findsOneWidget);

    // 完整 ID（不是前 8 位），并且可选中复制
    final deviceId = dao.clock.deviceId;
    expect(find.text(deviceId), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);

    expect(find.text('系统'), findsOneWidget);
    expect(find.text('监听端口'), findsOneWidget);
    expect(
      find.text('发现 UDP 47821 · 同步 未启动'),
      findsOneWidget,
      reason: '没有 SyncService 时同步端口应显示未启动',
    );
    expect(find.text('同步协议'), findsOneWidget);
    // 用常量拼，协议/表结构升版时这条测试不需要跟着改。
    expect(find.text('$kProto · 数据库 schema v$kSchemaVersion'), findsOneWidget);

    await teardownPage(tester);
  });

  testWidgets('没有对端时给出可操作的提示，而不是一片空白', (tester) async {
    await boot(tester);

    expect(find.textContaining('同一局域网内的其它设备（0 台同账号）'), findsOneWidget);
    expect(find.text('同步未启用，看不到其它设备。'), findsOneWidget);

    await teardownPage(tester);
  });

  testWidgets('设备 ID 的说明文案说明了"重装会换新 ID"', (tester) async {
    await boot(tester);

    expect(find.textContaining('重装 App 会换一个新的'), findsOneWidget);
    expect(find.textContaining('不包含任何个人信息'), findsOneWidget);

    await teardownPage(tester);
  });
}
