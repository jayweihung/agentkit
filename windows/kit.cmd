@echo off
rem kit for Windows: runs lib\kit.ps1 (kept out of PATH so PowerShell never runs the .ps1 directly). Works from cmd and PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\kit.ps1" %*
exit /b %ERRORLEVEL%
