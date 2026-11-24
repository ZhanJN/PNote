@echo off
rem Rebuild an "archive copy" of a release folder and verify it file by file.
rem Usage: pack-v3.bat [src] [dst]
rem   default src = D:\PNote_V3
rem   default dst = <this repo>\..\PNote_V3
setlocal
cd /d "%~dp0"

set "SRC=%~1"
if "%SRC%"=="" set "SRC=D:\PNote_V3"
set "DST=%~2"
if "%DST%"=="" set "DST=%~dp0..\PNote_V3"

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
