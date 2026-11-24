@echo off
rem Build PNote for Windows (release). Double-click this file.
rem Optional env: FLUTTER_HOME, FLUTTER_STORAGE_BASE_URL, PUB_HOSTED_URL.
setlocal
cd /d "%~dp0"

if not defined FLUTTER_HOME set "FLUTTER_HOME=D:\dev\flutter"
if exist "%FLUTTER_HOME%\bin\flutter.bat" set "PATH=%FLUTTER_HOME%\bin;%PATH%"

where flutter >nul 2>nul
if errorlevel 1 (
  echo [FAIL] flutter not found. Set FLUTTER_HOME to your Flutter SDK root.
  pause
  exit /b 1
)

echo [1/2] flutter pub get
call flutter pub get
if errorlevel 1 goto fail

echo [2/2] flutter build windows --release
call flutter build windows --release
if errorlevel 1 goto fail

echo.
echo BUILD OK
echo Output: build\windows\x64\runner\Release\pnote.exe
pause
exit /b 0

:fail
echo.
echo BUILD FAILED - read the messages above.
pause
exit /b 1
