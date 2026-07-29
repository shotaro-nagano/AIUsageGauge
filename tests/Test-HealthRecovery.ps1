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

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message. Expected: $Expected; Actual: $Actual"
    }
}

$watchdogScript = Join-Path $RepoRoot 'Watch-AIUsageGaugeHealth.ps1'
$tokens = $null
$parseErrors = $null
$watchdogAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $watchdogScript,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Watch-AIUsageGaugeHealth.ps1 has parse errors: $($parseErrors -join '; ')"
}

function Get-WatchdogFunctionAst([string]$FunctionName) {
    $watchdogAst.Find({
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -eq $FunctionName
    }, $true)
}

$requiredFunctionNames = @(
    'Test-GaugeProcessCommandLine'
    'Get-GaugeHeartbeatStatus'
)
$requiredFunctions = @{}
$missingFunctions = @(
    foreach ($functionName in $requiredFunctionNames) {
        $definition = Get-WatchdogFunctionAst $functionName
        if ($null -eq $definition) {
            $functionName
        } else {
            $requiredFunctions[$functionName] = $definition
        }
    }
)

if ($missingFunctions.Count -gt 0) {
    throw "Missing watchdog functions: $($missingFunctions -join ', ')"
}

foreach ($functionName in $requiredFunctionNames) {
    Invoke-Expression $requiredFunctions[$functionName].Extent.Text
}

$matchingCommandLines = @(
    'pwsh.exe -File "C:\app\Start-AIUsageGauge.ps1"',
    'powershell -NoProfile -File C:\app\Start-AIUsageGauge.ps1 -Placement right',
    '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -File ''C:\app dir\Start-AIUsageGauge.ps1'' -RefreshSeconds 30',
    'PWSH -File Start-AIUsageGauge.ps1'
)
foreach ($commandLine in $matchingCommandLines) {
    Assert-True (Test-GaugeProcessCommandLine $commandLine) "Gauge command line must match: $commandLine"
}

$nonMatchingCommandLines = @(
    'pwsh.exe -Command Start-AIUsageGauge.ps1',
    'pwsh.exe -Command "Write-Host ready" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -File "C:\app\Watch-AIUsageGaugeHealth.ps1"',
    'powershell.exe -File C:\app\Start-AIUsageGauge.ps1x',
    'pwsh.exe -File C:\app\another.ps1 Start-AIUsageGauge.ps1',
    'pwsh.exe -File C:\app\another.ps1 -Target C:\app\Start-AIUsageGauge.ps1',
    'cmd.exe /c pwsh.exe -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe Start-AIUsageGauge.ps1'
)
foreach ($commandLine in $nonMatchingCommandLines) {
    Assert-False (Test-GaugeProcessCommandLine $commandLine) "Non-gauge command line must not match: $commandLine"
}

Assert-False (Test-GaugeProcessCommandLine $null) 'A null command line must not match'
Assert-False (Test-GaugeProcessCommandLine '   ') 'A blank command line must not match'

$now = [DateTimeOffset]::Parse('2026-07-29T04:00:00Z')
$oldProcess = [pscustomobject]@{
    ProcessId = 42
    CreationDate = $now.AddHours(-1)
}
$newProcess = [pscustomobject]@{
    ProcessId = 42
    CreationDate = $now.AddMinutes(-1)
}

Assert-Equal 'missing' (Get-GaugeHeartbeatStatus $oldProcess $null $now 10 2) 'Missing health state must be reported'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 'not-a-pid'
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A malformed health PID must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = 'not-a-timestamp'
}) $now 10 2) 'A malformed heartbeat timestamp must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus ([pscustomobject]@{
    ProcessId = 42
    CreationDate = 'not-a-timestamp'
}) ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A malformed process creation timestamp must be rejected'
Assert-Equal 'pid_mismatch' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 43
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A health PID for another process must be rejected'
Assert-Equal 'startup_grace' (Get-GaugeHeartbeatStatus $newProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A newly started gauge must receive startup grace'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.AddMinutes(-1).ToString('o')
}) $now 10 2) 'A recent heartbeat must be fresh'
Assert-Equal 'stale' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.AddMinutes(-11).ToString('o')
}) $now 10 2) 'An old heartbeat must be stale'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.AddMinutes(-10).ToString('o')
}) $now 10 2) 'A heartbeat exactly at the stale threshold must remain fresh'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    uiHeartbeatAt = $now.AddMinutes(5).ToString('o')
}) $now 10 2) 'A future heartbeat must not be stale'

