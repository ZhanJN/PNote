@echo off
rem Install the arm64 release APK onto a phone connected by USB (USB debugging on).
rem Optional env: ANDROID_HOME.
setlocal
cd /d "%~dp0"

if not defined ANDROID_HOME if exist "%LOCALAPPDATA%\Android\Sdk" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not defined ANDROID_HOME if defined ANDROID_SDK_ROOT set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if not defined ANDROID_HOME (
  echo [FAIL] Android SDK not found. Set ANDROID_HOME.
  pause
  exit /b 1
)

set "ADB=%ANDROID_HOME%\platform-tools\adb.exe"
if not exist "%ADB%" (
  echo [FAIL] adb not found: %ADB%
  pause
  exit /b 1
)

set "APK=build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
if not exist "%APK%" goto noapk

echo [1/2] adb devices
"%ADB%" devices
echo.
echo If the list above is empty, plug the phone in and allow USB debugging on it.
pause

echo [2/2] adb install -r "%APK%"
"%ADB%" install -r "%APK%"
if errorlevel 1 goto fail

echo.
echo INSTALL OK - look for the PNote icon on the phone.
pause
exit /b 0

:noapk
echo %APK% not found. Run build-android.bat first.
pause
exit /b 1

:fail
echo.
echo INSTALL FAILED - read the messages above.
echo If it says INSTALL_FAILED_USER_RESTRICTED, turn on "Install via USB" in
echo the phone developer options.
pause
exit /b 1
