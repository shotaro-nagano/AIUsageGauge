param(
    [int]$RefreshSeconds = 180,
    [ValidateSet('left','right')]
    [string]$Placement = 'left'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}

$createdNew = $false
$script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, 'Global\AIUsageGauge', [ref]$createdNew)
if (-not $createdNew) {
    $script:SingleInstanceMutex.Dispose()
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$CodexHome = Join-Path $env:USERPROFILE '.codex'
$AuthPath = Join-Path $CodexHome 'auth.json'
$StatePath = Join-Path $CodexHome '.codex-global-state.json'
$UsageUri = 'https://chatgpt.com/backend-api/wham/usage'
$ClaudeConfigDir = if ([string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
    Join-Path $env:USERPROFILE '.claude'
} else {
    $env:CLAUDE_CONFIG_DIR
}
$ClaudeCredsPath = Join-Path $ClaudeConfigDir '.credentials.json'
$ClaudeApiUri = 'https://api.anthropic.com/v1/messages'
$ClaudeRefreshHelperPath = Join-Path $ScriptDir 'Invoke-ClaudeOAuthRefresh.ps1'
$script:ClaudeRefreshAttemptedAt = [DateTimeOffset]::MinValue  # 最後に refresh を試みた時刻
$script:ClaudeNeedsRelogin = $false

# --- Option B: refresh 状態を永続化（再起動しても連打しないための backoff）---
$RefreshStateDir = Join-Path $env:LOCALAPPDATA 'AIUsageGauge'
$RefreshStatePath = Join-Path $RefreshStateDir 'claude-refresh-state.json'

function Get-RefreshState {
    try {
        if (Test-Path -LiteralPath $RefreshStatePath) {
            return Get-Content -LiteralPath $RefreshStatePath -Raw | ConvertFrom-Json
        }
    } catch {}
    return [pscustomobject]@{ backoffUntil = $null; lastSuccess = $null }
}

function Set-RefreshState($State) {
    try {
        if (!(Test-Path -LiteralPath $RefreshStateDir)) {
            New-Item -ItemType Directory -Force -Path $RefreshStateDir | Out-Null
        }
        $State | ConvertTo-Json | Set-Content -LiteralPath $RefreshStatePath -Encoding UTF8
    } catch {}
}

$script:ManualOffsetX = 0
$script:ManualOffsetY = 0
$script:LastBasePosition = $null

function Clamp-Percent([int]$Value) {
    if ($Value -lt 0) { return 0 }
    if ($Value -gt 100) { return 100 }
    return $Value
}

function Format-Duration([int]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalDays -ge 1) {
        return ('{0}d {1}h' -f [int][Math]::Floor($span.TotalDays), $span.Hours)
    }
    if ($span.TotalHours -ge 1) {
        return ('{0}h {1}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
    }
    return ('{0}m' -f [Math]::Max(1, [int][Math]::Ceiling($span.TotalMinutes)))
}

function Get-FillBrush([int]$RemainingPercent, [string]$Kind) {
    # 残量パーセントで5段階に色分け (短期/長期 共通)
    if ($RemainingPercent -le 10) { return '#dc2626' }  # 赤 (10%以下: 危険)
    if ($RemainingPercent -le 25) { return '#f97316' }  # 濃いオレンジ (25%以下: 警告)
    if ($RemainingPercent -le 50) { return '#fbbf24' }  # 黄色 (50%以下: 注意)
    if ($RemainingPercent -le 75) { return '#84cc16' }  # 黄緑 (75%以下: 良好)
    return '#22c55e'                                     # 緑 (76%以上: 余裕)
}

function Get-CodexUsage {
    if (!(Test-Path -LiteralPath $AuthPath)) {
        throw "Codex auth file was not found: $AuthPath"
    }

    $auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
    $token = $auth.tokens.access_token
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Codex access token was not found in auth.json"
    }

    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
        'User-Agent' = 'AIUsageGauge/0.1'
    }
    $usage = Invoke-RestMethod -Method Get -Uri $UsageUri -Headers $headers -TimeoutSec 20
    $primaryUsed = [int]$usage.rate_limit.primary_window.used_percent
    $weeklyUsed = [int]$usage.rate_limit.secondary_window.used_percent

    [pscustomobject]@{
        PrimaryRemaining = Clamp-Percent (100 - $primaryUsed)
        WeeklyRemaining = Clamp-Percent (100 - $weeklyUsed)
        PrimaryReset = [int]$usage.rate_limit.primary_window.reset_after_seconds
        WeeklyReset = [int]$usage.rate_limit.secondary_window.reset_after_seconds
        Allowed = [bool]$usage.rate_limit.allowed
        LimitReached = [bool]$usage.rate_limit.limit_reached
        PlanType = [string]$usage.plan_type
        UpdatedAt = Get-Date
    }
}