$getProcessesAst = Get-WatchdogFunctionAst 'Get-GaugeProcesses'
$ensureRunningAst = Get-WatchdogFunctionAst 'Ensure-GaugeRunning'
$recoveryAst = Get-WatchdogFunctionAst 'Invoke-ConfirmedGaugeRecovery'
Assert-True ($null -ne $getProcessesAst) 'Get-GaugeProcesses function is missing'
Assert-True ($null -ne $ensureRunningAst) 'Ensure-GaugeRunning function is missing'
Assert-True ($null -ne $recoveryAst) 'Invoke-ConfirmedGaugeRecovery function is missing'

$getProcessesText = $getProcessesAst.Extent.Text
$ensureRunningText = $ensureRunningAst.Extent.Text
$recoveryText = $recoveryAst.Extent.Text

Assert-True ($getProcessesText -match 'Get-CimInstance\s+Win32_Process') 'Gauge discovery must use Win32_Process CIM data'
Assert-True ($getProcessesText -match 'Test-GaugeProcessCommandLine') 'Gauge discovery must use strict command-line validation'
Assert-True ($ensureRunningText -match "(?s)if\s*\(\`$status\s*-ne\s*'stale'\)\s*\{.*?continue.*?\}.*?Invoke-ConfirmedGaugeRecovery") 'Only a stale heartbeat may invoke confirmed recovery'
foreach ($safeStatus in @('missing', 'malformed', 'pid_mismatch', 'startup_grace', 'fresh')) {
    Assert-True ($watchdogAst.Extent.Text -match [regex]::Escape($safeStatus)) "Watchdog must handle $safeStatus without stopping"
}

$stopCommands = @($watchdogAst.FindAll({
    param($ast)
    $ast -is [System.Management.Automation.Language.CommandAst] -and
        $ast.GetCommandName() -eq 'Stop-Process'
}, $true))
Assert-Equal 1 $stopCommands.Count 'Watchdog must contain exactly one narrowly scoped Stop-Process call'
Assert-True ($stopCommands[0].Extent.Text -match '^Stop-Process\s+-Id\s+\$ProcessId(?:\s|$)') 'Stop-Process must target only the confirmed exact ProcessId'
Assert-False ($stopCommands[0].Extent.Text -match '-Name\b') 'Watchdog must never stop processes by name'

$sleepIndex = $recoveryText.IndexOf('Start-Sleep')
$confirmationHealthIndex = $recoveryText.IndexOf('Read-GaugeHealthState', $sleepIndex + 1)
$finalCimIndex = $recoveryText.LastIndexOf('Get-CimInstance Win32_Process')
$finalCommandValidationIndex = $recoveryText.LastIndexOf('Test-GaugeProcessCommandLine')
$stopIndex = $recoveryText.IndexOf('Stop-Process')
Assert-True ($sleepIndex -ge 0) 'Stale recovery must wait for confirmation'
Assert-True ($confirmationHealthIndex -gt $sleepIndex) 'Stale recovery must reread health after the confirmation wait'
Assert-True ($finalCimIndex -gt $confirmationHealthIndex) 'Stale recovery must freshly requery the exact PID after rereading health'
Assert-True ($finalCommandValidationIndex -gt $finalCimIndex) 'Stale recovery must revalidate the freshly queried command line'
Assert-True ($stopIndex -gt $finalCommandValidationIndex) 'Stop-Process must occur only after final PID and command-line revalidation'
Assert-True ($recoveryText -match 'Get-CimInstance\s+Win32_Process\s+-Filter\s+\("ProcessId=\{0\}"\s+-f\s+\$ProcessId\)') 'Recovery CIM queries must use the exact integer ProcessId filter'
Assert-True ($recoveryText -match '(?s)\$null\s*-eq\s*\$confirmationProcess.*?Start-GaugeHidden.*?return') 'A process that exits during confirmation must be restarted without stopping'
Assert-True ($recoveryText -match '(?s)\$confirmedStatus\s*-ne\s*''stale''.*?return') 'A heartbeat that recovers during confirmation must not be stopped'

Write-Host 'Health recovery tests passed'
