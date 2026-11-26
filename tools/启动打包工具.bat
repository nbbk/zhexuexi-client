@echo off
rem 哲学系客户端打包工具启动器：双击本文件打开图形界面。
rem 用系统自带的 Windows PowerShell 5.1 就够，不用装 PowerShell 7。
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package-apk.ps1"
if errorlevel 1 (
  echo.
  echo 脚本出错退出了（见上面提示），按任意键关闭。
  pause >nul
)
