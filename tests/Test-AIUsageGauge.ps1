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

$tokens = $null
$parseErrors = $null
$startAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $startScript,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) 'Start-AIUsageGauge.ps1 must parse successfully'
$getClaudeUsageAst = $startAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Get-ClaudeUsage'
}, $true)
Assert-True ($null -ne $getClaudeUsageAst) 'Get-ClaudeUsage function is missing'
$getClaudeUsageText = $getClaudeUsageAst.Extent.Text
$updateUsageAst = $startAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Update-Usage'
}, $true)
Assert-True ($null -ne $updateUsageAst) 'Update-Usage function is missing'
$updateUsageText = $updateUsageAst.Extent.Text
$convertVisiblePositionAst = $startAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'ConvertTo-VisibleGaugePosition'
}, $true)
Assert-True ($null -ne $convertVisiblePositionAst) 'ConvertTo-VisibleGaugePosition function is missing'
$getWorkingAreasAst = $startAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Get-GaugeWorkingAreas'
}, $true)
Assert-True ($null -ne $getWorkingAreasAst) 'Get-GaugeWorkingAreas function is missing'
$getWorkingAreasText = $getWorkingAreasAst.Extent.Text
$updatePositionAst = $startAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Update-Position'
}, $true)
Assert-True ($null -ne $updatePositionAst) 'Update-Position function is missing'
$updatePositionText = $updatePositionAst.Extent.Text

Assert-True ($start -match 'Global\\AIUsageGauge') 'Start script must create a named mutex'
Assert-True ($start -match '再ログイン要') 'Expired Claude auth must show a relogin-required label'
Assert-True ($start -notmatch 'Invoke-RestMethod\s+-Uri\s+[''"]https://platform\.claude\.com/v1/oauth/token') 'Gauge must not directly call the Claude OAuth token endpoint'
Assert-True ($start -match '\$ClaudeUsageUri\s*=\s*[''"]https://api\.anthropic\.com/api/oauth/usage[''"]') 'Claude usage must use the approved Anthropic host and path'
Assert-True ($getClaudeUsageText -match 'Invoke-RestMethod\s+-Uri\s+\$ClaudeUsageUri\s+-Method\s+GET\b') 'Get-ClaudeUsage must use Invoke-RestMethod with GET'
Assert-True ($getClaudeUsageText -match '[''"]anthropic-client-name[''"]\s*=\s*[''"]claude-code[''"]') 'Get-ClaudeUsage must identify the Claude Code client'
Assert-True ($getClaudeUsageText -notmatch '/v1/messages') 'Get-ClaudeUsage must not call the Messages endpoint'
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
Assert-True ($getWorkingAreasText -match '\[System\.Windows\.Forms\.Screen\]::AllScreens') 'Gauge must enumerate all active monitor working areas'
Assert-True ($getWorkingAreasText -match 'PresentationSource.*?CompositionTarget' -and $getWorkingAreasText -match 'TransformFromDevice') 'Gauge must transform physical screen coordinates to WPF DIPs when a presentation source is available'
Assert-True ($getWorkingAreasText -match '\[System\.Windows\.SystemParameters\]::WorkArea') 'Gauge must fall back to the WPF working area when screen enumeration or transformation fails'
Assert-True ($getWorkingAreasText -notmatch '(?s)else\s*\{\s*\[pscustomobject\]@\{\s*Left\s*=\s*\[double\]\$workingArea\.Left.*?Bottom\s*=\s*\[double\]\$workingArea\.Bottom') 'A missing DPI transform must not expose Screen.WorkingArea physical pixels as WPF DIPs'
$missingTransformFallbackPattern = '(?s)if\s*\(\$null\s*-eq\s*\$transform\)\s*\{\s*\$fallback\s*=\s*\[System\.Windows\.SystemParameters\]::WorkArea\s*return\s*,\(\[pscustomobject\]@\{\s*Left\s*=\s*\$fallback\.Left\s*Top\s*=\s*\$fallback\.Top\s*Right\s*=\s*\$fallback\.Right\s*Bottom\s*=\s*\$fallback\.Bottom\s*\}\)\s*\}'
Assert-True ($getWorkingAreasText -match $missingTransformFallbackPattern) 'A missing DPI transform must immediately return exactly one WPF SystemParameters.WorkArea'
$missingTransformFallbackIndex = $getWorkingAreasText.IndexOf('if ($null -eq $transform)')
$screenEnumerationIndex = $getWorkingAreasText.IndexOf('[System.Windows.Forms.Screen]::AllScreens')
Assert-True ($missingTransformFallbackIndex -ge 0 -and $screenEnumerationIndex -gt $missingTransformFallbackIndex) 'Screen.AllScreens must only be enumerated after a valid DPI transform is available'
Assert-True ($updatePositionText -match '(?s)\$desiredLeft\s*=\s*\$base\.Left\s*\+\s*\$script:ManualOffsetX.*?\$desiredTop\s*=\s*\$base\.Top\s*\+\s*\$script:ManualOffsetY') 'Position updates must start from the pet base plus persisted manual offsets'
Assert-True ($updatePositionText -match 'ConvertTo-VisibleGaugePosition') 'Update-Position must clamp the desired gauge position to an active monitor'
Assert-True ($updatePositionText -match '(?s)\$screenMargin\s*=\s*6.*?ScreenMargin') 'Position clamping must default ScreenMargin to 6 before Task 5 adds the setting'
Assert-True ($updatePositionText -match '(?s)if\s*\(\$safePosition\.Corrected\)\s*\{.*?\$script:ManualOffsetX\s*=\s*\$safePosition\.Left\s*-\s*\$base\.Left.*?\$script:ManualOffsetY\s*=\s*\$safePosition\.Top\s*-\s*\$base\.Top.*?Save-GaugeUiState.*?window_position_corrected') 'A corrected position must update and persist offsets before writing its diagnostic event'
Assert-True ($start -match 'Update-Position\s+-PersistPosition') 'Drag completion must run clamping before persisting the position'
Assert-True ($start -notmatch '(?is)Get-ChildItem\b.{0,200}(?:auth|credential|\.codex|\.claude)') 'Gauge auth lookup must not scan directories broadly'
Assert-True ($start -match 'Show-AIUsageGaugeNotification') 'Gauge must support Windows notifications'
Assert-True ($start -match 'NotifyIcon') 'Gauge notifications must use a Windows notification mechanism'
Assert-True ($start -match 'Test-NotificationAllowed') 'Gauge must dedupe low-remaining notifications'
Assert-True ($start -match 'stale') 'Gauge must visibly mark stale usage values'
Assert-True ($start -match 'Get-LastHealthEventSummary') 'Gauge UI must expose recent watchdog/repair summary'
Assert-True ($start -notmatch '\$primaryRow\b') 'Codex short row must be removed'
$codexLongRows = [regex]::Matches($start, '(?m)^\s*\$weeklyRow\s*=\s*New-Row\s+''long''\s+0\s+''Codex''\s*$')
Assert-True ($codexLongRows.Count -eq 1) 'Exactly one Codex long row is required'
Assert-True ($start -match '(?s)\$claude5hRow\s*=\s*New-Row\s+''5h''\s+0\s+''Claude''.*?\$claude7dRow\s*=\s*New-Row\s+''7d''\s+0\s+''Claude''.*?\$claudeFableRow\s*=\s*New-Row\s+''Fable''\s+0\s+''Claude''') 'Claude rows must appear in 5h, 7d, Fable order'
$updateUsageDefinitionIndex = $start.IndexOf('function Update-Usage')
Assert-True ($updateUsageDefinitionIndex -gt 0) 'Update-Usage definition must follow row creation'
$rowInitializationText = $start.Substring(0, $updateUsageDefinitionIndex)
$missingUnavailableInitializers = @(
    foreach ($rowName in @('weeklyRow', 'claude5hRow', 'claude7dRow', 'claudeFableRow')) {
        $creationMatch = [regex]::Match($rowInitializationText, '(?m)^\s*\$' + $rowName + '\s*=\s*New-Row\b')
        $unavailableMatch = [regex]::Match($rowInitializationText, '(?m)^\s*Set-RowUnavailable\s+\$' + $rowName + '\s*$')
        if (-not $creationMatch.Success -or -not $unavailableMatch.Success -or $unavailableMatch.Index -le $creationMatch.Index) {
            $rowName
        }
    }
)
Assert-True ($missingUnavailableInitializers.Count -eq 0) ('Every usage row must be initialized as unavailable before Update-Usage. Missing: {0}' -f ($missingUnavailableInitializers -join ', '))
Assert-True ($start -match '#16191e') 'Graphite surface is required'
Assert-True ($start -match '#3c424c') 'Graphite border is required'
Assert-True ($start -match '#303640') 'Graphite track is required'
Assert-True ($start -match '#d8dde5') 'Graphite primary text is required'
Assert-True ($start -match '#aeb7c4') 'Graphite secondary text is required'
foreach ($color in @('#cf5d63', '#c97a55', '#c2a35c', '#94a56d', '#84a98c', '#c59a72')) {
    Assert-True ($start -match [regex]::Escape($color)) "Graphite fill color $color is required"
}
Assert-True ($start -match '\$outer\.CornerRadius\s*=\s*7\b') 'Graphite outer radius must be 7'
Assert-True ($start -match '\$battery\.CornerRadius\s*=\s*2\b') 'Graphite bar radius must be 2'

