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
    'ConvertFrom-WindowsCommandLine'
    'ConvertTo-ProcessStartUtcTicks'
    'Get-EffectiveHeartbeatConfirmationSeconds'
    'Get-WatchdogRecoverySettings'
    'Test-GaugeProcessCommandLine'
    'Get-GaugeHeartbeatStatus'
    'Invoke-ConfirmedGaugeRecovery'
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

$ScriptDir = 'C:\app'
$canonicalGaugePath = 'C:\app\Start-AIUsageGauge.ps1'
$matchingCommandLines = @(
    'pwsh.exe -File "C:\app\Start-AIUsageGauge.ps1"',
    'powershell -NoProfile -File C:\app\Start-AIUsageGauge.ps1 -Placement right',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File C:\app\Start-AIUsageGauge.ps1',
    '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "C:\app\Start-AIUsageGauge.ps1" -RefreshSeconds 30',
    'pwsh.exe -File C:\app\Start-AIUsageGauge.ps1 -e script-value -en script-value -enco script-value -CommandWithArgs script-value -cwa script-value -EncodedArguments script-value /c script-value /EncodedCommand script-value --Command script-value --File C:\other.ps1 C:\other.ps1 /File C:\other.ps1 -f C:\other.ps1'
)
foreach ($commandLine in $matchingCommandLines) {
    Assert-True (Test-GaugeProcessCommandLine $commandLine) "Gauge command line must match: $commandLine"
}

$nonMatchingCommandLines = @(
    'pwsh.exe -Command Start-AIUsageGauge.ps1',
    'pwsh.exe -Command "Write-Host ready" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -c "Write-Host ready" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -EncodedCommand AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -enc AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -e AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -ec AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -en AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -enco AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -CommandWithArgs "Write-Host ready" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -cwa "Write-Host ready" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -EncodedArguments AAA -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe /File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe /File C:\other.ps1 -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe /f C:\other.ps1 -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -f C:\other.ps1 -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe C:\other.ps1 -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe "C:\other dir\other.ps1" -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -File "C:\app\Watch-AIUsageGaugeHealth.ps1"',
    'powershell.exe -File C:\app\Start-AIUsageGauge.ps1x',
    'pwsh.exe -File C:\app\another.ps1 Start-AIUsageGauge.ps1',
    'pwsh.exe -File C:\app\another.ps1 -Target C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe -File C:\other\Start-AIUsageGauge.ps1',
    'pwsh.exe -File Start-AIUsageGauge.ps1',
    'pwsh.exe -File ''C:\app\Start-AIUsageGauge.ps1''',
    'pwsh.exe -File ''C:\app dir\Start-AIUsageGauge.ps1''',
    'pwsh.exe -NoProfile -UnknownMode value -File C:\app\Start-AIUsageGauge.ps1',
    'cmd.exe /c pwsh.exe -File C:\app\Start-AIUsageGauge.ps1',
    'pwsh.exe Start-AIUsageGauge.ps1'
)
foreach ($commandLine in $nonMatchingCommandLines) {
    Assert-False (Test-GaugeProcessCommandLine $commandLine) "Non-gauge command line must not match: $commandLine"
}

$executionSelectorNames = @(
    'Command'
    'CommandWithArgs'
    'EncodedCommand'
    'EncodedArguments'
)
$executionSelectorTokens = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($selectorName in $executionSelectorNames) {
    foreach ($prefixLength in 1..$selectorName.Length) {
        [void]$executionSelectorTokens.Add($selectorName.Substring(0, $prefixLength))
    }
}
foreach ($selectorAlias in @('c', 'cwa', 'e', 'ec', 'enc')) {
    [void]$executionSelectorTokens.Add($selectorAlias)
}

foreach ($selectorToken in @($executionSelectorTokens | Sort-Object)) {
    foreach ($caseVariant in @($selectorToken.ToLowerInvariant(), $selectorToken.ToUpperInvariant())) {
        foreach ($optionPrefix in @('-', '--', '/')) {
            $selectorCommandLine = 'pwsh.exe {0}{1} selector-payload -File C:\app\Start-AIUsageGauge.ps1' -f $optionPrefix, $caseVariant
            Assert-False (Test-GaugeProcessCommandLine $selectorCommandLine) "Execution selector prefix must not match: $optionPrefix$caseVariant"
        }
    }
}

