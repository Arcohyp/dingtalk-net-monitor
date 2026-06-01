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

set "PS_FILE=%TEMP%\create_shortcut_%RANDOM%.ps1"
echo $WshShell = New-Object -ComObject WScript.Shell > "%PS_FILE%"
echo $Shortcut = $WshShell.CreateShortcut('%STARTUP_FOLDER%\%SHORTCUT_NAME%') >> "%PS_FILE%"
echo $Shortcut.TargetPath = '%TARGET_BAT%' >> "%PS_FILE%"
echo $Shortcut.WorkingDirectory = '%~dp0' >> "%PS_FILE%"
echo $Shortcut.Description = 'Network Monitor Daemon' >> "%PS_FILE%"
echo $Shortcut.Save() >> "%PS_FILE%"
echo Write-Host 'Shortcut created successfully!' -ForegroundColor Green >> "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"
set "PS_RESULT=%errorlevel%"
del "%PS_FILE%" >nul 2>&1
set "errorlevel=%PS_RESULT%"

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