foreach ($window in @(
    [pscustomobject]@{ Property = 'FiveHourRemaining'; Row = 'claude5hRow'; Label = '5h' }
    [pscustomobject]@{ Property = 'SevenDayRemaining'; Row = 'claude7dRow'; Label = '7d' }
    [pscustomobject]@{ Property = 'FableRemaining'; Row = 'claudeFableRow'; Label = 'Fable' }
)) {
    $guardPattern = '(?s)if\s*\(\s*\$null\s*-ne\s*\$cl\.' + $window.Property + '\s*\)\s*\{\s*Set-Row\s+\$' + $window.Row + '\s+\$cl\.' + $window.Property + '.*?Notify-IfLowRemaining\s+-Service\s+[''"]Claude[''"]\s+-Window\s+[''"]' + $window.Label + '[''"]\s+-RemainingPercent\s+\$cl\.' + $window.Property + '\s*\}\s*else\s*\{\s*Set-RowUnavailable\s+\$' + $window.Row + '\s*\}'
    Assert-True ($updateUsageText -match $guardPattern) "Claude $($window.Label) rendering and notification must be guarded by availability"
}
Assert-True ($updateUsageText -match '(?s)AIUG_TOKEN_EXPIRED.*?Set-RowUnavailable\s+\$claude5hRow.*?Set-RowUnavailable\s+\$claude7dRow.*?Set-RowUnavailable\s+\$claudeFableRow.*?再ログイン要') 'Claude auth expiry must make all three rows unavailable and require relogin'

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
