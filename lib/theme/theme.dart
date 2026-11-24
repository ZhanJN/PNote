/// 主题定义（1.18 引入，1.19 增加"跟随系统"）。
///
/// 三个选项由用户指定（m04681）：白底黑字 / 黑底白字 / 跟随系统主题颜色。
/// 主题只存在本机 meta 表，**不参与同步、不进备份**：手机选深色不该把
/// 电脑也变黑（见项目说明 7.13）。
library;

import 'package:material_ui/material_ui.dart';

/// 主题偏好在 meta 表里的键。值是 `ThemeMode.name`，即 'light' / 'dark'
/// / 'system'。
const String kThemeModeKey = 'theme_mode';

/// 「减少动效」偏好在 meta 表里的键。值 '1' 表示开启（1.22 新增）。
///
/// 为什么 App 自己也要开关：Android 的系统开关藏在「无障碍 → 视觉 → 移除
/// 动画」，很多 ROM（含 HyperOS）改过位置甚至没有入口；用户找不到时，
/// App 内给一个等价开关最省事（见项目说明 8.4.4）。
const String kReduceMotionKey = 'reduce_motion';

/// 品牌色：一直用这个绿的种子色，深色主题也保留，只是背景变黑。
const Color kSeedColor = Color(0xFF2E6F5E);

/// 1.33：全局字体。西文与中文放在同一个字体里，避免系统回退字体
/// 大小不一致（用户反馈"有的字大有的字小"）。字体随 App 打包，
/// 两端显示一致，不依赖系统装了什么。
const String kFontFamily = 'NotoSansSC';

ThemeData buildLightTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: kSeedColor),
    useMaterial3: true,
    fontFamily: kFontFamily,
  );
}

ThemeData buildDarkTheme() {
  final base = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: kSeedColor,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    fontFamily: kFontFamily,
  );
  // 纯黑背景（OLED 省电、也和用户说的"黑"一致）；卡片/对话框仍用
  // Material 3 的深色表面色，否则一片全黑分不清层次。
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF000000),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: const Color(0xFF000000),
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: const Color(0xFF000000),
    ),
  );
}

/// 把数据库里存的字符串解析成 ThemeMode。
///
/// 没有值、旧值、写坏了 —— 一律回落到"白底黑字"：升级后界面不该突然变样，
/// 也不该被一个坏值弄成打不开。选了"跟随系统"才存 'system'。
ThemeMode parseThemeMode(String? raw) {
  return switch (raw) {
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => ThemeMode.light,
  };
}

/// 解析「减少动效」的存储值：只认 '1' / 'true'，其余（含空值）都是关闭。
bool parseReduceMotion(String? raw) => raw == '1' || raw == 'true';

/// 给界面显示用的名字。用户要求直接写"白底黑字""黑底白字""跟随系统主题颜色"
/// （m04681），不要再加括号解释。
String themeModeLabel(ThemeMode mode) {
  return switch (mode) {
    ThemeMode.dark => '黑底白字',
    ThemeMode.system => '跟随系统主题颜色',
    ThemeMode.light => '白底黑字',
  };
}
