@echo off
rem ============================================================
rem  Slay the Spire Save Assistant - console watcher
rem  双击本文件开始后台记录存档快照，保持窗口开着即可。
rem ============================================================
cd /d "%~dp0"
title Slay the Spire Save Watcher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sts_save_watch.ps1" %*
echo.
echo Watcher stopped. Press any key to close.
pause >nul
