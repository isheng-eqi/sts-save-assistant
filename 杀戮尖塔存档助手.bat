@echo off
rem ============================================================
rem  Slay the Spire Save Assistant / 杀戮尖塔 存档助手
rem  双击本文件启动图形界面。
rem  请务必由你自己双击启动（不要由其他程序代启），
rem  否则可能没有写入游戏存档目录的权限。
rem ============================================================
cd /d "%~dp0"
start "Slay the Spire Save Assistant" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sts_save_gui.ps1"
