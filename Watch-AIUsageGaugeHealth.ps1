param(
    [switch]$Quiet,
    [switch]$SkipClaudeRefreshTaskCheck,
    [int]$GaugeStartupWaitSeconds = 3
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}

$GaugeHiddenLauncherPath = Join-Path $ScriptDir 'Start-AIUsageGauge-hidden.vbs'
$GaugeScriptName = 'Start-AIUsageGauge.ps1'
$GaugeScriptPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $GaugeScriptName))
$ClaudeRefreshTaskInstallerPath = Join-Path $ScriptDir 'Install-ClaudeOAuthRefreshTask.ps1'
$EventLogDir = Join-Path $env:LOCALAPPDATA 'AIUsageGauge'
$EventLogPath = Join-Path $EventLogDir 'events.log'
$HealthStatePath = Join-Path $EventLogDir 'health.json'
$MaxEventLogBytes = 262144
$SettingsPath = Join-Path $ScriptDir 'settings.json'

function Get-EventLogRetentionDays {
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($null -ne $settings.LogRetentionDays) {
                return [Math]::Max(1, [int]$settings.LogRetentionDays)
            }
        }
    } catch {}
    return 2
}

function Get-EventLogRetentionCutoffDate {
    $retentionDays = Get-EventLogRetentionDays
    return (Get-Date).Date.AddDays(-($retentionDays - 1))
}

function Limit-WatchdogEventLog {
    try {
        if (!(Test-Path -LiteralPath $EventLogPath)) {
            return
        }

        $cutoffDate = Get-EventLogRetentionCutoffDate
        $keptLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $EventLogPath -ErrorAction Stop)) {
            try {
                $entry = $line | ConvertFrom-Json
                if ($null -ne $entry.timestamp) {
                    $eventDate = ([DateTimeOffset]::Parse([string]$entry.timestamp)).LocalDateTime.Date
                    if ($eventDate -ge $cutoffDate) {
                        $keptLines.Add($line)
                    }
                }
            } catch {}
        }

        if ($keptLines.Count -eq 0) {
            Remove-Item -LiteralPath $EventLogPath -Force -ErrorAction SilentlyContinue
            return
        }

        $tempPath = "$EventLogPath.tmp"
        $keptLines | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $EventLogPath -Force

        $logItem = Get-Item -LiteralPath $EventLogPath -ErrorAction Stop
        if ($logItem.Length -le $MaxEventLogBytes) {
            return
        }

        $tail = Get-Content -LiteralPath $EventLogPath -Tail 500 -ErrorAction Stop
        $tail | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $EventLogPath -Force
    } catch {}
}

function Write-WatchdogEvent {
    param(
        [string]$Event,
        [hashtable]$Data = @{}
    )

    try {
        if (!(Test-Path -LiteralPath $EventLogDir)) {
            New-Item -ItemType Directory -Force -Path $EventLogDir | Out-Null
        }

        Limit-WatchdogEventLog

        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            event = $Event
        }
        foreach ($key in $Data.Keys) {
            if ($key -match 'token|authorization|secret') { continue }
            $entry[$key] = $Data[$key]
        }

        ($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $EventLogPath -Encoding UTF8
    } catch {}
}

