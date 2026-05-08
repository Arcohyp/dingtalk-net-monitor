@echo off
chcp 65001 >nul
title Network Monitor Daemon

echo ==========================================
echo      Network Monitor Daemon Started
echo ==========================================
echo.
echo The daemon will keep the monitor running
echo Auto-restart if the monitor exits
echo.
echo Press Ctrl+C to stop the daemon
echo ==========================================
echo.

:loop
echo [%date% %time%] Starting network monitor...
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -Silent
echo [%date% %time%] Monitor exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto loop
