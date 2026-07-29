$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "ASSERT FAILED: $Message. Expected: $Expected; Actual: $Actual" }
}

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in $Path" }
    $ast
}

function Get-FunctionTextFromAst {
    param($Ast, [string]$Name)
    $definition = $Ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if ($null -eq $definition) { throw "Missing function: $Name" }
    $definition.Extent.Text
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'settings.json')
$installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install-AIUsageGauge.ps1')
$status = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Show-AIUsageGaugeStatus.ps1')
$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
$details = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs\README-detailed.md')
$startPath = Join-Path $repoRoot 'Start-AIUsageGauge.ps1'
$installerPath = Join-Path $repoRoot 'Install-AIUsageGauge.ps1'
$statusPath = Join-Path $repoRoot 'Show-AIUsageGaugeStatus.ps1'

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AIUsageGauge-settings-test-{0}" -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $startAst = Get-ScriptAst $startPath
    Invoke-Expression (Get-FunctionTextFromAst $startAst 'New-DefaultAIUsageGaugeSettings')
    Invoke-Expression (Get-FunctionTextFromAst $startAst 'Get-AIUsageGaugeSettings')
    $script:SettingsPath = Join-Path $tempRoot 'runtime-settings.json'
    [ordered]@{
        HealthHeartbeatSeconds = 47
        HealthStaleMinutes = 14
        HeartbeatConfirmationSeconds = 19
        ScreenMargin = 11
    } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    $loadedSettings = Get-AIUsageGaugeSettings
    Assert-Equal 47 $loadedSettings.HealthHeartbeatSeconds 'Runtime must honor HealthHeartbeatSeconds'
    Assert-Equal 14 $loadedSettings.HealthStaleMinutes 'Runtime must honor HealthStaleMinutes'
    Assert-Equal 19 $loadedSettings.HeartbeatConfirmationSeconds 'Runtime must honor HeartbeatConfirmationSeconds'
    Assert-Equal 11 $loadedSettings.ScreenMargin 'Runtime must honor ScreenMargin'

    $installerAst = Get-ScriptAst $installerPath
    Invoke-Expression (Get-FunctionTextFromAst $installerAst 'Write-SettingsJsonAtomically')
    Invoke-Expression (Get-FunctionTextFromAst $installerAst 'Ensure-SettingsFile')
    $script:settingsPath = Join-Path $tempRoot 'install-settings.json'
    '[1]' | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    $originalInvalidSettings = Get-Content -Raw -LiteralPath $script:settingsPath
    try {
        Ensure-SettingsFile
        throw 'Expected non-object settings to be rejected.'
    } catch {
        Assert-True ($_.Exception.Message -match 'malformed') 'Non-object settings must fail closed'
    }
    Assert-Equal $originalInvalidSettings (Get-Content -Raw -LiteralPath $script:settingsPath) 'Rejected settings must remain byte-for-byte unchanged'

    [ordered]@{
        RefreshSeconds = 321
        Custom = [ordered]@{ Level1 = [ordered]@{ Level2 = [ordered]@{ Value = 'preserved' } } }
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    Ensure-SettingsFile
    $merged = Get-Content -Raw -LiteralPath $script:settingsPath | ConvertFrom-Json
    Assert-Equal 321 $merged.RefreshSeconds 'Installer must preserve customized known settings'
    Assert-Equal 'preserved' $merged.Custom.Level1.Level2.Value 'Installer must preserve unknown nested settings'
    Assert-Equal 30 $merged.HealthHeartbeatSeconds 'Installer must add missing health defaults'
    Assert-True (-not (Test-Path -LiteralPath "$script:settingsPath.$PID.tmp")) 'Atomic settings temp file must be cleaned up'

    $statusAst = Get-ScriptAst $statusPath
    foreach ($name in @('Convert-GaugeHealthTimestamp', 'Convert-GaugeServiceHealthStatus', 'Get-GaugeHealthStatus', 'Get-RecentEvents')) {
        Invoke-Expression (Get-FunctionTextFromAst $statusAst $name)
    }
    $script:HealthStatePath = Join-Path $tempRoot 'health.json'
    $script:EventLogPath = Join-Path $tempRoot 'events.log'
    [ordered]@{
        schemaVersion = 1
        pid = 123
        processStartedAt = '2026-07-29T01:00:00Z'
        uiHeartbeatAt = '2026-07-29T01:01:00Z'
        lastUpdateAttemptAt = $null
        codex = [ordered]@{ status = 'ok'; lastSuccessAt = '2026-07-29T01:01:00Z'; ignored = 'must-not-escape' }
        claude = [ordered]@{ status = 'starting'; lastSuccessAt = $null }
        lastScreenCorrectionAt = $null
        ignored = 'must-not-escape'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:HealthStatePath -Encoding UTF8
    $rawHealth = Get-Content -Raw -LiteralPath $script:HealthStatePath | ConvertFrom-Json
    Assert-Equal '2026-07-29T01:00:00.0000000+00:00' (Convert-GaugeHealthTimestamp $rawHealth.processStartedAt) 'Valid health timestamp must normalize'
    Assert-Equal 'ok' (Convert-GaugeServiceHealthStatus $rawHealth.codex).Status 'Valid service health must pass validation'
    $health = Get-GaugeHealthStatus
    Assert-True $health.Available 'Valid fixed-schema health must be available'
    Assert-Equal 'ok' $health.Codex.Status 'Valid service status must be preserved'
    Assert-True ($null -eq $health.PSObject.Properties['ignored']) 'Unknown health fields must not escape'
    Assert-True ($null -eq $health.Codex.PSObject.Properties['ignored']) 'Unknown service fields must not escape'

    '{"schemaVersion":2,"pid":123,"processStartedAt":"secret","uiHeartbeatAt":"secret"}' |
        Set-Content -LiteralPath $script:HealthStatePath -Encoding UTF8
    $malformedHealth = Get-GaugeHealthStatus
    Assert-Equal 'malformed' $malformedHealth.State 'Unsupported or malformed health must fail closed'
    Assert-True (-not $malformedHealth.Available) 'Malformed health must not be available'

    @(
        'credential-looking malformed line'
        '{"timestamp":"not-a-date","event":"health_watchdog_failed"}'
        '{"timestamp":"2026-07-29T01:02:00Z","event":"health_watchdog_invoked","ignored":"must-not-escape"}'
    ) | Set-Content -LiteralPath $script:EventLogPath -Encoding UTF8
    $recentEvents = @(Get-RecentEvents -Count 10)
    Assert-Equal 1 $recentEvents.Count 'Malformed event lines must be dropped'
    Assert-Equal 'health_watchdog_invoked' $recentEvents[0].Event 'Valid event name must remain'
    Assert-True ($null -eq $recentEvents[0].PSObject.Properties['raw']) 'Raw malformed log text must never be returned'
    Assert-True ($null -eq $recentEvents[0].PSObject.Properties['ignored']) 'Unknown event fields must never be returned'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