function Write-Status {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Get-WatchdogRecoverySettings {
    $recoverySettings = [ordered]@{
        HealthStaleMinutes = 10
        HealthHeartbeatSeconds = 30
        HeartbeatConfirmationSeconds = 10
    }

    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($settings.PSObject.Properties.Name -contains 'HealthStaleMinutes') {
                $staleMinutes = [int]$settings.HealthStaleMinutes
                if ($staleMinutes -gt 0) {
                    $recoverySettings.HealthStaleMinutes = $staleMinutes
                }
            }
            if ($settings.PSObject.Properties.Name -contains 'HeartbeatConfirmationSeconds') {
                $confirmationSeconds = [int]$settings.HeartbeatConfirmationSeconds
                if ($confirmationSeconds -ge 0) {
                    $recoverySettings.HeartbeatConfirmationSeconds = $confirmationSeconds
                }
            }
            if ($settings.PSObject.Properties.Name -contains 'HealthHeartbeatSeconds') {
                $heartbeatSeconds = [int]$settings.HealthHeartbeatSeconds
                if ($heartbeatSeconds -gt 0) {
                    $recoverySettings.HealthHeartbeatSeconds = $heartbeatSeconds
                }
            }
        }
    } catch {}

    $recoverySettings.HeartbeatConfirmationSeconds = Get-EffectiveHeartbeatConfirmationSeconds `
        -ConfiguredSeconds $recoverySettings.HeartbeatConfirmationSeconds `
        -HeartbeatSeconds $recoverySettings.HealthHeartbeatSeconds `
        -MarginSeconds 5
    return [pscustomobject]$recoverySettings
}

function Get-EffectiveHeartbeatConfirmationSeconds {
    param(
        [int]$ConfiguredSeconds = 10,
        [int]$HeartbeatSeconds = 30,
        [int]$MarginSeconds = 5
    )

    $safeConfiguredSeconds = [Math]::Max(0, $ConfiguredSeconds)
    $safeHeartbeatSeconds = [Math]::Max(1, $HeartbeatSeconds)
    $safeMarginSeconds = [Math]::Max(0, $MarginSeconds)
    return [Math]::Max($safeConfiguredSeconds, $safeHeartbeatSeconds + $safeMarginSeconds)
}

function ConvertFrom-WindowsCommandLine {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return @()
    }

    if ($null -eq ('AIUsageGauge.CommandLineNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AIUsageGauge
{
    public static class CommandLineNative
    {
        [DllImport("shell32.dll", SetLastError = true)]
        public static extern IntPtr CommandLineToArgvW(
            [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
            out int argumentCount);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LocalFree(IntPtr memory);
    }
}
'@
    }

    $argumentCount = 0
    $argumentVector = [AIUsageGauge.CommandLineNative]::CommandLineToArgvW(
        $CommandLine,
        [ref]$argumentCount
    )
    if ($argumentVector -eq [IntPtr]::Zero -or $argumentCount -le 0) {
        return @()
    }

    try {
        $arguments = New-Object string[] $argumentCount
        for ($index = 0; $index -lt $argumentCount; $index++) {
            $argumentPointer = [System.Runtime.InteropServices.Marshal]::ReadIntPtr(
                $argumentVector,
                $index * [IntPtr]::Size
            )
            $arguments[$index] = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($argumentPointer)
        }
        return $arguments
    } finally {
        [void][AIUsageGauge.CommandLineNative]::LocalFree($argumentVector)
    }
}

function Test-GaugeProcessCommandLine {
    param(
        [string]$CommandLine,
        [string]$ExpectedScriptPath = (Join-Path $ScriptDir 'Start-AIUsageGauge.ps1')
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    try {
        $arguments = @(ConvertFrom-WindowsCommandLine $CommandLine)
    } catch {
        return $false
    }
    if ($arguments.Count -lt 3) {
        return $false
    }

    $executable = $arguments[0]
    try {
        $executableName = [System.IO.Path]::GetFileName($executable)
        $canonicalExpectedScriptPath = [System.IO.Path]::GetFullPath($ExpectedScriptPath)
    } catch {
        return $false
    }
    if ($executableName -notmatch '^(?i:pwsh|powershell)(?:\.exe)?$') {
        return $false
    }

    for ($index = 1; $index -lt $arguments.Count;) {
        $argument = $arguments[$index]
        if ($argument -ieq '-File') {
            if ($index + 1 -ge $arguments.Count) {
                return $false
            }
            try {
                $canonicalScriptTarget = [System.IO.Path]::GetFullPath($arguments[$index + 1])
            } catch {
                return $false
            }
            return $canonicalScriptTarget.Equals(
                $canonicalExpectedScriptPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

        if ($argument -iin @('-NoLogo', '-NoProfile', '-STA', '-NonInteractive')) {
            $index++
            continue
        }
        if ($argument -ieq '-ExecutionPolicy') {
            if ($index + 1 -ge $arguments.Count -or $arguments[$index + 1] -ine 'Bypass') {
                return $false
            }
            $index += 2
            continue
        }
        if ($argument -ieq '-WindowStyle') {
            if ($index + 1 -ge $arguments.Count -or $arguments[$index + 1] -ine 'Hidden') {
                return $false
            }
            $index += 2
            continue
        }
        return $false
    }

    return $false
}

function ConvertTo-ProcessStartUtcTicks {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        if ($Value -is [DateTimeOffset]) {
            return ([DateTimeOffset]$Value).UtcDateTime.Ticks
        }
        if ($Value -is [DateTime]) {
            return ([DateTimeOffset]::new([DateTime]$Value)).UtcDateTime.Ticks
        }

        $text = [string]$Value
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParseExact(
            $text,
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )) {
            return $parsed.UtcDateTime.Ticks
        }

        if ($text -match '^\d{14}\.\d{6}[+-]\d{3}$') {
            $dmtfDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($text)
            return ([DateTimeOffset]::new($dmtfDate)).UtcDateTime.Ticks
        }
    } catch {}

    return $null
}

function Get-GaugeHeartbeatStatus {
    param(
        $Process,
        $HealthState,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$StaleMinutes = 10,
        [int]$StartupGraceMinutes = 2
    )

    if ($null -eq $HealthState) {
        return 'missing'
    }

    $schemaVersion = 0
    if (-not [int]::TryParse([string]$HealthState.schemaVersion, [ref]$schemaVersion) -or
        $schemaVersion -ne 1) {
        return 'malformed'
    }

    $processId = 0
    $healthPid = 0
    if ($null -eq $Process -or
        -not [int]::TryParse([string]$Process.ProcessId, [ref]$processId) -or
        $processId -le 0 -or
        -not [int]::TryParse([string]$HealthState.pid, [ref]$healthPid) -or
        $healthPid -le 0) {
        return 'malformed'
    }
    if ($healthPid -ne $processId) {
        return 'pid_mismatch'
    }

    $processStartUtcTicks = ConvertTo-ProcessStartUtcTicks $Process.CreationDate
    if ($null -eq $processStartUtcTicks) {
        return 'malformed'
    }

    $healthStartUtcTicks = ConvertTo-ProcessStartUtcTicks $HealthState.processStartedAt
    if ($null -eq $healthStartUtcTicks) {
        return 'malformed'
    }
    $healthBindingDifference = [TimeSpan]::FromTicks([Math]::Abs(
        [long]($processStartUtcTicks - $healthStartUtcTicks)
    ))
    if (($healthBindingDifference.TotalSeconds) -gt 2) {
        return 'pid_mismatch'
    }

    $created = [DateTimeOffset]::new([DateTime]::new(
        $processStartUtcTicks,
        [DateTimeKind]::Utc
    ))
    if (($Now - $created).TotalMinutes -lt $StartupGraceMinutes) {
        return 'startup_grace'
    }

    $heartbeat = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$HealthState.uiHeartbeatAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$heartbeat
    )) {
        return 'malformed'
    }
    if (($Now - $heartbeat).TotalMinutes -gt $StaleMinutes) {
        return 'stale'
    }
    return 'fresh'
}

function Read-GaugeHealthState {
    if (!(Test-Path -LiteralPath $HealthStatePath)) {
        return $null
    }

    try {
        $healthState = Get-Content -LiteralPath $HealthStatePath -Raw | ConvertFrom-Json
        if ($null -ne $healthState) {
            return $healthState
        }
    } catch {}

    return [pscustomobject]@{}
}

function Get-GaugeProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                Test-GaugeProcessCommandLine `
                    -CommandLine ([string]$_.CommandLine) `
                    -ExpectedScriptPath $GaugeScriptPath
            }
    )
}

function Start-GaugeHidden {
    if (!(Test-Path -LiteralPath $GaugeHiddenLauncherPath)) {
        Write-WatchdogEvent 'watchdog_gauge_launcher_missing'
        Write-Status 'gauge_launcher_missing'
        return $false
    }

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (!(Test-Path -LiteralPath $wscript)) {
        Write-WatchdogEvent 'watchdog_wscript_missing'
        Write-Status 'wscript_missing'
        return $false
    }

    Start-Process -FilePath $wscript -ArgumentList ('//B //Nologo "{0}"' -f $GaugeHiddenLauncherPath) -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds ([Math]::Max(1, $GaugeStartupWaitSeconds))

    $started = @(Get-GaugeProcesses).Count -gt 0
    Write-WatchdogEvent 'watchdog_gauge_start_attempted' @{ started = $started }
    Write-Status ('gauge_start_attempted:{0}' -f $started)
    return $started
}

function Stop-VerifiedGaugeProcess {
    param(
        [int]$ProcessId,
        [long]$ExpectedProcessStartUtcTicks,
        [string]$ExpectedScriptPath = $GaugeScriptPath
    )

    if ($ProcessId -le 0) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ reason = 'invalid_pid' }
        return 'rejected'
    }

    $verifiedProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $verifiedProcess) {
        Write-WatchdogEvent 'watchdog_stale_process_exited' @{ processId = $ProcessId; reason = 'stop_revalidation_exit' }
        return 'exited'
    }
    if ([int]$verifiedProcess.ProcessId -ne $ProcessId) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'stop_revalidation_pid' }
        return 'rejected'
    }

    $verifiedCreationDate = $verifiedProcess.CreationDate
    $verifiedProcessStartUtcTicks = ConvertTo-ProcessStartUtcTicks $verifiedCreationDate
    if ($null -eq $verifiedProcessStartUtcTicks -or
        $verifiedProcessStartUtcTicks -ne $ExpectedProcessStartUtcTicks) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'stop_revalidation_start' }
        return 'rejected'
    }
    if (-not (Test-GaugeProcessCommandLine `
        -CommandLine ([string]$verifiedProcess.CommandLine) `
        -ExpectedScriptPath $ExpectedScriptPath)) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'stop_revalidation_command' }
        return 'rejected'
    }

    Stop-Process -Id $ProcessId -ErrorAction Stop
    Write-WatchdogEvent 'watchdog_stale_stop_confirmed' @{ processId = $ProcessId; reason = 'stale' }
    Wait-Process -Id $ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    return 'stopped'
}

function Invoke-ConfirmedGaugeRecovery {
    param(
        [int]$ProcessId,
        [long]$ExpectedProcessStartUtcTicks,
        [string]$ExpectedScriptPath = $GaugeScriptPath,
        [int]$StaleMinutes,
        [int]$StartupGraceMinutes = 2,
        [int]$ConfirmationSeconds = 35,
        [scriptblock]$QueryProcess = {
            param([int]$ProcessId)
            Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
        },
        [scriptblock]$Sleep = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        },
        [scriptblock]$ReadHealth = { Read-GaugeHealthState },
        [scriptblock]$StopVerified = {
            param(
                [int]$RequestedProcessId,
                [long]$ExpectedStartUtcTicks,
                [string]$CanonicalScriptPath
            )
            Stop-VerifiedGaugeProcess `
                -ProcessId $RequestedProcessId `
                -ExpectedProcessStartUtcTicks $ExpectedStartUtcTicks `
                -ExpectedScriptPath $CanonicalScriptPath
        },
        [scriptblock]$StartHidden = { Start-GaugeHidden | Out-Null },
        [scriptblock]$GetNow = { [DateTimeOffset]::UtcNow },
        [scriptblock]$WriteEvent = {
            param([string]$Event, [hashtable]$Data)
            Write-WatchdogEvent -Event $Event -Data $Data
        },
        [scriptblock]$WriteStatus = {
            param([string]$Message)
            Write-Status -Message $Message
        }
    )

    if ($ProcessId -le 0) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ reason = 'invalid_pid' }
        return
    }

    & $Sleep ([Math]::Max(0, $ConfirmationSeconds))
    $confirmationProcess = & $QueryProcess $ProcessId
    if ($null -eq $confirmationProcess) {
        & $WriteEvent 'watchdog_stale_process_exited' @{ processId = $ProcessId; reason = 'confirmation_exit' }
        & $StartHidden
        return
    }
    if ([int]$confirmationProcess.ProcessId -ne $ProcessId) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'confirmation_pid' }
        return
    }

    $confirmationStartUtcTicks = ConvertTo-ProcessStartUtcTicks $confirmationProcess.CreationDate
    if ($null -eq $confirmationStartUtcTicks -or
        $confirmationStartUtcTicks -ne $ExpectedProcessStartUtcTicks) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'confirmation_start' }
        return
    }
    if (-not (Test-GaugeProcessCommandLine `
        -CommandLine ([string]$confirmationProcess.CommandLine) `
        -ExpectedScriptPath $ExpectedScriptPath)) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'confirmation_command' }
        return
    }

    $confirmationHealth = & $ReadHealth
    $confirmedStatus = Get-GaugeHeartbeatStatus `
        -Process $confirmationProcess `
        -HealthState $confirmationHealth `
        -Now (& $GetNow) `
        -StaleMinutes $StaleMinutes `
        -StartupGraceMinutes $StartupGraceMinutes
    if ($confirmedStatus -ne 'stale') {
        & $WriteEvent 'watchdog_stale_recovered' @{ processId = $ProcessId; reason = $confirmedStatus }
        & $WriteStatus ('gauge_recovered:{0}:{1}' -f $ProcessId, $confirmedStatus)
        return
    }

    $verifiedProcess = & $QueryProcess $ProcessId
    if ($null -eq $verifiedProcess) {
        & $WriteEvent 'watchdog_stale_process_exited' @{ processId = $ProcessId; reason = 'final_exit' }
        & $StartHidden
        return
    }
    if ([int]$verifiedProcess.ProcessId -ne $ProcessId) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'final_pid' }
        return
    }

    $finalStartUtcTicks = ConvertTo-ProcessStartUtcTicks $verifiedProcess.CreationDate
    if ($null -eq $finalStartUtcTicks -or
        $finalStartUtcTicks -ne $ExpectedProcessStartUtcTicks) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'final_start' }
        return
    }
    if (-not (Test-GaugeProcessCommandLine `
        -CommandLine ([string]$verifiedProcess.CommandLine) `
        -ExpectedScriptPath $ExpectedScriptPath)) {
        & $WriteEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'final_command' }
        return
    }

    $finalHealth = & $ReadHealth
    $finalStatus = Get-GaugeHeartbeatStatus `
        -Process $verifiedProcess `
        -HealthState $finalHealth `
        -Now (& $GetNow) `
        -StaleMinutes $StaleMinutes `
        -StartupGraceMinutes $StartupGraceMinutes
    if ($finalStatus -ne 'stale') {
        & $WriteEvent 'watchdog_stale_recovered' @{ processId = $ProcessId; reason = $finalStatus }
        & $WriteStatus ('gauge_recovered:{0}:{1}' -f $ProcessId, $finalStatus)
        return
    }
    $stopResult = & $StopVerified `
        $ProcessId `
        $ExpectedProcessStartUtcTicks `
        $ExpectedScriptPath
    if ($stopResult -in @('stopped', 'exited')) {
        & $StartHidden
    }
}

function Ensure-GaugeRunning {
    $processes = @(Get-GaugeProcesses)
    if ($processes.Count -eq 0) {
        Start-GaugeHidden | Out-Null
        return
    }

    $healthState = Read-GaugeHealthState
    $recoverySettings = Get-WatchdogRecoverySettings
    foreach ($process in $processes) {
        $status = Get-GaugeHeartbeatStatus `
            -Process $process `
            -HealthState $healthState `
            -Now ([DateTimeOffset]::UtcNow) `
            -StaleMinutes $recoverySettings.HealthStaleMinutes `
            -StartupGraceMinutes 2
        if ($status -ne 'fresh') {
            Write-WatchdogEvent 'watchdog_heartbeat_status' @{ processId = [int]$process.ProcessId; reason = $status }
        }
        Write-Status ('gauge_heartbeat:{0}:{1}' -f $process.ProcessId, $status)

        if ($status -ne 'stale') {
            continue
        }

        $expectedProcessStartUtcTicks = ConvertTo-ProcessStartUtcTicks $process.CreationDate
        if ($null -eq $expectedProcessStartUtcTicks) {
            Write-WatchdogEvent 'watchdog_heartbeat_status' @{ processId = [int]$process.ProcessId; reason = 'malformed' }
            continue
        }

        Invoke-ConfirmedGaugeRecovery `
            -ProcessId ([int]$process.ProcessId) `
            -ExpectedProcessStartUtcTicks $expectedProcessStartUtcTicks `
            -ExpectedScriptPath $GaugeScriptPath `
            -StaleMinutes $recoverySettings.HealthStaleMinutes `
            -StartupGraceMinutes 2 `
            -ConfirmationSeconds $recoverySettings.HeartbeatConfirmationSeconds
        return
    }
}

