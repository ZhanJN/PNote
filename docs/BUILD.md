# 构建脚本（Windows）

这些 `.bat` 只是双击即用的包装，实际命令见 [README](../README.md)。它们会优先读环境变量，没设时用常见默认值；找不到工具会明确报错，不会静默失败。

| 脚本 | 作用 |
|---|---|
| `run-windows.bat` | 编译（若需要）并启动 Windows 版 |
| `build-windows.bat` | `flutter pub get` + `flutter build windows --release` |
| `build-android.bat` | `flutter pub get` + `flutter build apk --release --target-platform android-arm64` |
| `install-android.bat` | 把 arm64 APK 装到已连接的手机 |
| `pack-release.bat` | 把正式版目录打包成「归档副本」并校验（见 `tool/pack_archive.py`） |

可选环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FLUTTER_HOME` | 无（Flutter 需已在 PATH） | Flutter SDK 根目录 |
| `ANDROID_HOME` | `%LOCALAPPDATA%\Android\Sdk` | Android SDK |
| `JAVA_HOME` | 自动探测 | JDK 17 |
| `GRADLE_USER_HOME` | `%USERPROFILE%\.gradle` | Gradle 缓存（可放别的盘） |
| `FLUTTER_STORAGE_BASE_URL` / `PUB_HOSTED_URL` | 官方源 | 国内可设为 `https://storage.flutter-io.cn` / `https://pub.flutter-io.cn` |

`pack_archive.py` 需要 Python 3.7+，`pack-release.bat` 会依次尝试 `py -3`、`python`。

```bat
set FLUTTER_HOME=E:\flutter
set ANDROID_HOME=E:\Android\Sdk
build-android.bat
```
