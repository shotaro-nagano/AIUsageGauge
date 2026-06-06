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
            $sensitiveNamePattern = (@('token', ('author' + 'ization'), 'secret') -join '|')
            foreach ($name in @($event.PSObject.Properties.Name)) {
                if ($name -match $sensitiveNamePattern) {
                    $event.PSObject.Properties.Remove($name)
                }
            }
            $events += $event
        } catch {
            $events += [pscustomobject]@{ raw = $line }
        }
    }
    return $events
}

function Get-AIUsageGaugeStatus {
    [pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        GaugeProcess = Get-GaugeProcessStatus
        ClaudeCredentials = Get-ClaudeCredentialExpiry -Path $ClaudeCredentialsPath
        ClaudeOAuthRefreshTask = Get-TaskStatus -TaskName 'ClaudeOAuthRefresh'
        HealthWatchdog = [pscustomobject]@{
            ScriptExists = Test-Path -LiteralPath $WatchdogScriptPath
            HeartbeatTask = 'ClaudeOAuthRefresh'
            Mode = 'piggyback'
        }
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
Write-Host ('  Claude credentials: exists={0}, expired={1}, remainingMinutes={2}, expiresAt={3}' -f $status.ClaudeCredentials.Exists, $status.ClaudeCredentials.Expired, $status.ClaudeCredentials.RemainingMinutes, $status.ClaudeCredentials.ExpiresAtLocal)
Write-Host ('  Claude refresh task: exists={0}, lastResult={1}, nextRun={2}' -f $status.ClaudeOAuthRefreshTask.Exists, $status.ClaudeOAuthRefreshTask.LastTaskResult, $status.ClaudeOAuthRefreshTask.NextRunTime)
Write-Host ('  Watchdog heartbeat: mode={0}, task={1}, scriptExists={2}' -f $status.HealthWatchdog.Mode, $status.HealthWatchdog.HeartbeatTask, $status.HealthWatchdog.ScriptExists)
Write-Host ('  Recent events: {0}' -f @($status.RecentEvents).Count)
foreach ($event in $status.RecentEvents) {
    $eventText = $event | ConvertTo-Json -Compress -Depth 4
    Write-Host ('    {0}' -f $eventText)
}
