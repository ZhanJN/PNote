import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/theme/theme.dart';
import 'package:pnote/theme/theme_controller.dart';
import 'package:pnote/ui/shell/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.18 设置页：齿轮能进、黑白色能切、切完能存住。
///
/// 两个刻意的写法：
///  1. `ThemeScope` 在 `MaterialApp` 外面，和 app.dart 一致 —— 否则设置页的
///     `ThemeScope.of(context)` 取不到控制器（"单测过、真机白屏"的常见来源）。
///  2. **不用 `pumpAndSettle`**：待办首次加载会转圈（`CircularProgressIndicator`
///     永远在动），而真实 sqflite I/O 在 FakeAsync 下不会自己完成，
///     `pumpAndSettle` 必然超时。改用 `settleIo`（runAsync 让真异步跑完）+ 定长 pump。
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late Database db;
  late TaskDao dao;
  final paths = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pnote_settings_');
    final path = '${dir.path}/settings.db';
    paths.add(path);
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
    // 首页会同时建好笔记页，它会扫一遍库；指到临时目录，别碰真实文档目录。
    setNotesRootOverride(dir);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    await db.close();
    for (final path in paths.reversed) {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {
            // Windows 上偶尔删不掉；下次用唯一文件名，不影响结论。
          }
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

  Widget harness(ThemeController controller) {
    return ThemeScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => MaterialApp(
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: controller.mode,
          home: HomePage(dao: dao),
        ),
      ),
    );
  }

  /// 让真实 IO 跑完，再把结果 pump 到界面上。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }

  Future<void> boot(WidgetTester tester, ThemeController controller) async {
    await tester.pumpWidget(harness(controller));
    await settleIo(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settleIo(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> teardownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleIo(tester);
  }

  testWidgets('顶栏最右边有齿轮，点开能进设置页', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    expect(find.byTooltip('设置'), findsOneWidget);

    await tapAndWait(tester, find.byTooltip('设置'));

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('白底黑字'), findsOneWidget);
    expect(find.text('黑底白字'), findsOneWidget);
    expect(find.text('跟随系统主题颜色'), findsOneWidget);
    // 1.41 多了「笔记」一节，关于被挤到首屏外，先滚下去再断言。
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(find.text('关于'), findsOneWidget);

    await teardownPage(tester);
  });

  testWidgets('在笔记页签也能进设置（齿轮常驻）', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    await tapAndWait(tester, find.text('笔记'));
    expect(find.byTooltip('设置'), findsOneWidget);
    // 回收站两个页签都在（1.45 统一回收站）；导出/导入仍只属于待办。
    expect(find.byTooltip('回收站'), findsOneWidget);
    expect(find.byTooltip('导出备份'), findsNothing);

    await tapAndWait(tester, find.byTooltip('设置'));
    expect(find.text('外观'), findsOneWidget);

    await teardownPage(tester);
  });

  testWidgets('选深色后立即变深色，并且写进数据库', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    await tapAndWait(tester, find.byTooltip('设置'));
    await tapAndWait(tester, find.text('黑底白字'));

    expect(controller.mode, ThemeMode.dark);
    // 亮度来自 MaterialApp 的 themeMode，检查它的实际效果
    final ctx = tester.element(find.text('设置'));
    expect(Theme.of(ctx).brightness, Brightness.dark);
    expect(
      Theme.of(ctx).scaffoldBackgroundColor,
      const Color(0xFF000000),
      reason: '深色主题用纯黑背景',
    );

    final stored = await tester.runAsync(() => dao.readSetting(kThemeModeKey));
    expect(stored, 'dark');

    await teardownPage(tester);
  });

  testWidgets('存过的深色在下一次启动时被读回来', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);
    await tapAndWait(tester, find.byTooltip('设置'));
    await tapAndWait(tester, find.text('黑底白字'));

    // 模拟重启：按 main.dart 的做法从库里读一遍
    final raw = await tester.runAsync(() => dao.readSetting(kThemeModeKey));
    expect(parseThemeMode(raw), ThemeMode.dark);
    expect(themeModeLabel(ThemeMode.dark), '黑底白字');

    // 用读回来的值新建一个控制器，界面应当是深色
    final restarted = ThemeController(
      dao: dao,
      initialMode: parseThemeMode(raw),
    );
    await teardownPage(tester);
    await boot(tester, restarted);
    final ctx = tester.element(find.text('PNote'));
    expect(Theme.of(ctx).brightness, Brightness.dark);

    await teardownPage(tester);
  });

  testWidgets('库里是坏值时不崩，回落到浅色', (tester) async {
    expect(parseThemeMode(null), ThemeMode.light);
    expect(parseThemeMode(''), ThemeMode.light);
    expect(parseThemeMode('purple'), ThemeMode.light);
    expect(parseThemeMode('light'), ThemeMode.light);
    expect(parseThemeMode('dark'), ThemeMode.dark);
  });

  testWidgets('可以选「跟随系统主题颜色」，并且存成 system', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    await tapAndWait(tester, find.byTooltip('设置'));
    await tapAndWait(tester, find.text('跟随系统主题颜色'));

    expect(controller.mode, ThemeMode.system);
    final stored = await tester.runAsync(() => dao.readSetting(kThemeModeKey));
    expect(stored, 'system');
    expect(parseThemeMode(stored), ThemeMode.system);
    expect(themeModeLabel(ThemeMode.system), '跟随系统主题颜色');

    await teardownPage(tester);
  });

  testWidgets('关于里的「连接设备」能进二级页，并显示本机设备 ID', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    await tapAndWait(tester, find.byTooltip('设置'));
    // 1.36 起设置页多了「任务」一节，关于里的入口落在首屏外，先滚下去。
    await tester.scrollUntilVisible(
      find.text('连接设备'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(find.text('连接设备'), findsOneWidget);
    await tapAndWait(tester, find.text('连接设备'));

    // 进了二级页：标题 + 本机设备 ID（完整）
    expect(find.text('连接设备'), findsOneWidget);
    expect(find.text('设备 ID'), findsOneWidget);
    expect(find.text(dao.clock.deviceId), findsOneWidget);

    await teardownPage(tester);
  });

  testWidgets('打开「减少动效」→ 控制器生效、写进库里、重启后仍开着', (tester) async {
    final controller = ThemeController(dao: dao, initialMode: ThemeMode.light);
    await boot(tester, controller);

    await tapAndWait(tester, find.byTooltip('设置'));
    expect(find.text('减少动效'), findsOneWidget);

    // 1.36 起页面上有两个 SwitchListTile，按标题点，别用 find.byType(Switch)。
    await tapAndWait(tester, find.text('减少动效'));

    expect(controller.reduceMotion, isTrue);
    final stored = await tester.runAsync(() => dao.readSetting(kReduceMotionKey));
    expect(stored, '1');
    // 模拟重启：main.dart 用这个解析函数
    expect(parseReduceMotion(stored), isTrue);
    expect(parseReduceMotion(null), isFalse);

    await teardownPage(tester);

    final restarted = ThemeController(
      dao: dao,
      initialMode: ThemeMode.light,
      initialReduceMotion: parseReduceMotion(stored),
    );
    expect(restarted.reduceMotion, isTrue);
    await boot(tester, restarted);
    await tapAndWait(tester, find.byTooltip('设置'));
    final sw = tester.widget<SwitchListTile>(
      find.ancestor(of: find.text('减少动效'), matching: find.byType(SwitchListTile)),
    );
    expect(sw.value, isTrue);

    await teardownPage(tester);
  });
}
