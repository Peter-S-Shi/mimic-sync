@echo off
setlocal EnableExtensions DisableDelayedExpansion

title Mimic Sync
cd /d "%~dp0"

set "MIMIC_ENGINE=%~dp0mimic-sync.ps1"
set "MIMIC_DEFAULT_CONFIG=%~dp0mimic-sync.config.json"
set "MIMIC_CONFIG="

echo ================================================================
echo Mimic Sync
echo ================================================================
echo.

if not exist "%MIMIC_ENGINE%" (
    echo ERROR: mimic-sync.ps1 was not found beside this launcher.
    echo Expected:
    echo   %MIMIC_ENGINE%
    echo.
    pause
    exit /b 2
)

rem ---------------------------------------------------------------
rem Config selection
rem 1. A JSON path passed to the BAT (including drag-and-drop)
rem 2. The standard mimic-sync.config.json beside the launcher
rem 3. Friendly interactive prompt when neither is available
rem ---------------------------------------------------------------

if not "%~1"=="" (
    set "MIMIC_CONFIG=%~1"
    echo Using config:
    echo   %~1
    echo.
) else if exist "%MIMIC_DEFAULT_CONFIG%" (
    set "MIMIC_CONFIG=%MIMIC_DEFAULT_CONFIG%"
    echo Using default config:
    echo   %MIMIC_DEFAULT_CONFIG%
    echo.
) else (
    echo No default config was found.
    echo.
    echo Expected default:
    echo   %MIMIC_DEFAULT_CONFIG%
    echo.
    echo You can:
    echo   1. Paste a JSON config path below now.
    echo   2. Next time, drag a JSON config file onto Mimic Sync.bat.
    echo   3. Save mimic-sync.config.json beside this launcher.
    echo.
    set /p "MIMIC_CONFIG=Config path ^(press Enter to exit^): "

    if not defined MIMIC_CONFIG (
        echo.
        echo No config selected. Nothing was changed.
        echo.
        pause
        exit /b 0
    )

    rem Remove quote characters if the user pasted a quoted Windows path.
    set "MIMIC_CONFIG=%MIMIC_CONFIG:"=%"

    echo.
    echo Using config:
    echo   %MIMIC_CONFIG%
    echo.
)

if not exist "%MIMIC_CONFIG%" (
    echo ERROR: Config file does not exist:
    echo   %MIMIC_CONFIG%
    echo.
    echo Nothing was changed.
    echo.
    pause
    exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MIMIC_ENGINE%" -Config "%MIMIC_CONFIG%"

set "MIMIC_EXIT=%ERRORLEVEL%"

echo.
echo ================================================================
if "%MIMIC_EXIT%"=="0" (
    echo Mimic Sync finished.
) else (
    echo Mimic Sync finished with exit code %MIMIC_EXIT%.
)
echo ================================================================
echo.
pause

exit /b %MIMIC_EXIT%
