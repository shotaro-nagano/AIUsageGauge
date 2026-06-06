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
$MaxEventLogBytes = 262144

function Limit-WatchdogEventLog {
    try {
        if (!(Test-Path -LiteralPath $EventLogPath)) {
            return
        }

        $logItem = Get-Item -LiteralPath $EventLogPath -ErrorAction Stop
        if ($logItem.Length -le $MaxEventLogBytes) {
            return
        }

        $tail = Get-Content -LiteralPath $EventLogPath -Tail 500 -ErrorAction Stop
        $tempPath = "$EventLogPath.tmp"
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

function Get-GaugeProcesses {
    $gaugeScriptPattern = [regex]::Escape($GaugeScriptName)
    @(
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "(?i)(^|\s)-File\s+['""]?.*$gaugeScriptPattern" }
    )
}

function Ensure-GaugeRunning {
    $processes = @(Get-GaugeProcesses)
    if ($processes.Count -gt 0) {
        Write-WatchdogEvent 'watchdog_gauge_running' @{ count = $processes.Count }
        Write-Status ('gauge_running:{0}' -f $processes.Count)
        return
    }

    if (!(Test-Path -LiteralPath $GaugeHiddenLauncherPath)) {
        Write-WatchdogEvent 'watchdog_gauge_launcher_missing'
        Write-Status 'gauge_launcher_missing'
        return
    }

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (!(Test-Path -LiteralPath $wscript)) {
        Write-WatchdogEvent 'watchdog_wscript_missing'
        Write-Status 'wscript_missing'
        return
    }

    Start-Process -FilePath $wscript -ArgumentList ('//B //Nologo "{0}"' -f $GaugeHiddenLauncherPath) -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds ([Math]::Max(1, $GaugeStartupWaitSeconds))

    $started = @(Get-GaugeProcesses).Count -gt 0
    Write-WatchdogEvent 'watchdog_gauge_start_attempted' @{ started = $started }
    Write-Status ('gauge_start_attempted:{0}' -f $started)
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
        Write-WatchdogEvent 'watchdog_refresh_task_repair_failed' @{ error = $_.Exception.Message }
        Write-Status ('refresh_task_repair_failed:{0}' -f $_.Exception.Message)
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
    Write-WatchdogEvent 'watchdog_error' @{ error = $_.Exception.Message }
    Write-Status ('watchdog_error:{0}' -f $_.Exception.Message)
    exit 1
}
