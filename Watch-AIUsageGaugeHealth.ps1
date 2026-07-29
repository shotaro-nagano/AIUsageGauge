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
        HeartbeatConfirmationSeconds = 10
    }

    try {
        if (!(Test-Path -LiteralPath $SettingsPath)) {
            return [pscustomobject]$recoverySettings
        }

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
    } catch {}

    return [pscustomobject]$recoverySettings
}

function Test-GaugeProcessCommandLine {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    $argumentPattern = '(?:"(?:[^"]|"")*"|''(?:[^'']|'''')*''|\S+)'
    $arguments = @([regex]::Matches($CommandLine, $argumentPattern) | ForEach-Object { $_.Value })
    if ($arguments.Count -lt 3) {
        return $false
    }

    $executable = $arguments[0]
    if (($executable.StartsWith('"') -and $executable.EndsWith('"')) -or
        ($executable.StartsWith("'") -and $executable.EndsWith("'"))) {
        $executable = $executable.Substring(1, $executable.Length - 2)
    }

    try {
        $executableName = [System.IO.Path]::GetFileName($executable)
    } catch {
        return $false
    }
    if ($executableName -notmatch '^(?i:pwsh|powershell)(?:\.exe)?$') {
        return $false
    }

    for ($index = 1; $index -lt $arguments.Count; $index++) {
        if ($arguments[$index] -iin @(
            '-Command'
            '-c'
            '-CommandWithArgs'
            '-cwa'
            '-EncodedCommand'
            '-e'
            '-ec'
            '-enc'
            '-EncodedArguments'
        )) {
            return $false
        }
        if ($arguments[$index] -ine '-File') {
            continue
        }
        if ($index + 1 -ge $arguments.Count) {
            return $false
        }

        $scriptTarget = $arguments[$index + 1]
        if (($scriptTarget.StartsWith('"') -and $scriptTarget.EndsWith('"')) -or
            ($scriptTarget.StartsWith("'") -and $scriptTarget.EndsWith("'"))) {
            $scriptTarget = $scriptTarget.Substring(1, $scriptTarget.Length - 2)
        }

        try {
            return [System.IO.Path]::GetFileName($scriptTarget) -ieq 'Start-AIUsageGauge.ps1'
        } catch {
            return $false
        }
    }

    return $false
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

    $created = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Process.CreationDate, [ref]$created)) {
        return 'malformed'
    }

    $healthStartedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$HealthState.processStartedAt, [ref]$healthStartedAt)) {
        return 'malformed'
    }
    if ([Math]::Abs(($created - $healthStartedAt).TotalSeconds) -gt 2) {
        return 'pid_mismatch'
    }

    if (($Now - $created).TotalMinutes -lt $StartupGraceMinutes) {
        return 'startup_grace'
    }

    $heartbeat = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$HealthState.uiHeartbeatAt, [ref]$heartbeat)) {
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
            Where-Object { Test-GaugeProcessCommandLine ([string]$_.CommandLine) }
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
        [DateTimeOffset]$ExpectedProcessStartedAt
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

    $verifiedStartedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$verifiedProcess.CreationDate, [ref]$verifiedStartedAt) -or
        [Math]::Abs(($verifiedStartedAt - $ExpectedProcessStartedAt).TotalSeconds) -gt 2) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'stop_revalidation_start' }
        return 'rejected'
    }
    if (-not (Test-GaugeProcessCommandLine ([string]$verifiedProcess.CommandLine))) {
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
        [DateTimeOffset]$ExpectedProcessStartedAt,
        [int]$StaleMinutes,
        [int]$StartupGraceMinutes = 2,
        [int]$ConfirmationSeconds = 10
    )

    if ($ProcessId -le 0) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ reason = 'invalid_pid' }
        return
    }

    Start-Sleep -Seconds ([Math]::Max(0, $ConfirmationSeconds))
    $confirmationProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $confirmationProcess) {
        Write-WatchdogEvent 'watchdog_stale_process_exited' @{ processId = $ProcessId; reason = 'confirmation_exit' }
        Start-GaugeHidden | Out-Null
        return
    }
    if ([int]$confirmationProcess.ProcessId -ne $ProcessId -or
        -not (Test-GaugeProcessCommandLine ([string]$confirmationProcess.CommandLine))) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'confirmation_command' }
        return
    }

    $confirmationStartedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$confirmationProcess.CreationDate, [ref]$confirmationStartedAt) -or
        [Math]::Abs(($confirmationStartedAt - $ExpectedProcessStartedAt).TotalSeconds) -gt 2) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'confirmation_start' }
        return
    }

    $confirmationHealth = Read-GaugeHealthState
    $confirmedStatus = Get-GaugeHeartbeatStatus `
        -Process $confirmationProcess `
        -HealthState $confirmationHealth `
        -Now ([DateTimeOffset]::UtcNow) `
        -StaleMinutes $StaleMinutes `
        -StartupGraceMinutes $StartupGraceMinutes
    if ($confirmedStatus -ne 'stale') {
        Write-WatchdogEvent 'watchdog_stale_recovered' @{ processId = $ProcessId; reason = $confirmedStatus }
        Write-Status ('gauge_recovered:{0}:{1}' -f $ProcessId, $confirmedStatus)
        return
    }

    $verifiedProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $verifiedProcess) {
        Write-WatchdogEvent 'watchdog_stale_process_exited' @{ processId = $ProcessId; reason = 'final_exit' }
        Start-GaugeHidden | Out-Null
        return
    }
    if ([int]$verifiedProcess.ProcessId -ne $ProcessId) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'final_pid' }
        return
    }

    $finalStartedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$verifiedProcess.CreationDate, [ref]$finalStartedAt) -or
        [Math]::Abs(($finalStartedAt - $ExpectedProcessStartedAt).TotalSeconds) -gt 2) {
        Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId; reason = 'final_start' }
        return
    }

    $finalHealth = Read-GaugeHealthState
    $finalStatus = Get-GaugeHeartbeatStatus `
        -Process $verifiedProcess `
        -HealthState $finalHealth `
        -Now ([DateTimeOffset]::UtcNow) `
        -StaleMinutes $StaleMinutes `
        -StartupGraceMinutes $StartupGraceMinutes
    if ($finalStatus -ne 'stale') {
        Write-WatchdogEvent 'watchdog_stale_recovered' @{ processId = $ProcessId; reason = $finalStatus }
        Write-Status ('gauge_recovered:{0}:{1}' -f $ProcessId, $finalStatus)
        return
    }
    $stopResult = Stop-VerifiedGaugeProcess `
        -ProcessId $ProcessId `
        -ExpectedProcessStartedAt $ExpectedProcessStartedAt
    if ($stopResult -in @('stopped', 'exited')) {
        Start-GaugeHidden | Out-Null
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
        Write-WatchdogEvent 'watchdog_heartbeat_status' @{ processId = [int]$process.ProcessId; reason = $status }
        Write-Status ('gauge_heartbeat:{0}:{1}' -f $process.ProcessId, $status)

        if ($status -ne 'stale') {
            continue
        }

        $expectedProcessStartedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$process.CreationDate, [ref]$expectedProcessStartedAt)) {
            Write-WatchdogEvent 'watchdog_heartbeat_status' @{ processId = [int]$process.ProcessId; reason = 'malformed' }
            continue
        }

        Invoke-ConfirmedGaugeRecovery `
            -ProcessId ([int]$process.ProcessId) `
            -ExpectedProcessStartedAt $expectedProcessStartedAt `
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
        Write-WatchdogEvent 'watchdog_refresh_task_current'
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
        Write-WatchdogEvent 'watchdog_refresh_task_check_skipped'
        Write-Status 'refresh_task_check_skipped'
    }
    exit 0
} catch {
    Write-WatchdogEvent 'watchdog_error' @{ reason = 'unhandled' }
    Write-Status 'watchdog_error'
    exit 1
}