foreach ($filePrefixLength in 1..'File'.Length) {
    $fileSelectorPrefix = 'File'.Substring(0, $filePrefixLength)
    foreach ($caseVariant in @($fileSelectorPrefix.ToLowerInvariant(), $fileSelectorPrefix.ToUpperInvariant())) {
        foreach ($optionPrefix in @('-', '--', '/')) {
            $shadowedFileCommandLine = 'pwsh.exe {0}{1} C:\other.ps1 -File C:\app\Start-AIUsageGauge.ps1' -f $optionPrefix, $caseVariant
            Assert-False (Test-GaugeProcessCommandLine $shadowedFileCommandLine) "Earlier File selector must shadow the later Gauge target: $optionPrefix$caseVariant"
        }
    }
}

Assert-False (Test-GaugeProcessCommandLine $null) 'A null command line must not match'
Assert-False (Test-GaugeProcessCommandLine '   ') 'A blank command line must not match'

$singleQuotedArgv = @(ConvertFrom-WindowsCommandLine 'pwsh.exe -File ''C:\app dir\Start-AIUsageGauge.ps1''')
Assert-Equal 4 $singleQuotedArgv.Count 'Raw Windows command lines must not treat single quotes as grouping characters'
Assert-Equal "'C:\app" $singleQuotedArgv[2] 'The first raw single-quoted path fragment must retain its quote character'

Assert-Equal 35 (Get-EffectiveHeartbeatConfirmationSeconds 10 30 5) 'Confirmation must outlast the default heartbeat plus margin'
Assert-Equal 60 (Get-EffectiveHeartbeatConfirmationSeconds 60 30 5) 'A larger configured confirmation must remain usable'
Assert-Equal 50 (Get-EffectiveHeartbeatConfirmationSeconds 10 45 5) 'A configured heartbeat must raise the effective confirmation'

$missingSettingsPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-usage-gauge-missing-{0}.json' -f [guid]::NewGuid())
$SettingsPath = $missingSettingsPath
$defaultRecoverySettings = Get-WatchdogRecoverySettings
Assert-Equal 30 $defaultRecoverySettings.HealthHeartbeatSeconds 'Missing settings must retain the default heartbeat'
Assert-Equal 35 $defaultRecoverySettings.HeartbeatConfirmationSeconds 'Missing settings must still apply the resume-safe confirmation minimum'

$temporarySettingsPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-usage-gauge-settings-{0}.json' -f [guid]::NewGuid())
try {
    '{"HealthHeartbeatSeconds":45,"HeartbeatConfirmationSeconds":60}' |
        Set-Content -LiteralPath $temporarySettingsPath -Encoding UTF8
    $SettingsPath = $temporarySettingsPath
    $configuredRecoverySettings = Get-WatchdogRecoverySettings
    Assert-Equal 45 $configuredRecoverySettings.HealthHeartbeatSeconds 'Configured heartbeat settings must remain usable'
    Assert-Equal 60 $configuredRecoverySettings.HeartbeatConfirmationSeconds 'A configured confirmation above the minimum must remain usable'

    '{"HealthHeartbeatSeconds":45,"HeartbeatConfirmationSeconds":10}' |
        Set-Content -LiteralPath $temporarySettingsPath -Encoding UTF8
    $clampedRecoverySettings = Get-WatchdogRecoverySettings
    Assert-Equal 50 $clampedRecoverySettings.HeartbeatConfirmationSeconds 'Configured confirmation below heartbeat plus margin must be raised'
} finally {
    Remove-Item -LiteralPath $temporarySettingsPath -Force -ErrorAction SilentlyContinue
    $SettingsPath = Join-Path $ScriptDir 'settings.json'
}

