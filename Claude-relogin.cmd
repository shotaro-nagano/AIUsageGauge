@echo off
title Claude relogin
pwsh -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-ChildItem \"$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code\" -Recurse -Filter claude.exe -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if (-not $c) { Write-Host 'claude.exe not found' -ForegroundColor Red; pause; exit 1 }; Write-Host 'Opening Claude sign-in...' -ForegroundColor Cyan; & $c.FullName auth login --claudeai; exit $LASTEXITCODE"