function Test-ClaudeRefreshTaskCurrent {
    try {
        $task = Get-ScheduledTask -TaskPath '\AIUsageGauge\' -TaskName 'ClaudeOAuthRefresh' -ErrorAction Stop
        $action = $task.Actions | Select-Object -First 1
        $expectedWscript = Join-Path $env:WINDIR 'System32\wscript.exe'
        return (
            $null -ne $action -and
            $action.Execute -ieq $expectedWscript -and
            $action.Arguments -like '*Invoke-ClaudeOAuthRefresh-hidden.vbs*' -and
            [bool]$task.Settings.Hidden
        )
    } catch {
        return $false
    }
}

function Ensure-ClaudeRefreshTask {
    if (Test-ClaudeRefreshTaskCurrent) {
        Write-Status 'refresh_task_current'
        return
    }

    if (!(Test-Path -LiteralPath $ClaudeRefreshTaskInstallerPath)) {
        Write-WatchdogEvent 'watchdog_refresh_task_installer_missing'
        Write-Status 'refresh_task_installer_missing'
        return
    }

    try {
        & $ClaudeRefreshTaskInstallerPath -IntervalMinutes 5 -Quiet | Out-Null
        Write-WatchdogEvent 'watchdog_refresh_task_repaired'
        Write-Status 'refresh_task_repaired'
    } catch {
        Write-WatchdogEvent 'watchdog_refresh_task_repair_failed' @{ reason = 'installer_error' }
        Write-Status 'refresh_task_repair_failed'
    }
}

try {
    Ensure-GaugeRunning
    if (-not $SkipClaudeRefreshTaskCheck) {
        Ensure-ClaudeRefreshTask
    } else {
        Write-Status 'refresh_task_check_skipped'
    }
    exit 0
} catch {
    Write-WatchdogEvent 'watchdog_error' @{ reason = 'unhandled' }
    Write-Status 'watchdog_error'
    exit 1
}
