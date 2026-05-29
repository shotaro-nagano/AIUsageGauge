@echo off
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh^) was not found.
  echo Install PowerShell 7, then run this launcher again.
  pause
  exit /b 1
)

if not exist "%~dp0Start-AIUsageGauge.ps1" (
  echo Start-AIUsageGauge.ps1 was not found.
  echo Download the full package and keep this CMD file next to the PS1 file.
  pause
  exit /b 1
)

pwsh -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-AIUsageGauge.ps1"
