@echo off
REM ---------------------------------------------------------------------------
REM  Run-XHTTPRelayDeploy.bat
REM  Launches the XHTTP Relay deployer with a relaxed execution policy for this
REM  process only (does not change machine/user policy permanently).
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File ".\XHTTPRelayDeploy.ps1"

if errorlevel 1 (
    echo.
    echo The deployer exited with an error code.
)

echo.
pause
endlocal
