@echo off
chcp 65001 >nul
title Network Monitor

:: Check PowerShell availability
powershell -Command "exit 0" >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: PowerShell is not available
    pause
    exit /b 1
)

:: Start monitor (all interaction handled by PowerShell)
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1"

echo.
echo Press any key to exit...
pause >nul
