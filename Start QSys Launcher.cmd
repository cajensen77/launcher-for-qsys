@echo off
rem ------------------------------------------------------------------
rem  Starts Q-SYS Launcher using Windows' built-in PowerShell 5.1.
rem   -STA                     : WPF windows need a single-threaded apartment
rem   -ExecutionPolicy Bypass  : lets this one script run without changing system policy
rem   -WindowStyle Hidden      : hides the black console window
rem  Keep this file in the same folder as QSysLauncher.ps1.
rem ------------------------------------------------------------------
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0QSysLauncher.ps1"
