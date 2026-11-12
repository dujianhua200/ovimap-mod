@echo off
REM ============================================================================
REM  滑洲云图 ovimap —— Windows 一键构建入口（双击运行）
REM  实际逻辑在 build_windows.ps1
REM ============================================================================
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_windows.ps1"
echo.
echo 按任意键关闭窗口...
pause >nul
endlocal
