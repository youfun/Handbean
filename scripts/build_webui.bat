@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_webui.ps1" %*
