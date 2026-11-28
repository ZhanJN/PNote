@echo off
rem Build PNote for Android (release, arm64). Double-click this file.
rem Optional env: FLUTTER_HOME, ANDROID_HOME, JAVA_HOME, GRADLE_USER_HOME.
setlocal
cd /d "%~dp0"

rem 若 flutter 不在 PATH，先 set FLUTTER_HOME=<Flutter SDK 根目录>
if exist "%FLUTTER_HOME%\bin\flutter.bat" set "PATH=%FLUTTER_HOME%\bin;%PATH%"

if not defined ANDROID_HOME if exist "%LOCALAPPDATA%\Android\Sdk" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not defined ANDROID_HOME if defined ANDROID_SDK_ROOT set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if defined ANDROID_HOME set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
if defined ANDROID_HOME set "PATH=%ANDROID_HOME%\platform-tools;%PATH%"

where flutter >nul 2>nul
if errorlevel 1 (
  echo [FAIL] flutter not found. Set FLUTTER_HOME to your Flutter SDK root.
  pause
  exit /b 1
)
if not defined ANDROID_HOME (
  echo [FAIL] Android SDK not found. Set ANDROID_HOME.
  pause
  exit /b 1
)
if not defined JAVA_HOME (
  echo [WARN] JAVA_HOME is not set; Gradle will look for a JDK by itself.
)

echo Using ANDROID_HOME=%ANDROID_HOME%
if defined JAVA_HOME echo Using JAVA_HOME=%JAVA_HOME%

echo [1/2] flutter pub get
call flutter pub get
if errorlevel 1 goto fail

echo [2/2] flutter build apk --release --target-platform android-arm64
call flutter build apk --release --target-platform android-arm64
if errorlevel 1 goto fail

echo.
echo BUILD OK
echo Output: build\app\outputs\flutter-apk\app-release.apk
echo Next: run install-android.bat with the phone plugged in (USB debugging on)
pause
exit /b 0

:fail
echo.
echo BUILD FAILED - read the messages above.
pause
exit /b 1
