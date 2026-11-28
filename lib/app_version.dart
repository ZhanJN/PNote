/// 应用版本号：只在这里维护，必须与 pubspec.yaml 的 `version:` 一致。
///
/// 过去「设置 → 关于」里的版本号是写死的字符串，升版本时两次忘记改，用户看到的
/// 是旧版本号。这里独立成常量，并由 test/app_version_test.dart 对照 pubspec.yaml
/// 校验，漏改会让测试变红。
const String kAppVersion = '1.65.2';
const int kAppBuildNumber = 16502;

/// 展示用文案，例如 `v1.65.2 (16502)`。
String get kAppVersionLabel => 'v$kAppVersion ($kAppBuildNumber)';
