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

Assert-True (Test-Path -LiteralPath $startScript) 'Start-AIUsageGauge.ps1 is missing'
Assert-True (Test-Path -LiteralPath $helperScript) 'Invoke-ClaudeOAuthRefresh.ps1 is missing'

$start = Get-Content -Raw -LiteralPath $startScript
$helper = Get-Content -Raw -LiteralPath $helperScript

Assert-True ($start -match 'Global\\AIUsageGauge') 'Start script must create a named mutex'
Assert-True ($start -match '再ログイン要') 'Expired Claude auth must show a relogin-required label'
Assert-True ($start -notmatch 'Invoke-RestMethod\s+-Uri\s+[''"]https://platform\.claude\.com/v1/oauth/token') 'Gauge must not directly call the Claude OAuth token endpoint'
Assert-True ($start -match 'Invoke-ClaudeOAuthRefresh\.ps1') 'Gauge must delegate Claude OAuth refresh to the helper script'

Assert-True ($helper -match 'claude-code') 'Helper must discover Claude Code installs dynamically'
Assert-True ($helper -match '--no-session-persistence') 'Helper must avoid persisting probe conversations'
Assert-True ($helper -match 'RefreshWindowSeconds') 'Helper must guard CLI calls behind a local expiry window'
Assert-True ($helper -notmatch 'accessToken|refreshToken') 'Helper must not read token values directly'

Write-Host 'AI Usage Gauge tests passed'