function Invoke-ClaudeTokenRefresh($Creds) {
    if (!(Test-Path -LiteralPath $ClaudeRefreshHelperPath)) {
        throw "Claude OAuth refresh helper was not found: $ClaudeRefreshHelperPath"
    }

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ClaudeRefreshHelperPath `
        -CredentialsPath $ClaudeCredsPath `
        -RefreshWindowSeconds 30 `
        -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "claude_cli_refresh_failed:$LASTEXITCODE"
    }

    $updatedCreds = Get-Content -LiteralPath $ClaudeCredsPath -Raw | ConvertFrom-Json
    $token = $updatedCreds.claudeAiOauth.accessToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Claude access token was not found after CLI refresh"
    }

    return $token
}


function Get-ClaudeUsage {
    if (!(Test-Path -LiteralPath $ClaudeCredsPath)) {
        throw "Claude credentials file was not found: $ClaudeCredsPath"
    }

    $creds = Get-Content -LiteralPath $ClaudeCredsPath -Raw | ConvertFrom-Json
    $token = $creds.claudeAiOauth.accessToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Claude access token was not found in .credentials.json"
    }

    # --- Option B: 先回り refresh + ファイル再読込 + 429 バックオフ ---
    $now = [DateTimeOffset]::UtcNow
    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($creds.claudeAiOauth.expiresAt)
    # Claude CLI は残り30秒以下で同期 refresh するため、直接エンドポイントは叩かずCLIに任せる
    $needRefresh = $now -gt $expiresAt.AddSeconds(-30)

    if ($needRefresh) {
        # 他クライアント(Claude Code等)が既に更新しているかもしれないので読み直す
        try {
            $creds = Get-Content -LiteralPath $ClaudeCredsPath -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($creds.claudeAiOauth.expiresAt)
            $needRefresh = $now -gt $expiresAt.AddSeconds(-30)
        } catch {}
    }

    if ($needRefresh) {
        $state = Get-RefreshState
        $backoffUntil = if ($state.backoffUntil) { [DateTimeOffset]::Parse($state.backoffUntil) } else { [DateTimeOffset]::MinValue }
        if ($now -lt $backoffUntil) {
            # バックオフ中は refresh を叩かない。完全失効なら使えない
            if ($now -gt $expiresAt) { throw "token_expired" }
        } else {
            try {
                $token = Invoke-ClaudeTokenRefresh $creds
                Set-RefreshState ([pscustomobject]@{ backoffUntil = $null; lastSuccess = $now.ToString('o') })
            } catch {
                $is429 = ($_.Exception.Message -match '429|Too Many|rate')
                $backoff = if ($is429) { $now.AddMinutes(60) } else { $now.AddMinutes(5) }
                Set-RefreshState ([pscustomobject]@{ backoffUntil = $backoff.ToString('o'); lastSuccess = $state.lastSuccess })
                if ($now -gt $expiresAt) { throw "token_expired" }
                # まだ少し有効なら古いトークンのまま続行
            }
        }
    }

    $headers = @{
        Authorization = "Bearer $token"
        'anthropic-version' = '2023-06-01'
        'content-type' = 'application/json'
        'anthropic-client-name' = 'claude-code'
    }
    $body = (@{
        model = 'claude-haiku-4-5-20251001'
        max_tokens = 1
        messages = @(@{ role = 'user'; content = 'hi' })
    } | ConvertTo-Json -Compress)

    $resp = Invoke-WebRequest -Uri $ClaudeApiUri -Method POST -Headers $headers -Body $body -TimeoutSec 20

    $util5h = [double](($resp.Headers['anthropic-ratelimit-unified-5h-utilization'] | Select-Object -First 1) ?? '0')
    $util7d = [double](($resp.Headers['anthropic-ratelimit-unified-7d-utilization'] | Select-Object -First 1) ?? '0')
    $reset5hTs = ($resp.Headers['anthropic-ratelimit-unified-5h-reset'] | Select-Object -First 1)
    $reset7dTs = ($resp.Headers['anthropic-ratelimit-unified-7d-reset'] | Select-Object -First 1)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    [pscustomobject]@{
        FiveHourRemaining = Clamp-Percent ([int]([Math]::Round((1 - $util5h) * 100)))
        SevenDayRemaining = Clamp-Percent ([int]([Math]::Round((1 - $util7d) * 100)))
        FiveHourReset = if ($reset5hTs) { [Math]::Max(0, [long]$reset5hTs - $now) } else { 0 }
        SevenDayReset = if ($reset7dTs) { [Math]::Max(0, [long]$reset7dTs - $now) } else { 0 }
        UpdatedAt = Get-Date
    }
}

function Start-ClaudeRelogin {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $candidates = @(
        (Join-Path $desktop 'Claude再ログイン.lnk'),
        (Join-Path $env:USERPROFILE 'OneDrive\デスクトップ\Claude再ログイン.lnk'),
        (Join-Path $ScriptDir 'Claude-relogin.cmd')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Start-Process -FilePath $candidate
            return
        }
    }
}

function Get-PetGaugePosition($WindowWidth, $WindowHeight) {
    $fallback = [pscustomobject]@{
        Left = [System.Windows.SystemParameters]::WorkArea.Right - $WindowWidth - 24
        Top = [System.Windows.SystemParameters]::WorkArea.Bottom - $WindowHeight - 96
    }

    if (!(Test-Path -LiteralPath $StatePath)) {
        return $fallback
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $atoms = $state.'electron-persisted-atom-state'
        $bounds = $state.'electron-avatar-overlay-bounds'
        if ($null -eq $bounds -and $null -ne $atoms) {
            $bounds = $atoms.'electron-avatar-overlay-bounds'
        }
        if ($null -eq $bounds -or $null -eq $bounds.mascot) {
            if ($null -ne $script:LastBasePosition) { return $script:LastBasePosition }
            return $fallback
        }

        $petLeft = [double]$bounds.x + [double]$bounds.mascot.left
        $petTop = [double]$bounds.y + [double]$bounds.mascot.top
        $petWidth = [double]$bounds.mascot.width
        $petHeight = [double]$bounds.mascot.height

        if ($Placement -eq 'right') {
            $left = $petLeft + $petWidth + 10
        } else {
            $left = $petLeft - $WindowWidth - 10
        }
        $top = $petTop + $petHeight - $WindowHeight

        $basePosition = [pscustomobject]@{ Left = $left; Top = $top }
        $script:LastBasePosition = $basePosition
        $basePosition
    } catch {
        if ($null -ne $script:LastBasePosition) { return $script:LastBasePosition }
        $fallback
    }
}

function New-Row($Label, $InitialPercent, $Kind) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,0,0,2'
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '30' }))
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '34' }))

    $labelBlock = New-Object System.Windows.Controls.TextBlock
    $labelBlock.Text = $Label
    $labelBlock.Foreground = '#e5e7eb'
    $labelBlock.FontSize = 10
    $labelBlock.FontWeight = 'SemiBold'
    $labelBlock.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($labelBlock, 0)
    $row.Children.Add($labelBlock) | Out-Null

    $battery = New-Object System.Windows.Controls.Border
    $battery.Height = 11
    $battery.CornerRadius = 4
    $battery.BorderThickness = 1
    $battery.BorderBrush = '#64748b'
    $battery.Background = '#111827'
    $battery.VerticalAlignment = 'Center'

    $fill = New-Object System.Windows.Shapes.Rectangle
    $fill.Height = 7
    $fill.HorizontalAlignment = 'Left'
    $fill.Margin = '2,1,2,1'
    $fill.RadiusX = 3
    $fill.RadiusY = 3
    $fill.Fill = Get-FillBrush $InitialPercent $Kind

    $battery.Child = $fill
    [System.Windows.Controls.Grid]::SetColumn($battery, 1)
    $row.Children.Add($battery) | Out-Null

    $valueBlock = New-Object System.Windows.Controls.TextBlock
    $valueBlock.Text = "$InitialPercent%"
    $valueBlock.Foreground = '#f8fafc'
    $valueBlock.FontSize = 10
    $valueBlock.FontWeight = 'SemiBold'
    $valueBlock.TextAlignment = 'Right'
    $valueBlock.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($valueBlock, 2)
    $row.Children.Add($valueBlock) | Out-Null

    [pscustomobject]@{
        Root = $row
        Fill = $fill
        Battery = $battery
        Value = $valueBlock
        Kind = $Kind
    }
}

function Set-Row($Row, [int]$Percent) {
    $Percent = Clamp-Percent $Percent
    $innerWidth = [Math]::Max(0, $Row.Battery.ActualWidth - 4)
    if ($innerWidth -eq 0) { $innerWidth = 80 }
    $Row.Fill.Width = [Math]::Max(2, $innerWidth * $Percent / 100)
    $Row.Fill.Fill = Get-FillBrush $Percent $Row.Kind
    $Row.Value.Text = "$Percent%"
}

$window = New-Object System.Windows.Window
$window.Width = 142
$window.Height = 132
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = 'Transparent'
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ResizeMode = 'NoResize'
$window.Title = 'AI Usage Gauge'

$outer = New-Object System.Windows.Controls.Border
$outer.CornerRadius = 10
$outer.Background = '#dd0f172a'
$outer.BorderBrush = '#334155'
$outer.BorderThickness = 1
$outer.Padding = '9,5,9,5'

$stack = New-Object System.Windows.Controls.StackPanel

# --- Codex section ---
$title = New-Object System.Windows.Controls.TextBlock
$title.Text = 'Codex rate'
$title.Foreground = '#cbd5e1'
$title.FontSize = 9
$title.Margin = '0,0,0,2'
$title.ToolTip = 'Left click and drag to move. Right click to close.'
$stack.Children.Add($title) | Out-Null

$primaryRow = New-Row '5h' 0 'primary'
$weeklyRow = New-Row 'long' 0 'week'
$stack.Children.Add($primaryRow.Root) | Out-Null
$stack.Children.Add($weeklyRow.Root) | Out-Null

$footer = New-Object System.Windows.Controls.TextBlock
$footer.Foreground = '#94a3b8'
$footer.FontSize = 8
$footer.Margin = '0,0,0,3'
$footer.Text = 'loading...'
$stack.Children.Add($footer) | Out-Null

# --- Separator ---
$sep = New-Object System.Windows.Controls.Border
$sep.Height = 1
$sep.Background = '#334155'
$sep.Margin = '0,0,0,3'
$stack.Children.Add($sep) | Out-Null

# --- Claude section ---
$claudeTitle = New-Object System.Windows.Controls.TextBlock
$claudeTitle.Text = 'Claude rate'
$claudeTitle.Foreground = '#cbd5e1'
$claudeTitle.FontSize = 9
$claudeTitle.Margin = '0,0,0,2'
$stack.Children.Add($claudeTitle) | Out-Null

$claude5hRow = New-Row '5h' 0 'primary'
$claude7dRow = New-Row '7d' 0 '7d'
$stack.Children.Add($claude5hRow.Root) | Out-Null
$stack.Children.Add($claude7dRow.Root) | Out-Null

$claudeFooter = New-Object System.Windows.Controls.TextBlock
$claudeFooter.Foreground = '#94a3b8'
$claudeFooter.FontSize = 8
$claudeFooter.Margin = '0,0,0,0'
$claudeFooter.Text = 'loading...'
$claudeFooter.Cursor = [System.Windows.Input.Cursors]::Hand
$claudeFooter.ToolTip = 'Click when Claude relogin is required.'
$claudeFooter.Add_MouseLeftButtonUp({
    if ($script:ClaudeNeedsRelogin) {
        Start-ClaudeRelogin
    }
})
$stack.Children.Add($claudeFooter) | Out-Null

$outer.Child = $stack
$window.Content = $outer

$window.Add_MouseLeftButtonDown({
    try {
        $window.DragMove()
        $base = Get-PetGaugePosition $window.Width $window.Height
        $script:ManualOffsetX = $window.Left - $base.Left
        $script:ManualOffsetY = $window.Top - $base.Top
    } catch {}
})
$window.Add_MouseRightButtonUp({
    $window.Close()
})

function Update-Position {
    $pos = Get-PetGaugePosition $window.Width $window.Height
    $window.Left = $pos.Left + $script:ManualOffsetX
    $window.Top = $pos.Top + $script:ManualOffsetY
}

function Update-Usage {
    # Codex
    try {
        $usage = Get-CodexUsage
        Set-Row $primaryRow $usage.PrimaryRemaining
        Set-Row $weeklyRow $usage.WeeklyRemaining
        $footer.Text = ('reset {0} / {1}' -f (Format-Duration $usage.PrimaryReset), (Format-Duration $usage.WeeklyReset))
        if ($usage.LimitReached) {
            $title.Text = 'Codex rate - capped'
            $outer.BorderBrush = '#ef4444'
        } else {
            $title.Text = 'Codex rate'
            $outer.BorderBrush = '#334155'
        }
    } catch {
        $title.Text = 'Codex rate'
        $footer.Text = 'unavailable'
        $outer.BorderBrush = '#ef4444'
    }

    # Claude
    try {
        $cl = Get-ClaudeUsage
        Set-Row $claude5hRow $cl.FiveHourRemaining
        Set-Row $claude7dRow $cl.SevenDayRemaining
        $claudeFooter.Text = ('reset {0} / {1}' -f (Format-Duration $cl.FiveHourReset), (Format-Duration $cl.SevenDayReset))
        $claudeTitle.Text = 'Claude rate'
        $script:ClaudeNeedsRelogin = $false
    } catch {
        $claudeTitle.Text = 'Claude rate'
        $errMsg = $_.Exception.Message
        if ($errMsg -match 'token_expired|401|Unauthorized') {
            Set-Row $claude5hRow 0
            Set-Row $claude7dRow 0
            $claude5hRow.Fill.Fill = '#475569'
            $claude7dRow.Fill.Fill = '#475569'
            $claudeFooter.Text = '🔑 再ログイン要'
            $script:ClaudeNeedsRelogin = $true
        } elseif ($errMsg -match '429|rate.limit|Rate') {
            $claudeFooter.Text = 'refresh limited - retrying...'
            $script:ClaudeNeedsRelogin = $false
        } else {
            $claudeFooter.Text = 'unavailable'
            $script:ClaudeNeedsRelogin = $false
        }
    }
}

$positionTimer = New-Object System.Windows.Threading.DispatcherTimer
$positionTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$positionTimer.Add_Tick({ Update-Position })
$positionTimer.Start()

$usageTimer = New-Object System.Windows.Threading.DispatcherTimer
$usageTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(15, $RefreshSeconds))
$usageTimer.Add_Tick({ Update-Usage })
$usageTimer.Start()

$window.Add_SourceInitialized({
    Update-Position
    Update-Usage
})

try {
    $null = $window.ShowDialog()
} finally {
    if ($script:SingleInstanceMutex) {
        $script:SingleInstanceMutex.ReleaseMutex()
        $script:SingleInstanceMutex.Dispose()
    }
}
