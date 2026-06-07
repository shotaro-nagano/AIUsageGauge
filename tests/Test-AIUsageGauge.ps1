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

$startScript = Join-Path $RepoRoot 'Start-AIUsageGauge.ps1'
$helperScript = Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh.ps1'
$hiddenRefreshLauncher = Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh-hidden.vbs'
$taskInstaller = Join-Path $RepoRoot 'Install-ClaudeOAuthRefreshTask.ps1'
$statusScript = Join-Path $RepoRoot 'Show-AIUsageGaugeStatus.ps1'
$watchdogScript = Join-Path $RepoRoot 'Watch-AIUsageGaugeHealth.ps1'
$appInstallerScript = Join-Path $RepoRoot 'Install-AIUsageGauge.ps1'
$settingsFile = Join-Path $RepoRoot 'settings.json'

Assert-True (Test-Path -LiteralPath $startScript) 'Start-AIUsageGauge.ps1 is missing'
Assert-True (Test-Path -LiteralPath $helperScript) 'Invoke-ClaudeOAuthRefresh.ps1 is missing'
Assert-True (Test-Path -LiteralPath $hiddenRefreshLauncher) 'Invoke-ClaudeOAuthRefresh-hidden.vbs is missing'
Assert-True (Test-Path -LiteralPath $taskInstaller) 'Install-ClaudeOAuthRefreshTask.ps1 is missing'
Assert-True (Test-Path -LiteralPath $statusScript) 'Show-AIUsageGaugeStatus.ps1 is missing'
Assert-True (Test-Path -LiteralPath $watchdogScript) 'Watch-AIUsageGaugeHealth.ps1 is missing'
Assert-True (Test-Path -LiteralPath $appInstallerScript) 'Install-AIUsageGauge.ps1 is missing'
Assert-True (Test-Path -LiteralPath $settingsFile) 'settings.json is missing'

$start = Get-Content -Raw -LiteralPath $startScript
$helper = Get-Content -Raw -LiteralPath $helperScript
$hiddenLauncher = Get-Content -Raw -LiteralPath $hiddenRefreshLauncher
$installer = Get-Content -Raw -LiteralPath $taskInstaller
$status = Get-Content -Raw -LiteralPath $statusScript
$watchdog = Get-Content -Raw -LiteralPath $watchdogScript
$appInstaller = Get-Content -Raw -LiteralPath $appInstallerScript
$settings = Get-Content -Raw -LiteralPath $settingsFile

Assert-True ($start -match 'Global\\AIUsageGauge') 'Start script must create a named mutex'
Assert-True ($start -match '再ログイン要') 'Expired Claude auth must show a relogin-required label'
Assert-True ($start -notmatch 'Invoke-RestMethod\s+-Uri\s+[''"]https://platform\.claude\.com/v1/oauth/token') 'Gauge must not directly call the Claude OAuth token endpoint'
Assert-True ($start -match 'Invoke-ClaudeOAuthRefresh\.ps1') 'Gauge must delegate Claude OAuth refresh to the helper script'
Assert-True ($start -match 'Invoke-ClaudeOAuthRefresh-hidden\.vbs') 'Gauge must use the hidden refresh launcher for foreground refresh attempts'
Assert-True ($start -notmatch '&\s*\$pwsh\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File\s+\$ClaudeRefreshHelperPath') 'Gauge must not launch pwsh.exe directly for Claude refresh'
Assert-True ($start -match 'Ensure-ClaudeRefreshTask') 'Gauge startup must self-heal the Claude refresh scheduled task'
Assert-True ($start -match 'Write-AIUsageGaugeEvent') 'Gauge must write token-free diagnostic events'
Assert-True ($start -match 'Limit-AIUsageGaugeEventLog') 'Gauge must rotate diagnostic logs'
Assert-True ($start -match 'LogRetentionDays') 'Gauge log rotation must use day-based retention'
Assert-True ($start -match 'Get-EventLogRetentionCutoffDate') 'Gauge log rotation must keep only the configured calendar-day window'
Assert-True ($start -match 'AIUG_TOKEN_EXPIRED') 'Gauge must use stable coded errors for expired Claude auth'
Assert-True ($start -match 'Get-AIUsageGaugeSettings') 'Gauge must load external settings'
Assert-True ($start -match 'settings\.json') 'Gauge settings must live in settings.json'
Assert-True ($start -match 'Save-GaugeUiState') 'Gauge must persist drag position state'
Assert-True ($start -match 'Load-GaugeUiState') 'Gauge must restore persisted drag position state'
Assert-True ($start -match 'Show-AIUsageGaugeNotification') 'Gauge must support Windows notifications'
Assert-True ($start -match 'NotifyIcon') 'Gauge notifications must use a Windows notification mechanism'
Assert-True ($start -match 'Test-NotificationAllowed') 'Gauge must dedupe low-remaining notifications'
Assert-True ($start -match 'stale') 'Gauge must visibly mark stale usage values'
Assert-True ($start -match 'Get-LastHealthEventSummary') 'Gauge UI must expose recent watchdog/repair summary'

