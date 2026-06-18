@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RemoteSshApp.ps1" -ConfigPath "%~dp0config.ini"
