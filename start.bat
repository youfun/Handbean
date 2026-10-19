@echo off
rem Start the local production Web UI selected by scripts\build_webui.bat.
rem Package layout: start.ps1 sits beside this script (extracted Web UI package).
rem Repo layout: scripts\start.ps1 reads _build\local-webui\current.txt, with a
rem legacy fallback to _build\prod\rel\handbean.
if exist "%~dp0start.ps1" goto package
if exist "%~dp0scripts\start.ps1" goto repo
echo [Error] start.ps1 not found: this folder is neither an extracted Web UI
echo package nor a repository checkout. Build first with scripts\build_webui.bat,
echo or run this script from an extracted Web UI package.
exit /b 1

:package
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
exit /b %ERRORLEVEL%

:repo
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1" %*
exit /b %ERRORLEVEL%
