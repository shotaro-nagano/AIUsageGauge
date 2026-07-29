param(
    [switch]$Json,
    [int]$RecentEventCount = 12,
    [string]$ClaudeCredentialsPath = (Join-Path $env:USERPROFILE '.claude\.credentials.json')
)

$ErrorActionPreference = 'Stop'
$ScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}
$EventLogDir = Join-Path $env:LOCALAPPDATA 'AIUsageGauge'
$EventLogPath = Join-Path $EventLogDir 'events.log'
$HealthStatePath = Join-Path $EventLogDir 'health.json'
$WatchdogScriptPath = Join-Path $ScriptDir 'Watch-AIUsageGaugeHealth.ps1'

function Get-ClaudeCredentialExpiry {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            ExpiresAtUtc = $null
            ExpiresAtLocal = $null
            RemainingMinutes = $null
            Expired = $null
        }
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw
        $match = [regex]::Match($text, '"expiresAt"\s*:\s*(\d+)')
        if (-not $match.Success) {
            throw "expiresAt was not found"
        }

        $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$match.Groups[1].Value)
        $remaining = $expiresAt - [DateTimeOffset]::UtcNow
        [pscustomobject]@{
            Exists = $true
            ExpiresAtUtc = $expiresAt.UtcDateTime.ToString('o')
            ExpiresAtLocal = $expiresAt.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
            RemainingMinutes = [int][Math]::Floor($remaining.TotalMinutes)
            Expired = $remaining.TotalSeconds -le 0
        }
    } catch {
        [pscustomobject]@{
            Exists = $true
            ExpiresAtUtc = $null
            ExpiresAtLocal = $null
            RemainingMinutes = $null
            Expired = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-GaugeProcessStatus {
    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match '(?i)(^|\s)-File\s+[''"]?.*Start-AIUsageGauge\.ps1' }
    )

    [pscustomobject]@{
        Running = $processes.Count -gt 0
        Count = $processes.Count
        ProcessIds = @($processes | ForEach-Object { $_.ProcessId })
    }
}

