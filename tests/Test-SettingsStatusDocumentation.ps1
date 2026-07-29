$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'settings.json')
$installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install-AIUsageGauge.ps1')
$status = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Show-AIUsageGaugeStatus.ps1')
$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
$details = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs\README-detailed.md')

$expectedSettings = [ordered]@{
    HealthHeartbeatSeconds = 30
    HealthStaleMinutes = 10
    HeartbeatConfirmationSeconds = 10
    ScreenMargin = 6
}

foreach ($entry in $expectedSettings.GetEnumerator()) {
    Assert-True ($settings -match ('"{0}"\s*:\s*{1}\b' -f $entry.Key, $entry.Value)) "settings.json must include $($entry.Key)"
    Assert-True ($installer -match ('(?m)^\s*{0}\s*=\s*{1}\b' -f $entry.Key, $entry.Value)) "fresh install defaults must include $($entry.Key)"
}

Assert-True ($status -match '\$HealthStatePath\s*=\s*Join-Path\s+\$EventLogDir\s+[''"]health\.json[''"]') 'Status must read the fixed health.json path'
Assert-True ($status -match 'function\s+Get-GaugeHealthStatus') 'Status must expose sanitized gauge health'
foreach ($property in @('ProcessId', 'ProcessStartedAt', 'UiHeartbeatAt', 'LastUpdateAttemptAt', 'Codex', 'Claude', 'LastScreenCorrectionAt')) {
    Assert-True ($status -match ("\b{0}\s*=" -f $property)) "Status health output must include $property"
}
Assert-True ($status -notmatch 'accessToken|refreshToken|Authorization') 'Status must never reference credential values or headers'

foreach ($document in @($readme, $details)) {
    Assert-True ($document -match 'Fable') 'Documentation must describe the Claude Fable row'
    Assert-True ($document -match '/api/oauth/usage') 'Documentation must describe the no-token usage GET endpoint'
    Assert-True ($document -match 'Graphite') 'Documentation must describe the Graphite design'
    Assert-True ($document -match '30') 'Documentation must describe the heartbeat interval'
    Assert-True ($document -match '10') 'Documentation must describe confirmed stale recovery'
    Assert-True ($document -match 'Start-AIUsageGauge\.ps1') 'Documentation must describe strict process scope'
}

Assert-True ($readme -notmatch 'Codex の短期枠（5時間）') 'README must not claim a Codex 5-hour row'
Assert-True ($details -notmatch 'shows remaining Codex and Claude usage for the 5-hour window') 'Detailed README must not claim a Codex 5-hour row'

Write-Host 'Settings, status, and documentation tests passed'
