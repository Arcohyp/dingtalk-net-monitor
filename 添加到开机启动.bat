@echo off
chcp 65001 >nul
title Add to Startup

set "TARGET_BAT=%~dp0守护进程.bat"
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT_NAME=Network Monitor Daemon.lnk"

if not exist "%TARGET_BAT%" (
    echo Error: Daemon script not found
    echo %TARGET_BAT%
    pause
    exit /b 1
)

echo ==========================================
echo      Add to Startup
echo ==========================================
echo.
echo Target: %TARGET_BAT%
echo Startup folder: %STARTUP_FOLDER%
echo Shortcut name: %SHORTCUT_NAME%
echo.

powershell -NoProfile -Command "
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut('%STARTUP_FOLDER%\%SHORTCUT_NAME%')
    $Shortcut.TargetPath = '%TARGET_BAT%'
    $Shortcut.WorkingDirectory = '%~dp0'
    $Shortcut.Description = 'Network Monitor Daemon'
    $Shortcut.Save()
    Write-Host 'Shortcut created successfully!' -ForegroundColor Green
"

if %errorlevel% neq 0 (
    echo Failed to create shortcut
    pause
    exit /b 1
)

echo.
echo Done! The daemon will start automatically on boot.
echo.
echo To remove: Win+R, type shell:startup, delete the shortcut
echo.
pause
