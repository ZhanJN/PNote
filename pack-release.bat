@echo off
rem Rebuild an "archive copy" of the current release folder and verify it file by file.
rem Usage: pack-release.bat [src] [dst]
rem   default src = D:\PNote_<version>   (version read from pubspec.yaml)
rem   default dst = <this repo>\..\PNote_<version>
setlocal
cd /d "%~dp0"

set "VER="
for /f "tokens=2 delims=:+" %%a in ('findstr /b "version:" pubspec.yaml') do set "VER=%%a"
if "%VER%"=="" (
  echo [FAIL] cannot read version from pubspec.yaml
  pause
  exit /b 1
)

set "SRC=%~1"
if "%SRC%"=="" set "SRC=D:\PNote_%VER%"
set "DST=%~2"
if "%DST%"=="" set "DST=%~dp0..\PNote_%VER%"

set "SCRIPT=%~dp0tool\pack_archive.py"
if not exist "%SCRIPT%" (
  echo [FAIL] %SCRIPT% not found
  pause
  exit /b 1
)

where py >nul 2>nul
if not errorlevel 1 (
  py -3 "%SCRIPT%" "%SRC%" "%DST%"
  goto done
)
where python >nul 2>nul
if not errorlevel 1 (
  python "%SCRIPT%" "%SRC%" "%DST%"
  goto done
)
echo [FAIL] Python 3 not found in PATH
pause
exit /b 1

:done
if errorlevel 1 (
  echo.
  echo PACK FAILED
  pause
  exit /b 1
)
echo.
echo PACK OK
pause
exit /b 0