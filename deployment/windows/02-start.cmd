@echo off
setlocal DisableDelayedExpansion
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" goto missing_powershell
if not exist "%~dp0myhome-windows.ps1" goto missing_script
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0myhome-windows.ps1" -Action Start %*
set "RESULT=%ERRORLEVEL%"
goto done
:missing_powershell
echo [FAILED] Windows PowerShell is missing. Windows 10/11 64-bit is required.
set "RESULT=9009"
goto done
:missing_script
echo [FAILED] myhome-windows.ps1 is missing. Extract the COMPLETE deployment ZIP first.
set "RESULT=2"
:done
echo.
if not "%RESULT%"=="0" echo Start failed. Exit code: %RESULT%. Read the reason above; keep data and state.
pause
exit /b %RESULT%
