@echo off
chcp 65001 >nul
title Network Monitor Daemon

:: 检查是否已有守护进程或监控脚本在运行
powershell -NoProfile -Command "$current = $PID; $others = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.ProcessId -ne $current -and $_.CommandLine -like '*NetworkMonitor.ps1*' }; if ($others) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% equ 0 (
    echo [WARNING] 守护进程或监控脚本正在运行中，请关闭已有实例或等待其退出
    echo [WARNING] 请勿重复启动守护进程
    echo.
    pause
    exit /b 1
)

echo ==========================================
echo      Network Monitor Daemon Started
echo ==========================================
echo.
echo The daemon will keep the monitor running
echo Auto-restart if the monitor exits abnormally
echo.
echo Press Ctrl+C to stop the daemon
echo ==========================================
echo.

:: 清除可能残留的正常退出标记
del ".nm_normal_exit" >nul 2>&1

:loop
echo [%date% %time%] Starting network monitor...
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -Silent
set EXITCODE=%errorlevel%

:: 检测正常退出标记
if exist ".nm_normal_exit" (
    del ".nm_normal_exit" >nul 2>&1
    echo [%date% %time%] Monitor exited normally. Daemon stopping.
    exit /b 0
)

:: 退出码 0 也视为正常退出（某些场景下 finally 可能执行成功）
if %EXITCODE% equ 0 (
    echo [%date% %time%] Monitor exited with code 0. Daemon stopping.
    exit /b 0
)

echo [%date% %time%] Monitor exited unexpectedly ^(code: %EXITCODE%^), restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto loop