$now = [DateTimeOffset]::Parse('2026-07-29T04:00:00Z')
$exactProcessStart = [DateTimeOffset]::ParseExact(
    '2026-07-29T03:00:00.1234567+00:00',
    'o',
    [System.Globalization.CultureInfo]::InvariantCulture
)
$expectedProcessStartTicks = $exactProcessStart.UtcDateTime.Ticks
Assert-Equal $expectedProcessStartTicks (ConvertTo-ProcessStartUtcTicks $exactProcessStart) 'DateTimeOffset process starts must preserve exact UTC ticks'
Assert-Equal $expectedProcessStartTicks (ConvertTo-ProcessStartUtcTicks $exactProcessStart.UtcDateTime) 'DateTime process starts must preserve exact UTC ticks'
$previousCulture = [System.Globalization.CultureInfo]::CurrentCulture
try {
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    Assert-Equal $expectedProcessStartTicks (ConvertTo-ProcessStartUtcTicks $exactProcessStart.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)) 'String process starts must parse independently of current culture'
} finally {
    [System.Globalization.CultureInfo]::CurrentCulture = $previousCulture
}

$oldProcess = [pscustomobject]@{
    ProcessId = 42
    CreationDate = $now.AddHours(-1)
}
$newProcess = [pscustomobject]@{
    ProcessId = 42
    CreationDate = $now.AddMinutes(-1)
}
$oldProcessStartedAt = ([DateTimeOffset]$oldProcess.CreationDate).ToString('o')
$newProcessStartedAt = ([DateTimeOffset]$newProcess.CreationDate).ToString('o')

Assert-Equal 'missing' (Get-GaugeHeartbeatStatus $oldProcess $null $now 10 2) 'Missing health state must be reported'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A missing health schema version must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 2
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'An unsupported health schema version must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 'not-a-pid'
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A malformed health PID must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = 'not-a-timestamp'
}) $now 10 2) 'A malformed heartbeat timestamp must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A missing health process start timestamp must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = 'not-a-timestamp'
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'An unparseable health process start timestamp must be rejected'
Assert-Equal 'malformed' (Get-GaugeHeartbeatStatus ([pscustomobject]@{
    ProcessId = 42
    CreationDate = 'not-a-timestamp'
}) ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A malformed process creation timestamp must be rejected'
Assert-Equal 'pid_mismatch' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 43
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A health PID for another process must be rejected'
Assert-Equal 'pid_mismatch' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = ([DateTimeOffset]$oldProcess.CreationDate).AddSeconds(3).ToString('o')
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A reused PID with a different process start time must be rejected'
Assert-Equal 'startup_grace' (Get-GaugeHeartbeatStatus $newProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $newProcessStartedAt
    uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'A newly started gauge must receive startup grace'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = ([DateTimeOffset]$oldProcess.CreationDate).AddSeconds(2).ToString('o')
    uiHeartbeatAt = $now.AddMinutes(-1).ToString('o')
}) $now 10 2) 'Process start timestamps within two seconds must match'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.AddMinutes(-1).ToString('o')
}) $now 10 2) 'A recent heartbeat must be fresh'
Assert-Equal 'stale' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.AddMinutes(-11).ToString('o')
}) $now 10 2) 'An old heartbeat must be stale'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.AddMinutes(-10).ToString('o')
}) $now 10 2) 'A heartbeat exactly at the stale threshold must remain fresh'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $oldProcess ([pscustomobject]@{
    schemaVersion = 1
    pid = 42
    processStartedAt = $oldProcessStartedAt
    uiHeartbeatAt = $now.AddMinutes(5).ToString('o')
}) $now 10 2) 'A future heartbeat must not be stale'

$validGaugeCommandLine = 'pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "C:\app\Start-AIUsageGauge.ps1" -Placement right'
function New-TestGaugeProcess {
    param(
        [DateTimeOffset]$StartedAt = $exactProcessStart,
        [string]$CommandLine = $validGaugeCommandLine
    )

    [pscustomobject]@{
        ProcessId = 42
        CreationDate = $StartedAt
        CommandLine = $CommandLine
    }
}