function Get-TaskStatus {
    param(
        [string]$TaskName,
        [string]$TaskPath = '\AIUsageGauge\'
    )

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $action = $task.Actions | Select-Object -First 1
        [pscustomobject]@{
            Exists = $true
            Enabled = [bool]$task.Settings.Enabled
            Hidden = [bool]$task.Settings.Hidden
            Execute = [string]$action.Execute
            Arguments = [string]$action.Arguments
            LastRunTime = if ($info.LastRunTime) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            LastTaskResult = $info.LastTaskResult
            NextRunTime = if ($info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            TriggerTypes = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
        }
    } catch {
        [pscustomobject]@{
            Exists = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-RecentEvents {
    param([int]$Count)

    if (!(Test-Path -LiteralPath $EventLogPath)) {
        return @()
    }

    $events = @()
    foreach ($line in (Get-Content -LiteralPath $EventLogPath -Tail $Count -ErrorAction SilentlyContinue)) {
        try {
            $event = $line | ConvertFrom-Json
            if ($event -isnot [System.Management.Automation.PSCustomObject]) {
                throw 'Event root must be an object.'
            }
            $eventName = [string]$event.event
            if ($eventName -notmatch '^[a-z0-9_]{1,80}$') {
                throw 'Invalid event name.'
            }
            $events += [pscustomobject]@{
                Timestamp = Convert-GaugeHealthTimestamp -Value $event.timestamp
                Event = $eventName
            }
        } catch {}
    }
    return $events
}

function Get-LastHealthEventSummary {
    if (!(Test-Path -LiteralPath $EventLogPath)) {
        return [pscustomobject]@{ Found = $false; Event = $null; Timestamp = $null; Summary = 'health: no events' }
    }

    $eventNames = @(
        'watchdog_gauge_start_attempted',
        'watchdog_refresh_task_repaired',
        'watchdog_refresh_task_repair_failed',
        'refresh_task_repaired',
        'refresh_task_repair_failed',
        'health_watchdog_failed',
        'health_watchdog_invoked',
        'notification_shown',
        'notification_failed'
    )

    try {
        $lines = @(Get-Content -LiteralPath $EventLogPath -Tail 120 -ErrorAction SilentlyContinue)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            try {
                $event = $line | ConvertFrom-Json
                if ($eventNames -contains [string]$event.event) {
                    $timestamp = Convert-GaugeHealthTimestamp -Value $event.timestamp
                    return [pscustomobject]@{
                        Found = $true
                        Event = [string]$event.event
                        Timestamp = $timestamp
                        Summary = ('health: {0} at {1}' -f $event.event, $timestamp)
                    }
                }
            } catch {}
        }
    } catch {}

    [pscustomobject]@{ Found = $false; Event = $null; Timestamp = $null; Summary = 'health: no recent repair events' }
}

function Convert-GaugeHealthTimestamp {
    param(
        $Value,
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) { return $null }
        throw 'Timestamp is required.'
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw 'Timestamp must be a date or non-empty string.'
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        throw 'Timestamp is malformed.'
    }
    $parsed.ToUniversalTime().ToString('o')
}

function Convert-GaugeServiceHealthStatus {
    param($Service)

    if ($Service -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Service health must be an object.'
    }
    $status = [string]$Service.status
    if ($Service.status -isnot [string] -or $status -notin @('starting', 'ok', 'off', 'auth', 'rate_limited', 'unavailable')) {
        throw 'Service health status is invalid.'
    }
    $lastSuccessAt = Convert-GaugeHealthTimestamp -Value $Service.lastSuccessAt -AllowNull
    if ($status -eq 'ok' -and $null -eq $lastSuccessAt) {
        throw 'Successful service health requires a timestamp.'
    }
    [pscustomobject]@{
        Status = $status
        LastSuccessAt = $lastSuccessAt
    }
}

function Get-GaugeHealthStatus {
    $empty = [ordered]@{
        Available = $false
        State = 'missing'
        ProcessId = $null
        ProcessStartedAt = $null
        UiHeartbeatAt = $null
        LastUpdateAttemptAt = $null
        Codex = $null
        Claude = $null
        LastScreenCorrectionAt = $null
    }

    if (!(Test-Path -LiteralPath $HealthStatePath)) {
        return [pscustomobject]$empty
    }

    try {
        $health = Get-Content -Raw -LiteralPath $HealthStatePath | ConvertFrom-Json
        if ($health -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Health root must be an object.'
        }
        $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
        if (-not ($integerTypes | Where-Object { $health.schemaVersion -is $_ }) -or [int64]$health.schemaVersion -ne 1) {
            throw 'Unsupported health schema.'
        }
        if (-not ($integerTypes | Where-Object { $health.pid -is $_ }) -or [int64]$health.pid -le 0 -or [int64]$health.pid -gt [int]::MaxValue) {
            throw 'Invalid process id.'
        }
        $processId = [int]$health.pid
        $processStartedAt = Convert-GaugeHealthTimestamp -Value $health.processStartedAt
        $uiHeartbeatAt = Convert-GaugeHealthTimestamp -Value $health.uiHeartbeatAt
        $lastUpdateAttemptAt = Convert-GaugeHealthTimestamp -Value $health.lastUpdateAttemptAt -AllowNull
        $lastScreenCorrectionAt = Convert-GaugeHealthTimestamp -Value $health.lastScreenCorrectionAt -AllowNull
        $codex = Convert-GaugeServiceHealthStatus $health.codex
        $claude = Convert-GaugeServiceHealthStatus $health.claude

        [pscustomobject]@{
            Available = $true
            State = 'available'
            ProcessId = $processId
            ProcessStartedAt = $processStartedAt
            UiHeartbeatAt = $uiHeartbeatAt
            LastUpdateAttemptAt = $lastUpdateAttemptAt
            Codex = $codex
            Claude = $claude
            LastScreenCorrectionAt = $lastScreenCorrectionAt
        }
    } catch {
        $empty.State = 'malformed'
        [pscustomobject]$empty
    }
}

function Get-AIUsageGaugeStatus {
    [pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        GaugeProcess = Get-GaugeProcessStatus
        GaugeHealth = Get-GaugeHealthStatus
        ClaudeCredentials = Get-ClaudeCredentialExpiry -Path $ClaudeCredentialsPath
        ClaudeOAuthRefreshTask = Get-TaskStatus -TaskName 'ClaudeOAuthRefresh'
        HealthWatchdog = [pscustomobject]@{
            ScriptExists = Test-Path -LiteralPath $WatchdogScriptPath
            HeartbeatTask = 'ClaudeOAuthRefresh'
            Mode = 'piggyback'
        }
        LastHealthEvent = Get-LastHealthEventSummary
        RecentEvents = @(Get-RecentEvents -Count $RecentEventCount)
    }
}

$status = Get-AIUsageGaugeStatus
if ($Json) {
    $status | ConvertTo-Json -Depth 8
    return
}

Write-Host 'AI Usage Gauge status'
Write-Host ('  Gauge running: {0} (count={1})' -f $status.GaugeProcess.Running, $status.GaugeProcess.Count)
Write-Host ('  Gauge heartbeat: state={0}, pid={1}, at={2}' -f $status.GaugeHealth.State, $status.GaugeHealth.ProcessId, $status.GaugeHealth.UiHeartbeatAt)
Write-Host ('  Claude credentials: exists={0}, expired={1}, remainingMinutes={2}, expiresAt={3}' -f $status.ClaudeCredentials.Exists, $status.ClaudeCredentials.Expired, $status.ClaudeCredentials.RemainingMinutes, $status.ClaudeCredentials.ExpiresAtLocal)
Write-Host ('  Claude refresh task: exists={0}, lastResult={1}, nextRun={2}' -f $status.ClaudeOAuthRefreshTask.Exists, $status.ClaudeOAuthRefreshTask.LastTaskResult, $status.ClaudeOAuthRefreshTask.NextRunTime)
Write-Host ('  Watchdog heartbeat: mode={0}, task={1}, scriptExists={2}' -f $status.HealthWatchdog.Mode, $status.HealthWatchdog.HeartbeatTask, $status.HealthWatchdog.ScriptExists)
Write-Host ('  Last health event: {0}' -f $status.LastHealthEvent.Summary)
Write-Host ('  Recent events: {0}' -f @($status.RecentEvents).Count)
foreach ($event in $status.RecentEvents) {
    $eventText = $event | ConvertTo-Json -Compress -Depth 4
    Write-Host ('    {0}' -f $eventText)
}
