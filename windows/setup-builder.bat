@echo off
chcp 65001 >nul
REM 哲学系客户端 — Windows 一键构建器（双击入口）
REM 双击这个文件就行：它会先请求管理员权限，再调 setup-builder.ps1。
REM 全程中文提示，装完显示“构建器已就绪”。
REM 注意：本脚本未在真机 Windows 上跑过，阶段 0 须在干净 Win 11 真机上跑一遍。

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo 正在请求管理员权限，请在弹出的窗口点“是”…
  powershell -Command "Start-Process '%~dp0setup-builder.bat' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-builder.ps1"
echo.
echo 按任意键关闭窗口…
pause >nul
