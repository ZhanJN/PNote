import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/platform/keep_alive.dart';
import 'package:pnote/sync/sync_service.dart';
import 'package:pnote/theme/theme.dart';
import 'package:pnote/theme/theme_controller.dart';
import 'package:pnote/ui/shell/home_page.dart';

/// 应用外壳。只做三件事：主题、把 DAO 与同步服务交给页面，
/// 以及在每次回到前台时确认「后台保活」还在跑（1.16）。
///
/// 为什么要在 resumed 时再确认一次：Android 会在这些情况下把前台服务收走 ——
/// 系统内存紧张、Android 15 对 dataSync 类型有每日累计时长上限、用户点了
/// 通知上的「暂停后台同步」、或小米的省电策略把它清掉。服务没了的后果是
/// 「电脑按同步一直超时」，但界面上看不出来。回到前台时补一次是最省事、
/// 也最不容易漏的修法（启动时 main.dart 已经调过一次）。
class PNoteApp extends StatefulWidget {
  const PNoteApp({
    super.key,
    required this.dao,
    this.sync,
    this.initialThemeMode = ThemeMode.light,
    this.initialReduceMotion = false,
  });

  final TaskDao dao;
  final SyncService? sync;

  /// 启动前从数据库读出来的主题；读不到就是浅色（见 main.dart）。
  final ThemeMode initialThemeMode;

  /// 启动前从数据库读出来的「减少动效」；读不到就是关闭（1.22）。
  final bool initialReduceMotion;

  @override
  State<PNoteApp> createState() => _PNoteAppState();
}

class _PNoteAppState extends State<PNoteApp> with WidgetsBindingObserver {
  late final ThemeController _theme = ThemeController(
    dao: widget.dao,
    initialMode: widget.initialThemeMode,
    initialReduceMotion: widget.initialReduceMotion,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _theme.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && BackgroundKeepAlive.isSupported) {
      // 失败也没关系：下一次回到前台还会再试，而且前台使用不受影响。
      unawaited(BackgroundKeepAlive.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    // ThemeScope 放在 MaterialApp 外面：设置页是 push 出来的路由，
    // 路由的 context 在 MaterialApp 之内，只有挂在外面才找得到。
    return ThemeScope(
      controller: _theme,
      child: AnimatedBuilder(
        animation: _theme,
        builder: (context, _) {
          return MaterialApp(
            title: 'PNote',
            debugShowCheckedModeBanner: false,
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: _theme.mode,
            // 1.22：「减少动效」既认系统开关（无障碍里的"移除动画"），也认
            // App 内的开关。两者只要有一个是真就关掉装饰动画 —— 系统的
            // disableAnimations 在各家 ROM 上位置不固定，App 自己给一个
            // 兜底入口（见设置页「减少动效」）。
            builder: (context, child) {
              var data = MediaQuery.of(context);
              // 1.36：内置思源黑体的字面比系统字体略靠下、视觉上偏大，手机
              // 上把整体字号缩 5%，字与格子更贴合（桌面保持原样）。这里乘
              // 在系统字号之上，所以用户自己调大字体仍然生效。
              if (defaultTargetPlatform == TargetPlatform.android) {
                final factor = data.textScaler.scale(1.0) * 0.95;
                data = data.copyWith(textScaler: TextScaler.linear(factor));
              }
              if (data.disableAnimations || _theme.reduceMotion) {
                data = data.copyWith(disableAnimations: true);
              }
              return MediaQuery(
                data: data,
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: HomePage(dao: widget.dao, sync: widget.sync),
          );
        },
      ),
    );
  }
}

/// 启动失败时的兜底页面：把原始错误显示出来，而不是白屏。
/// 阶段 1 排查问题全靠它，不要删。
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                const Text('数据库打不开'),
                const SizedBox(height: 8),
                SelectableText('$error', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
