@echo off
chcp 65001 >nul
setlocal

rem Double-click launcher for Update-DshPlugins.ps1.
rem Keep this file ASCII-only: cmd.exe misparses non-ASCII bytes in batch files.
rem The script needs PowerShell 7+ (#Requires -Version 7.0); fall back to it only.

set "PWSH="
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PWSH=pwsh.exe"

if not defined PWSH goto nopwsh

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-DshPlugins.ps1" %*
set "rc=%ERRORLEVEL%"
goto report

:nopwsh
echo.
echo [ERROR] PowerShell 7 (pwsh.exe) not found in PATH.
echo         This script requires PowerShell 7.0 or newer.
echo         Install it from https://aka.ms/powershell and try again.
echo.
set "rc=127"
goto done

:report
echo.
if "%rc%"=="0" goto ok
echo [exit code %rc%] see the output above.
goto done
:ok
echo Done.
:done
echo.
pause
endlocal
exit /b %rc%
