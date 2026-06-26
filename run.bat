@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

cd /d "%SCRIPT_DIR%"

where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 no encontrado.
    echo Intentando instalarlo con winget...
    winget --version >nul 2>nul
    if errorlevel 1 (
        echo winget no esta disponible. Instala PowerShell 7 desde:
        echo https://github.com/PowerShell/PowerShell/releases
        echo.
        echo O ejecuta: winget install --id Microsoft.PowerShell --source winget
        pause
        exit /b 1
    )

    winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo No se pudo instalar PowerShell automaticamente.
        echo Reinicia la terminal y vuelve a ejecutar este launcher.
        pause
        exit /b 1
    )

    echo PowerShell 7 instalado. Reinicia la terminal y vuelve a ejecutar.
    pause
    exit /b 0
)

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run.ps1" %*
if errorlevel 1 (
    echo.
    echo El script termino con errores.
    pause
)
