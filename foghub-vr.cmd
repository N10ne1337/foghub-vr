@echo off
setlocal EnableExtensions
chcp 65001 >nul
title FogHub VR setup
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0foghub-vr.ps1" %*
set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" (
  echo.
  echo Exit code: %EC%
  pause
)
exit /b %EC%