Assert-True ($helper -match 'claude-code') 'Helper must discover Claude Code installs dynamically'
Assert-True ($helper -match '--no-session-persistence') 'Helper must avoid persisting probe conversations'
Assert-True ($helper -match 'RefreshWindowSeconds') 'Helper must guard CLI calls behind a local expiry window'
Assert-True ($helper -notmatch 'accessToken|refreshToken') 'Helper must not read token values directly'
Assert-True ($helper -match 'Write-RefreshEvent') 'Helper must write token-free diagnostic events'
Assert-True ($helper -notmatch 'RegisterTaskDefinition') 'Helper must not rewrite scheduled task definitions at runtime'
Assert-True ($helper -match 'Limit-RefreshEventLog') 'Helper must rotate diagnostic logs'
Assert-True ($helper -match 'LogRetentionDays') 'Helper log rotation must use day-based retention'
Assert-True ($helper -match 'Get-EventLogRetentionCutoffDate') 'Helper log rotation must keep only the configured calendar-day window'
Assert-True ($helper -match 'Watch-AIUsageGaugeHealth\.ps1') 'Existing Claude refresh heartbeat must invoke the watchdog'
Assert-True ($helper -match 'SkipClaudeRefreshTaskCheck') 'Refresh heartbeat watchdog call must not recursively repair its own task'

Assert-True ($hiddenLauncher -match 'shell\.Run\s*\(\s*command\s*,\s*0\s*,\s*True\s*\)') 'Hidden launcher must run the refresh helper without showing a terminal'
Assert-True ($installer -match "wscript\.exe") 'Scheduled task must use wscript.exe so refresh checks do not flash a terminal'
Assert-True ($installer -notmatch '\$action\.Path\s*=\s*\$pwsh') 'Scheduled task must not launch pwsh.exe directly'
Assert-True ($installer -match '\[int\]\$IntervalMinutes\s*=\s*5') 'Scheduled task interval should default to 5 minutes'
Assert-True ($installer -match 'Repetition\.Interval') 'Scheduled task must keep a fixed hidden heartbeat that does not need runtime task rewrites'
Assert-True ($installer -match 'Triggers\.Create\(9\)') 'Scheduled task must run at logon as a self-healing fallback'

Assert-True ($status -match 'Get-AIUsageGaugeStatus') 'Status script must expose a structured status function'
Assert-True ($status -notmatch 'accessToken|refreshToken|Authorization') 'Status script must not read or print token values'
Assert-True ($status -match 'expiresAt') 'Status script must report Claude credential expiry metadata'
Assert-True ($status -match 'LastTaskResult') 'Status script must report scheduled task result codes'
Assert-True ($status -match 'RecentEvents') 'Status script must include recent token-free diagnostic events'
Assert-True ($status -match 'Get-LastHealthEventSummary') 'Status script must summarize the latest watchdog/repair event'
Assert-True ($status -match 'LastHealthEvent') 'Status JSON must include latest health event'

Assert-True ($watchdog -match 'Start-AIUsageGauge-hidden\.vbs') 'Watchdog must restart the gauge through the hidden launcher'
Assert-True ($watchdog -match 'Install-ClaudeOAuthRefreshTask\.ps1') 'Watchdog must repair the Claude refresh task'
Assert-True ($watchdog -match '\[switch\]\$SkipClaudeRefreshTaskCheck') 'Watchdog must support skipping refresh task checks when called from that task'
Assert-True ($watchdog -match 'Get-CimInstance\s+Win32_Process') 'Watchdog must inspect running Gauge processes'
Assert-True ($watchdog -match 'Start-AIUsageGauge\.ps1') 'Watchdog process matching must be scoped to Start-AIUsageGauge.ps1'
Assert-True ($watchdog -notmatch 'Stop-Process') 'Watchdog must not kill processes automatically'
Assert-True ($watchdog -match 'Write-WatchdogEvent') 'Watchdog must write token-free diagnostic events'
Assert-True ($watchdog -match 'Limit-WatchdogEventLog') 'Watchdog must rotate diagnostic logs'
Assert-True ($watchdog -match 'LogRetentionDays') 'Watchdog log rotation must use day-based retention'
Assert-True ($watchdog -match 'Get-EventLogRetentionCutoffDate') 'Watchdog log rotation must keep only the configured calendar-day window'

Assert-True ($appInstaller -match 'CreateShortcut') 'Installer must create Windows shortcuts'
Assert-True ($appInstaller -match 'Startup') 'Installer must register startup shortcut'
Assert-True ($appInstaller -match 'Compress-Archive') 'Installer must build a release ZIP'
Assert-True ($appInstaller -match 'Install-ClaudeOAuthRefreshTask\.ps1') 'Installer must install/repair the Claude refresh task'
Assert-True ($appInstaller -notmatch 'accessToken|refreshToken|Authorization') 'Installer must not read or print token values'

Assert-True ($settings -match '"RefreshSeconds"\s*:\s*180') 'Default settings must include RefreshSeconds'
Assert-True ($settings -match '"NotificationThresholdPercent"\s*:\s*10') 'Default settings must include notification threshold'
Assert-True ($settings -match '"StaleAfterMinutes"') 'Default settings must include stale threshold'
Assert-True ($settings -match '"PersistWindowPosition"\s*:\s*true') 'Default settings must enable position persistence'
Assert-True ($settings -match '"EnableNotifications"\s*:\s*true') 'Default settings must enable notifications'
Assert-True ($settings -match '"LogRetentionDays"\s*:\s*2') 'Default settings must keep today and the previous day of events'

Write-Host 'AI Usage Gauge tests passed'
