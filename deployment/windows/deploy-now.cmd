@echo off
setlocal DisableDelayedExpansion
rem 由后端「部署最新」分离式拉起（不由用户双击）。用 start 把 PowerShell 甩成独立进程：
rem Update 第一步就是 taskkill /T /F 掉后端整棵进程树，部署进程若挂在后端下面会被连带杀死、更新烂尾。
rem start 让 PowerShell 的父进程（本 cmd）立即退出、成为孤儿，taskkill /T 便够不着它。
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" exit /b 9009
if not exist "%~dp0myhome-windows.ps1" exit /b 2
rem 安装目录由后端从自己的环境透传（FH_INSTALL_DIR，Start-Backend 注入）；缺省回落到默认位置。
rem FH_DEPLOY_RUN_ID 同样由后端注入并随 start 继承，供 ps1 关联本次部署进度。
set "INSTALL=%FH_INSTALL_DIR%"
if "%INSTALL%"=="" set "INSTALL=%LOCALAPPDATA%\MyHome"
start "MyHomeDeploy" /min "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0myhome-windows.ps1" -Action Update -InstallDir "%INSTALL%"
exit /b 0