function New-TestHealthState {
    param(
        [DateTimeOffset]$HeartbeatAt,
        [DateTimeOffset]$StartedAt = $exactProcessStart
    )

    [pscustomobject]@{
        schemaVersion = 1
        pid = 42
        processStartedAt = $StartedAt.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        uiHeartbeatAt = $HeartbeatAt.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Invoke-TestRecoveryScenario {
    param(
        [object[]]$ProcessResults,
        [object[]]$HealthResults,
        [string]$StopResult = 'stopped'
    )

    $scenario = [pscustomobject]@{
        ProcessIndex = 0
        HealthIndex = 0
        SleepCount = 0
        SleptSeconds = 0
        StopCount = 0
        RestartCount = 0
    }
    $queryProcess = {
        param([int]$ProcessId)
        if ($scenario.ProcessIndex -ge $ProcessResults.Count) { return $null }
        $result = $ProcessResults[$scenario.ProcessIndex]
        $scenario.ProcessIndex++
        return $result
    }.GetNewClosure()
    $readHealth = {
        if ($scenario.HealthIndex -ge $HealthResults.Count) { return [pscustomobject]@{} }
        $result = $HealthResults[$scenario.HealthIndex]
        $scenario.HealthIndex++
        return $result
    }.GetNewClosure()
    $sleep = {
        param([int]$Seconds)
        $scenario.SleepCount++
        $scenario.SleptSeconds = $Seconds
    }.GetNewClosure()
    $stopVerified = {
        param([int]$ProcessId, [long]$ExpectedStartUtcTicks, [string]$ExpectedScriptPath)
        $scenario.StopCount++
        return $StopResult
    }.GetNewClosure()
    $startHidden = { $scenario.RestartCount++ }.GetNewClosure()

    Invoke-ConfirmedGaugeRecovery `
        -ProcessId 42 `
        -ExpectedProcessStartUtcTicks $expectedProcessStartTicks `
        -ExpectedScriptPath $canonicalGaugePath `
        -StaleMinutes 10 `
        -StartupGraceMinutes 2 `
        -ConfirmationSeconds 35 `
        -QueryProcess $queryProcess `
        -ReadHealth $readHealth `
        -Sleep $sleep `
        -StopVerified $stopVerified `
        -StartHidden $startHidden `
        -GetNow { $now } `
        -WriteEvent { param($Event, $Data) } `
        -WriteStatus { param($Message) }

    return $scenario
}

$sameProcess = New-TestGaugeProcess
$recoveredScenario = Invoke-TestRecoveryScenario `
    -ProcessResults @($sameProcess) `
    -HealthResults @((New-TestHealthState -HeartbeatAt $now.AddMinutes(-1)))
Assert-Equal 0 $recoveredScenario.StopCount 'A recovered heartbeat must not stop the gauge'
Assert-Equal 0 $recoveredScenario.RestartCount 'A recovered heartbeat must not restart the gauge'

$malformedScenario = Invoke-TestRecoveryScenario `
    -ProcessResults @($sameProcess) `
    -HealthResults @([pscustomobject]@{})
Assert-Equal 0 $malformedScenario.StopCount 'Malformed confirmation health must not stop the gauge'
Assert-Equal 0 $malformedScenario.RestartCount 'Malformed confirmation health must not restart the gauge'

$exitedScenario = Invoke-TestRecoveryScenario -ProcessResults @() -HealthResults @()
Assert-Equal 0 $exitedScenario.StopCount 'An exited process must not be stopped'
Assert-Equal 1 $exitedScenario.RestartCount 'An exited process must launch the hidden gauge once'

$reusedScenario = Invoke-TestRecoveryScenario `
    -ProcessResults @((New-TestGaugeProcess -StartedAt $exactProcessStart.AddTicks(1))) `
    -HealthResults @()
Assert-Equal 0 $reusedScenario.StopCount 'A reused PID with a different exact start tick must not be stopped'
Assert-Equal 0 $reusedScenario.RestartCount 'A reused PID must not trigger a competing restart'

$changedCommandScenario = Invoke-TestRecoveryScenario `
    -ProcessResults @((New-TestGaugeProcess -CommandLine 'pwsh.exe -File "C:\other\Start-AIUsageGauge.ps1"')) `
    -HealthResults @()
Assert-Equal 0 $changedCommandScenario.StopCount 'A changed command line must not be stopped'
Assert-Equal 0 $changedCommandScenario.RestartCount 'A changed command line must not restart the gauge'

$staleHealth = New-TestHealthState -HeartbeatAt $now.AddMinutes(-11)
$confirmedStaleScenario = Invoke-TestRecoveryScenario `
    -ProcessResults @($sameProcess, $sameProcess) `
    -HealthResults @($staleHealth, $staleHealth)
Assert-Equal 1 $confirmedStaleScenario.StopCount 'A twice-confirmed stale gauge must authorize exactly one stop'
Assert-Equal 1 $confirmedStaleScenario.RestartCount 'A stopped stale gauge must launch hidden exactly once'
Assert-Equal 1 $confirmedStaleScenario.SleepCount 'Recovery must wait exactly once for confirmation'
Assert-Equal 35 $confirmedStaleScenario.SleptSeconds 'Recovery must use the effective resume-safe confirmation delay'

$getProcessesAst = Get-WatchdogFunctionAst 'Get-GaugeProcesses'
$ensureRunningAst = Get-WatchdogFunctionAst 'Ensure-GaugeRunning'
$recoveryAst = Get-WatchdogFunctionAst 'Invoke-ConfirmedGaugeRecovery'
$stopVerifiedAst = Get-WatchdogFunctionAst 'Stop-VerifiedGaugeProcess'
Assert-True ($null -ne $getProcessesAst) 'Get-GaugeProcesses function is missing'
Assert-True ($null -ne $ensureRunningAst) 'Ensure-GaugeRunning function is missing'
Assert-True ($null -ne $recoveryAst) 'Invoke-ConfirmedGaugeRecovery function is missing'
Assert-True ($null -ne $stopVerifiedAst) 'Stop-VerifiedGaugeProcess function is missing'

$getProcessesText = $getProcessesAst.Extent.Text
$ensureRunningText = $ensureRunningAst.Extent.Text
$recoveryText = $recoveryAst.Extent.Text
$stopVerifiedText = $stopVerifiedAst.Extent.Text
$heartbeatStatusText = $requiredFunctions['Get-GaugeHeartbeatStatus'].Extent.Text
$commandLineText = $requiredFunctions['Test-GaugeProcessCommandLine'].Extent.Text

Assert-True ($getProcessesText -match 'Get-CimInstance\s+Win32_Process') 'Gauge discovery must use Win32_Process CIM data'
Assert-True ($getProcessesText -match 'Test-GaugeProcessCommandLine') 'Gauge discovery must use strict command-line validation'
Assert-True ($getProcessesText -match 'GaugeScriptPath') 'Gauge discovery must require the canonical script path'
Assert-True ($commandLineText -match 'ConvertFrom-WindowsCommandLine') 'Command matching must use Windows argv parsing'
Assert-True ($commandLineText -match 'GetFullPath') 'Command matching must canonicalize the expected and actual script paths'
Assert-True ($ensureRunningText -match "(?s)if\s*\(\`$status\s*-ne\s*'stale'\)\s*\{.*?continue.*?\}.*?Invoke-ConfirmedGaugeRecovery") 'Only a stale heartbeat may invoke confirmed recovery'
Assert-True ($heartbeatStatusText -match 'schemaVersion') 'Heartbeat classification must validate schemaVersion'
Assert-True ($heartbeatStatusText -match 'processStartedAt') 'Heartbeat classification must validate the health process start time'
Assert-True ($heartbeatStatusText -match 'TotalSeconds\)\s*-gt\s*2') 'Heartbeat classification must enforce the two-second process start tolerance'
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
Assert-True ($stopCommands[0].Extent.StartOffset -gt $stopVerifiedAst.Extent.StartOffset -and
    $stopCommands[0].Extent.EndOffset -lt $stopVerifiedAst.Extent.EndOffset) 'The sole Stop-Process call must be isolated in Stop-VerifiedGaugeProcess'
$commandValidationGuard = @($stopVerifiedAst.FindAll({
    param($ast)
    $ast -is [System.Management.Automation.Language.IfStatementAst] -and
        $ast.Extent.Text -match 'Test-GaugeProcessCommandLine'
}, $true)) | Select-Object -Last 1
Assert-True ($null -ne $commandValidationGuard) 'Final command-line validation guard is missing'
$guardEndInFunction = $commandValidationGuard.Extent.EndOffset - $stopVerifiedAst.Extent.StartOffset
$stopStartInFunction = $stopCommands[0].Extent.StartOffset - $stopVerifiedAst.Extent.StartOffset
$betweenValidationAndStop = $stopVerifiedText.Substring(
    $guardEndInFunction,
    $stopStartInFunction - $guardEndInFunction
)
Assert-True ([string]::IsNullOrWhiteSpace($betweenValidationAndStop)) 'No event logging, rotation, sleep, or external I/O may occur between successful final validation and Stop-Process'
$stopConfirmedEventIndex = $stopVerifiedText.IndexOf("Write-WatchdogEvent 'watchdog_stale_stop_confirmed'")
Assert-True ($stopConfirmedEventIndex -gt $stopStartInFunction) 'The confirmed-stop event must be written only after Stop-Process succeeds'

$sleepIndex = $recoveryText.IndexOf('Start-Sleep')
$confirmationHealthIndex = $recoveryText.IndexOf('Read-GaugeHealthState', $sleepIndex + 1)
Assert-True ($sleepIndex -ge 0) 'Stale recovery must wait for confirmation'
Assert-True ($confirmationHealthIndex -gt $sleepIndex) 'Stale recovery must reread health after the confirmation wait'
Assert-True ($recoveryText -match 'Get-CimInstance\s+Win32_Process\s+-Filter\s+\("ProcessId=\{0\}"\s+-f\s+\$ProcessId\)') 'Recovery CIM queries must use the exact integer ProcessId filter'
Assert-True ($recoveryText -match '(?s)\$null\s*-eq\s*\$confirmationProcess.*?&\s*\$StartHidden.*?return') 'A process that exits during confirmation must be restarted through the injected hidden launcher without stopping'
Assert-True ($recoveryText -match '(?s)\$confirmedStatus\s*-ne\s*''stale''.*?return') 'A heartbeat that recovers during confirmation must not be stopped'
Assert-True ($recoveryText -match '\[long\]\$ExpectedProcessStartUtcTicks') 'Confirmed recovery must accept exact original process start ticks'
Assert-True ($recoveryText -match '(?s)Stop-Verified.*?ExpectedProcessStartUtcTicks') 'Confirmed recovery must pass exact process start ticks to final stop verification'
Assert-True ($ensureRunningText -match '(?s)ConvertTo-ProcessStartUtcTicks.*?\$process\.CreationDate.*?Invoke-ConfirmedGaugeRecovery.*?-ExpectedProcessStartUtcTicks') 'Gauge monitoring must preserve exact initial CIM start ticks through confirmation'

Assert-True ($stopVerifiedText -match '\[long\]\$ExpectedProcessStartUtcTicks') 'Final stop verification must require exact expected process start ticks'
$verifiedCimIndex = $stopVerifiedText.IndexOf('Get-CimInstance Win32_Process')
$verifiedCreationIndex = $stopVerifiedText.IndexOf('$verifiedProcess.CreationDate')
$verifiedTicksIndex = $stopVerifiedText.IndexOf('ConvertTo-ProcessStartUtcTicks')
$verifiedExactMatchIndex = $stopVerifiedText.IndexOf('-ne $ExpectedProcessStartUtcTicks')
$verifiedCommandIndex = $stopVerifiedText.IndexOf('Test-GaugeProcessCommandLine')
$verifiedStopIndex = $stopVerifiedText.IndexOf('Stop-Process')
Assert-True ($verifiedCimIndex -ge 0 -and $verifiedCreationIndex -gt $verifiedCimIndex) 'Final stop verification must read creation time from a fresh exact-PID CIM result'
Assert-True ($verifiedTicksIndex -gt $verifiedCreationIndex -and $verifiedExactMatchIndex -gt $verifiedTicksIndex -and $verifiedExactMatchIndex -lt $verifiedStopIndex) 'Final stop verification must compare exact UTC process start ticks before stopping'
Assert-True ($verifiedCommandIndex -gt $verifiedCimIndex -and $verifiedCommandIndex -lt $verifiedStopIndex) 'Final stop verification must revalidate the command line before stopping'

Write-Host 'Health recovery tests passed'
