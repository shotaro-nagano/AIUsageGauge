param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$startScript = Join-Path $RepoRoot 'Start-AIUsageGauge.ps1'
$helperScript = Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh.ps1'
$hiddenRefreshLauncher = Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh-hidden.vbs'
$taskInstaller = Join-Path $RepoRoot 'Install-ClaudeOAuthRefreshTask.ps1'

Assert-True (Test-Path -LiteralPath $startScript) 'Start-AIUsageGauge.ps1 is missing'
Assert-True (Test-Path -LiteralPath $helperScript) 'Invoke-ClaudeOAuthRefresh.ps1 is missing'
Assert-True (Test-Path -LiteralPath $hiddenRefreshLauncher) 'Invoke-ClaudeOAuthRefresh-hidden.vbs is missing'
Assert-True (Test-Path -LiteralPath $taskInstaller) 'Install-ClaudeOAuthRefreshTask.ps1 is missing'

$start = Get-Content -Raw -LiteralPath $startScript
$helper = Get-Content -Raw -LiteralPath $helperScript
$hiddenLauncher = Get-Content -Raw -LiteralPath $hiddenRefreshLauncher
$installer = Get-Content -Raw -LiteralPath $taskInstaller

Assert-True ($start -match 'Global\\AIUsageGauge') 'Start script must create a named mutex'
Assert-True ($start -match '再ログイン要') 'Expired Claude auth must show a relogin-required label'
Assert-True ($start -notmatch 'Invoke-RestMethod\s+-Uri\s+[''"]https://platform\.claude\.com/v1/oauth/token') 'Gauge must not directly call the Claude OAuth token endpoint'
Assert-True ($start -match 'Invoke-ClaudeOAuthRefresh\.ps1') 'Gauge must delegate Claude OAuth refresh to the helper script'
Assert-True ($start -match 'Invoke-ClaudeOAuthRefresh-hidden\.vbs') 'Gauge must use the hidden refresh launcher for foreground refresh attempts'
Assert-True ($start -notmatch '&\s*\$pwsh\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File\s+\$ClaudeRefreshHelperPath') 'Gauge must not launch pwsh.exe directly for Claude refresh'
Assert-True ($start -match 'Ensure-ClaudeRefreshTask') 'Gauge startup must self-heal the Claude refresh scheduled task'
Assert-True ($start -match 'Write-AIUsageGaugeEvent') 'Gauge must write token-free diagnostic events'
Assert-True ($start -match 'AIUG_TOKEN_EXPIRED') 'Gauge must use stable coded errors for expired Claude auth'

Assert-True ($helper -match 'claude-code') 'Helper must discover Claude Code installs dynamically'
Assert-True ($helper -match '--no-session-persistence') 'Helper must avoid persisting probe conversations'
Assert-True ($helper -match 'RefreshWindowSeconds') 'Helper must guard CLI calls behind a local expiry window'
Assert-True ($helper -notmatch 'accessToken|refreshToken') 'Helper must not read token values directly'
Assert-True ($helper -match 'Write-RefreshEvent') 'Helper must write token-free diagnostic events'

Assert-True ($hiddenLauncher -match 'shell\.Run\s*\(\s*command\s*,\s*0\s*,\s*True\s*\)') 'Hidden launcher must run the refresh helper without showing a terminal'
Assert-True ($installer -match "wscript\.exe") 'Scheduled task must use wscript.exe so refresh checks do not flash a terminal'
Assert-True ($installer -notmatch '\$action\.Path\s*=\s*\$pwsh') 'Scheduled task must not launch pwsh.exe directly'
Assert-True ($installer -match '\[int\]\$IntervalMinutes\s*=\s*5') 'Scheduled task interval should default to 5 minutes'

Write-Host 'AI Usage Gauge tests passed'
