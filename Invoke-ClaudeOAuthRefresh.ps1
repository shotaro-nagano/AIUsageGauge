param(
    [string]$CredentialsPath = (Join-Path $env:USERPROFILE '.claude\.credentials.json'),
    [string]$ClaudeCodeRoot = (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code'),
    [int]$RefreshWindowSeconds = 30,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$EventLogDir = Join-Path $env:LOCALAPPDATA 'AIUsageGauge'
$EventLogPath = Join-Path $EventLogDir 'events.log'
$MaxEventLogBytes = 262144
$HealthWatchdogPath = Join-Path $PSScriptRoot 'Watch-AIUsageGaugeHealth.ps1'

function Limit-RefreshEventLog {
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

function Write-RefreshEvent {
    param(
        [string]$Event,
        [hashtable]$Data = @{}
    )

    try {
        if (!(Test-Path -LiteralPath $EventLogDir)) {
            New-Item -ItemType Directory -Force -Path $EventLogDir | Out-Null
        }

        Limit-RefreshEventLog

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

function Get-CredentialExpiry {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        throw "credentials_not_found"
    }

    $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($null -eq $json.claudeAiOauth -or $null -eq $json.claudeAiOauth.expiresAt) {
        throw "credentials_missing_expiresAt"
    }

    return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$json.claudeAiOauth.expiresAt)
}

function Get-ClaudeCliPath {
    param([string]$Root)

    if (!(Test-Path -LiteralPath $Root)) {
        throw "claude_code_root_not_found"
    }

    $cli = Get-ChildItem -LiteralPath $Root -Recurse -Filter claude.exe -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $cli) {
        throw "claude_cli_not_found"
    }

    return $cli.FullName
}

function Invoke-AIUsageGaugeHealthWatchdog {
    try {
        if (!(Test-Path -LiteralPath $HealthWatchdogPath)) {
            Write-RefreshEvent 'health_watchdog_missing'
            return
        }

        & $HealthWatchdogPath -Quiet -SkipClaudeRefreshTaskCheck | Out-Null
        Write-RefreshEvent 'health_watchdog_invoked'
    } catch {
        Write-RefreshEvent 'health_watchdog_failed' @{ error = $_.Exception.Message }
    }
}

$mutex = [System.Threading.Mutex]::new($false, 'Global\AIUsageGaugeClaudeOAuthRefresh')
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-RefreshEvent 'refresh_already_running'
        Write-Status 'refresh_already_running'
        exit 0
    }

    Invoke-AIUsageGaugeHealthWatchdog

    $now = [DateTimeOffset]::UtcNow
    $expiresAt = Get-CredentialExpiry -Path $CredentialsPath
    $remaining = ($expiresAt - $now).TotalSeconds

    if ($remaining -gt $RefreshWindowSeconds) {
        Write-RefreshEvent 'refresh_skipped_fresh' @{ expiresAt = $expiresAt.ToString('o'); remainingSeconds = [int]$remaining }
        Write-Status ('fresh_until {0:o}' -f $expiresAt)
        exit 0
    }

    $claude = Get-ClaudeCliPath -Root $ClaudeCodeRoot
    Write-RefreshEvent 'refresh_cli_start' @{ expiresAt = $expiresAt.ToString('o') }
    & $claude -p 'Respond with exactly OK.' --output-format text --model haiku --no-session-persistence *> $null
    $cliExit = $LASTEXITCODE
    if ($cliExit -ne 0) {
        Write-RefreshEvent 'refresh_cli_failed' @{ exitCode = $cliExit }
        Write-Status "claude_cli_failed:$cliExit"
        exit $cliExit
    }

    $afterExpiresAt = Get-CredentialExpiry -Path $CredentialsPath
    if ($afterExpiresAt -le ([DateTimeOffset]::UtcNow.AddSeconds($RefreshWindowSeconds))) {
        Write-RefreshEvent 'refresh_did_not_extend_credentials' @{ expiresAt = $afterExpiresAt.ToString('o') }
        Write-Status 'refresh_did_not_extend_credentials'
        exit 20
    }

    Write-RefreshEvent 'refresh_cli_success' @{ expiresAt = $afterExpiresAt.ToString('o') }
    Write-Status ('refreshed_until {0:o}' -f $afterExpiresAt)
    exit 0
} catch {
    Write-RefreshEvent 'refresh_helper_error' @{ error = $_.Exception.Message }
    Write-Status $_.Exception.Message
    exit 1
} finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
