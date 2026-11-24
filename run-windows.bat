@echo off
rem Build (if needed) and launch the Windows release build.
rem Optional: set FLUTTER_HOME, FLUTTER_STORAGE_BASE_URL, PUB_HOSTED_URL.
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

set "EXE=build\windows\x64\runner\Release\pnote.exe"

if not exist "%EXE%" (
  echo [1/2] no build yet, running "flutter build windows --release" ...
  call flutter build windows --release
  if errorlevel 1 (
    echo.
    echo [FAIL] build failed, see the last lines above.
    pause
    exit /b 1
  )
)

echo [2/2] starting PNote ...
start "" "%EXE%"
exit /b 0
