# Fable, Health Recovery, and Graphite UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display exact Claude Fable quota below `7d`, remove the Codex short row, apply the approved Graphite UI, recover a confirmed frozen gauge automatically, and keep the window inside an active monitor.

**Architecture:** Keep the existing PowerShell/WPF application structure, but add pure conversion functions for Claude usage and screen clamping so behavior is executable in tests. The gauge writes a fixed-schema token-free heartbeat to `%LOCALAPPDATA%\AIUsageGauge\health.json`; the existing hidden watchdog confirms a stale heartbeat and restarts only the revalidated `Start-AIUsageGauge.ps1` PID. Claude usage moves from a one-token Messages probe to the official endpoint used by Claude Code.

**Tech Stack:** PowerShell 7, WPF, Windows Forms monitor metadata, CIM process inspection, Windows Task Scheduler, JSON, Git/GitHub CLI.

---

## File Map

- Modify `Start-AIUsageGauge.ps1`: Claude usage mapping, Graphite WPF rows and colors, health writer, screen clamping.
- Modify `Watch-AIUsageGaugeHealth.ps1`: heartbeat classification, confirmation, strictly scoped restart.
- Modify `Show-AIUsageGaugeStatus.ps1`: expose sanitized heartbeat diagnostics.
- Modify `settings.json`: add automatic health and screen defaults.
- Modify `Install-AIUsageGauge.ps1`: create the same defaults for fresh installs.
- Modify `README.md` and `docs/README-detailed.md`: document current rows and recovery behavior.
- Modify `tests/Test-AIUsageGauge.ps1`: static security, UI, settings, and watchdog integration assertions.
- Modify `tests/Test-CodexWindowMapping.ps1`: remove UI expectations for the deleted Codex short row.
- Create `tests/Test-ClaudeUsageMapping.ps1`: execute Claude usage conversion behavior.
- Create `tests/Test-VisibleScreenPosition.ps1`: execute monitor-selection and clamping behavior.
- Create `tests/Test-HealthRecovery.ps1`: execute heartbeat classification and process-command matching behavior.

### Task 1: Claude OAuth Usage Mapping

**Files:**
- Create: `tests/Test-ClaudeUsageMapping.ps1`
- Modify: `Start-AIUsageGauge.ps1`
- Modify: `tests/Test-AIUsageGauge.ps1`

- [ ] **Step 1: Write the failing Claude mapping test**

Create an AST-based test that loads only `Clamp-Percent`,
`Convert-ClaudeResetToSeconds`, and `Convert-ClaudeUsageResponse` from the app,
then assert the real response shape:

```powershell
$response = [pscustomobject]@{
    five_hour = [pscustomobject]@{ utilization = 19; resets_at = '2026-07-29T03:50:00Z' }
    seven_day = [pscustomobject]@{ utilization = 4; resets_at = '2026-08-04T23:00:00Z' }
    limits = @(
        [pscustomobject]@{
            kind = 'weekly_scoped'
            percent = 0
            scope = [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Fable' } }
        }
    )
}
$now = [DateTimeOffset]::Parse('2026-07-29T03:20:00Z')
$actual = Convert-ClaudeUsageResponse -UsageResponse $response -Now $now
Assert-Equal 81 $actual.FiveHourRemaining '5h remaining'
Assert-Equal 96 $actual.SevenDayRemaining '7d remaining'
Assert-Equal 100 $actual.FableRemaining 'Fable remaining'
Assert-Equal 1800 $actual.FiveHourReset '5h reset'
Assert-Equal $null (Convert-ClaudeUsageResponse -UsageResponse ([pscustomobject]@{
    five_hour = $response.five_hour; seven_day = $response.seven_day; limits = @()
}) -Now $now).FableRemaining 'missing Fable'
```

Also assert that a present nonnumeric `percent` throws rather than becoming
`100%`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\tests\Test-ClaudeUsageMapping.ps1
```

Expected: FAIL because `Convert-ClaudeUsageResponse` does not exist.

- [ ] **Step 3: Add the minimal pure conversion functions**

Add these functions before `Get-ClaudeUsage`:

```powershell
function Convert-ClaudeResetToSeconds {
    param($ResetAt, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if ($null -eq $ResetAt -or [string]::IsNullOrWhiteSpace([string]$ResetAt)) { return $null }
    $reset = [DateTimeOffset]::Parse([string]$ResetAt)
    return [Math]::Max(0, [int][Math]::Ceiling(($reset - $Now).TotalSeconds))
}

function Convert-ClaudeUsageResponse {
    param($UsageResponse, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    function Convert-Remaining($Value, [string]$Name) {
        if ($null -eq $Value) { return $null }
        try { $used = [double]$Value } catch { throw "$Name must be numeric." }
        return Clamp-Percent ([int][Math]::Round(100 - $used))
    }
    $fable = @($UsageResponse.limits) | Where-Object {
        $_.kind -ieq 'weekly_scoped' -and $_.scope.model.display_name -ieq 'Fable'
    } | Select-Object -First 1
    [pscustomobject]@{
        FiveHourRemaining = Convert-Remaining $UsageResponse.five_hour.utilization 'five_hour.utilization'
        SevenDayRemaining = Convert-Remaining $UsageResponse.seven_day.utilization 'seven_day.utilization'
        FableRemaining = if ($null -eq $fable) { $null } else { Convert-Remaining $fable.percent 'Fable percent' }
        FiveHourReset = Convert-ClaudeResetToSeconds $UsageResponse.five_hour.resets_at $Now
        SevenDayReset = Convert-ClaudeResetToSeconds $UsageResponse.seven_day.resets_at $Now
        UpdatedAt = Get-Date
    }
}
```

- [ ] **Step 4: Replace the Messages probe with the CLI usage GET**

Set `$ClaudeUsageUri = 'https://api.anthropic.com/api/oauth/usage'`, retain the
existing expiry/refresh flow, then replace the POST body and header parsing with:

```powershell
$headers = @{
    Authorization = "Bearer $token"
    'anthropic-client-name' = 'claude-code'
}
$usageResponse = Invoke-RestMethod -Uri $ClaudeUsageUri -Method GET -Headers $headers -TimeoutSec 20
return Convert-ClaudeUsageResponse -UsageResponse $usageResponse
```

Add static assertions that the endpoint is the approved Anthropic host, the
request is GET, and `/v1/messages` is absent from the usage function.

- [ ] **Step 5: Run focused and existing tests and verify GREEN**

```powershell
pwsh -NoProfile -File .\tests\Test-ClaudeUsageMapping.ps1
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
pwsh -NoProfile -File .\tests\Test-CodexWindowMapping.ps1
```

Expected: all three scripts print their `tests passed` message.

- [ ] **Step 6: Commit**

```powershell
git add Start-AIUsageGauge.ps1 tests/Test-ClaudeUsageMapping.ps1 tests/Test-AIUsageGauge.ps1
git commit -m "Read Claude and Fable quota from usage API"
```

### Task 2: Graphite Rows and Codex Long-Only UI

**Files:**
- Modify: `Start-AIUsageGauge.ps1`
- Modify: `tests/Test-AIUsageGauge.ps1`
- Modify: `tests/Test-CodexWindowMapping.ps1`

- [ ] **Step 1: Write failing UI assertions**

Require the static script to contain one Codex `long` row, Claude rows in
`5h`, `7d`, `Fable` order, no `$primaryRow`, no short notification, and the
Graphite palette:

```powershell
Assert-True ($start -notmatch '\$primaryRow') 'Codex short row must be removed'
Assert-True ($start -match "\$weeklyRow\s*=\s*New-Row\s+'long'") 'Codex long row is required'
Assert-True ($start -match "(?s)New-Row\s+'5h'.*New-Row\s+'7d'.*New-Row\s+'Fable'") 'Claude Fable must follow 7d'
Assert-True ($start -match '#16191e') 'Graphite surface is required'
Assert-True ($start -match '#3c424c') 'Graphite border is required'
```

Update the Codex UI block assertion to require only `LongRemaining` and its
guarded notification.

- [ ] **Step 2: Run the UI tests and verify RED**

```powershell
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
pwsh -NoProfile -File .\tests\Test-CodexWindowMapping.ps1
```

Expected: FAIL on the existing short row and missing Fable/Graphite values.

- [ ] **Step 3: Implement the approved rows and calm palette**

Remove `$primaryRow`, add `$claudeFableRow`, and render unavailable Fable data
with the existing `Set-RowUnavailable` helper. Notify only when the value exists:

```powershell
if ($null -ne $cl.FableRemaining) {
    Set-Row $claudeFableRow $cl.FableRemaining
    Notify-IfLowRemaining -Service 'Claude' -Window 'Fable' -RemainingPercent $cl.FableRemaining
} else {
    Set-RowUnavailable $claudeFableRow
}
```

Use a 7 px outer radius, 2 px bar radius, `#16191e` surface, `#3c424c`
border, `#303640` track, `#d8dde5` primary text, and `#aeb7c4` secondary
text. Keep five threshold branches with muted danger-to-healthy values, and use
the row service kind to select the healthy Codex green or Claude bronze.

- [ ] **Step 4: Run all UI and mapping tests and verify GREEN**

```powershell
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
pwsh -NoProfile -File .\tests\Test-CodexWindowMapping.ps1
pwsh -NoProfile -File .\tests\Test-ClaudeUsageMapping.ps1
```

Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
git add Start-AIUsageGauge.ps1 tests/Test-AIUsageGauge.ps1 tests/Test-CodexWindowMapping.ps1
git commit -m "Apply Graphite long and Fable gauge layout"
```

### Task 3: Visible-Screen Clamping

**Files:**
- Create: `tests/Test-VisibleScreenPosition.ps1`
- Modify: `Start-AIUsageGauge.ps1`
- Modify: `tests/Test-AIUsageGauge.ps1`

- [ ] **Step 1: Write the failing pure position tests**

Extract and execute `ConvertTo-VisibleGaugePosition`. Cover an already visible
window, a negative-coordinate monitor, and a removed-monitor offset:

```powershell
$areas = @(
    [pscustomobject]@{ Left = -1920; Top = 0; Right = 0; Bottom = 1040 },
    [pscustomobject]@{ Left = 0; Top = 0; Right = 1920; Bottom = 1040 }
)
$visible = ConvertTo-VisibleGaugePosition -Left 100 -Top 100 -Width 142 -Height 132 -WorkingAreas $areas -Margin 6
Assert-Equal 100 $visible.Left 'visible left'
Assert-False $visible.Corrected 'visible correction'
$recovered = ConvertTo-VisibleGaugePosition -Left 4000 -Top 2000 -Width 142 -Height 132 -WorkingAreas $areas -Margin 6
Assert-True ($recovered.Left -le 1772) 'right clamp'
Assert-True ($recovered.Top -le 902) 'bottom clamp'
Assert-True $recovered.Corrected 'removed monitor correction'
```

- [ ] **Step 2: Run the position test and verify RED**

```powershell
pwsh -NoProfile -File .\tests\Test-VisibleScreenPosition.ps1
```

Expected: FAIL because `ConvertTo-VisibleGaugePosition` is missing.

- [ ] **Step 3: Implement nearest-monitor selection and clamping**

Add a pure function that scores each working area by squared distance from the
desired window center to the nearest point in that rectangle, selects the lowest
score, and clamps the full window with the configured margin. Return `Left`,
`Top`, and `Corrected`.

```powershell
function ConvertTo-VisibleGaugePosition {
    param(
        [double]$Left, [double]$Top, [double]$Width, [double]$Height,
        [array]$WorkingAreas, [double]$Margin = 6
    )
    if ($WorkingAreas.Count -eq 0) {
        return [pscustomobject]@{ Left = $Left; Top = $Top; Corrected = $false }
    }
    $centerX = $Left + ($Width / 2)
    $centerY = $Top + ($Height / 2)
    $area = $WorkingAreas | Sort-Object {
        $nearestX = [Math]::Min([Math]::Max($centerX, [double]$_.Left), [double]$_.Right)
        $nearestY = [Math]::Min([Math]::Max($centerY, [double]$_.Top), [double]$_.Bottom)
        [Math]::Pow($centerX - $nearestX, 2) + [Math]::Pow($centerY - $nearestY, 2)
    } | Select-Object -First 1
    $maxLeft = [Math]::Max([double]$area.Left + $Margin, [double]$area.Right - $Width - $Margin)
    $maxTop = [Math]::Max([double]$area.Top + $Margin, [double]$area.Bottom - $Height - $Margin)
    $safeLeft = [Math]::Min([Math]::Max($Left, [double]$area.Left + $Margin), $maxLeft)
    $safeTop = [Math]::Min([Math]::Max($Top, [double]$area.Top + $Margin), $maxTop)
    [pscustomobject]@{
        Left = $safeLeft
        Top = $safeTop
        Corrected = ([Math]::Abs($safeLeft - $Left) -gt 0.5 -or [Math]::Abs($safeTop - $Top) -gt 0.5)
    }
}
```

Add `Get-GaugeWorkingAreas` that reads
`[System.Windows.Forms.Screen]::AllScreens`, converts working-area corners with
`PresentationSource.FromVisual($window).CompositionTarget.TransformFromDevice`,
and falls back to WPF `SystemParameters.WorkArea`.

Update `Update-Position` to:

```powershell
$base = Get-PetGaugePosition $window.Width $window.Height
$desiredLeft = $base.Left + $script:ManualOffsetX
$desiredTop = $base.Top + $script:ManualOffsetY
$safe = ConvertTo-VisibleGaugePosition -Left $desiredLeft -Top $desiredTop `
    -Width $window.Width -Height $window.Height -WorkingAreas (Get-GaugeWorkingAreas $window) `
    -Margin ([int]$Settings.ScreenMargin)
$window.Left = $safe.Left
$window.Top = $safe.Top
if ($safe.Corrected) {
    $script:ManualOffsetX = $safe.Left - $base.Left
    $script:ManualOffsetY = $safe.Top - $base.Top
    Save-GaugeUiState $script:ManualOffsetX $script:ManualOffsetY
    Write-AIUsageGaugeEvent 'window_position_corrected' @{
        left = [Math]::Round($safe.Left, 1)
        top = [Math]::Round($safe.Top, 1)
    }
}
```

The existing 200 ms position timer provides display-change recovery without a
new visible process or terminal.

- [ ] **Step 4: Run position and regression tests and verify GREEN**

```powershell
pwsh -NoProfile -File .\tests\Test-VisibleScreenPosition.ps1
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
```

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
git add Start-AIUsageGauge.ps1 tests/Test-VisibleScreenPosition.ps1 tests/Test-AIUsageGauge.ps1
git commit -m "Keep the gauge inside active monitors"
```

### Task 4: Token-Free Heartbeat and Confirmed Recovery

**Files:**
- Create: `tests/Test-HealthRecovery.ps1`
- Modify: `Start-AIUsageGauge.ps1`
- Modify: `Watch-AIUsageGaugeHealth.ps1`
- Modify: `tests/Test-AIUsageGauge.ps1`

- [ ] **Step 1: Write failing heartbeat decision tests**

Extract `Test-GaugeProcessCommandLine` and `Get-GaugeHeartbeatStatus` from the
watchdog. Assert strict command matching and each non-destructive state:

```powershell
Assert-True (Test-GaugeProcessCommandLine 'pwsh.exe -File "C:\app\Start-AIUsageGauge.ps1"') 'gauge command'
Assert-False (Test-GaugeProcessCommandLine 'pwsh.exe -File "C:\app\Watch-AIUsageGaugeHealth.ps1"') 'watchdog command'
Assert-False (Test-GaugeProcessCommandLine 'pwsh.exe -Command Start-AIUsageGauge.ps1') 'missing -File'
$now = [DateTimeOffset]::Parse('2026-07-29T04:00:00Z')
$process = [pscustomobject]@{ ProcessId = 42; CreationDate = $now.AddHours(-1) }
Assert-Equal 'missing' (Get-GaugeHeartbeatStatus $process $null $now 10 2) 'missing health'
Assert-Equal 'pid_mismatch' (Get-GaugeHeartbeatStatus $process ([pscustomobject]@{
    pid = 43; uiHeartbeatAt = $now.ToString('o')
}) $now 10 2) 'PID mismatch'
Assert-Equal 'fresh' (Get-GaugeHeartbeatStatus $process ([pscustomobject]@{
    pid = 42; uiHeartbeatAt = $now.AddMinutes(-1).ToString('o')
}) $now 10 2) 'fresh heartbeat'
Assert-Equal 'stale' (Get-GaugeHeartbeatStatus $process ([pscustomobject]@{
    pid = 42; uiHeartbeatAt = $now.AddMinutes(-11).ToString('o')
}) $now 10 2) 'stale heartbeat'
```

- [ ] **Step 2: Run the recovery test and verify RED**

```powershell
pwsh -NoProfile -File .\tests\Test-HealthRecovery.ps1
```

Expected: FAIL because both functions are missing.

- [ ] **Step 3: Add the gauge heartbeat writer**

Use a fixed ordered state with only PID, process start, heartbeat, update times,
service status categories, and screen-correction time. Write no arbitrary error
message. Persist with a per-PID temporary file and atomic replacement:

```powershell
function Write-GaugeHealthState {
    try {
        if (!(Test-Path -LiteralPath $EventLogDir)) {
            New-Item -ItemType Directory -Force -Path $EventLogDir | Out-Null
        }
        $tempPath = "$HealthStatePath.$PID.tmp"
        $script:GaugeHealthState | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $tempPath -Encoding UTF8
        [System.IO.File]::Move($tempPath, $HealthStatePath, $true)
    } catch {
        Write-AIUsageGaugeEvent 'health_state_write_failed'
    }
}
```

Update the heartbeat at the configured interval and set service categories on
success, auth expiry, rate limit, and unavailable paths. API errors do not
restart the UI.

- [ ] **Step 4: Add watchdog classification and confirmed restart**

`Get-GaugeHeartbeatStatus` must return `missing`, `malformed`, `pid_mismatch`,
`startup_grace`, `fresh`, or `stale`. For `stale`, sleep
`HeartbeatConfirmationSeconds`, reread the same PID's state, and proceed only
if it remains stale.

```powershell
function Test-GaugeProcessCommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    return $CommandLine -match '(?i)(^|\s)-File\s+["'']?[^"'']*Start-AIUsageGauge\.ps1["'']?(\s|$)'
}

function Get-GaugeHeartbeatStatus {
    param(
        $Process,
        $HealthState,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$StaleMinutes = 10,
        [int]$StartupGraceMinutes = 2
    )
    if ($null -eq $HealthState) { return 'missing' }
    try { $healthPid = [int]$HealthState.pid } catch { return 'malformed' }
    if ($healthPid -ne [int]$Process.ProcessId) { return 'pid_mismatch' }
    try { $created = [DateTimeOffset]$Process.CreationDate } catch { return 'malformed' }
    if (($Now - $created).TotalMinutes -lt $StartupGraceMinutes) { return 'startup_grace' }
    try { $heartbeat = [DateTimeOffset]::Parse([string]$HealthState.uiHeartbeatAt) } catch { return 'malformed' }
    if (($Now - $heartbeat).TotalMinutes -gt $StaleMinutes) { return 'stale' }
    return 'fresh'
}
```

When screen correction runs after the heartbeat task exists, set
`lastScreenCorrectionAt` to UTC and write the health state in addition to the
token-free event.

Before `Stop-Process`, requery `Win32_Process` by PID and call
`Test-GaugeProcessCommandLine` again:

```powershell
$verified = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
if ($null -eq $verified -or -not (Test-GaugeProcessCommandLine $verified.CommandLine)) {
    Write-WatchdogEvent 'watchdog_stale_revalidation_failed' @{ processId = $ProcessId }
    return $false
}
Stop-Process -Id $ProcessId -ErrorAction Stop
Wait-Process -Id $ProcessId -Timeout 10 -ErrorAction SilentlyContinue
Start-GaugeHidden
```

Missing, malformed, mismatched, and startup-grace states log diagnostics and
never authorize a stop.

- [ ] **Step 5: Run health and full regression tests and verify GREEN**

```powershell
pwsh -NoProfile -File .\tests\Test-HealthRecovery.ps1
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
pwsh -NoProfile -File .\tests\Test-ClaudeUsageMapping.ps1
pwsh -NoProfile -File .\tests\Test-VisibleScreenPosition.ps1
pwsh -NoProfile -File .\tests\Test-CodexWindowMapping.ps1
```

Expected: all pass.

- [ ] **Step 6: Commit**

```powershell
git add Start-AIUsageGauge.ps1 Watch-AIUsageGaugeHealth.ps1 tests/Test-HealthRecovery.ps1 tests/Test-AIUsageGauge.ps1
git commit -m "Recover confirmed frozen gauge processes"
```

### Task 5: Settings, Status, and Documentation

**Files:**
- Modify: `settings.json`
- Modify: `Install-AIUsageGauge.ps1`
- Modify: `Show-AIUsageGaugeStatus.ps1`
- Modify: `README.md`
- Modify: `docs/README-detailed.md`
- Modify: `tests/Test-AIUsageGauge.ps1`

- [ ] **Step 1: Write failing integration assertions**

Require `HealthHeartbeatSeconds: 30`, `HealthStaleMinutes: 10`,
`HeartbeatConfirmationSeconds: 10`, and `ScreenMargin: 6` in both normal and
fresh-install defaults. Require the status script to read `health.json` while
continuing to reject `accessToken`, `refreshToken`, and `Authorization`.

- [ ] **Step 2: Run the integration test and verify RED**

```powershell
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
```

Expected: FAIL on missing settings and status health output.

- [ ] **Step 3: Add defaults and sanitized status output**

Extend the defaults without requiring users to edit JSON. In
`Show-AIUsageGaugeStatus.ps1`, read `health.json` and expose only:

```powershell
[pscustomobject]@{
    ProcessId = $health.pid
    UiHeartbeatAt = $health.uiHeartbeatAt
    LastUpdateAttemptAt = $health.lastUpdateAttemptAt
    Codex = $health.codex
    Claude = $health.claude
    LastScreenCorrectionAt = $health.lastScreenCorrectionAt
}
```

Missing or malformed health data returns a structured unavailable state.

- [ ] **Step 4: Update user documentation**

Document Codex `long` only, Claude `5h / 7d / Fable`, the no-token usage GET,
Graphite display, 30-second heartbeat, confirmed ten-minute freeze recovery,
strict `-File ... Start-AIUsageGauge.ps1` stop scope, and screen clamping.

- [ ] **Step 5: Run all tests and verify GREEN**

```powershell
Get-ChildItem .\tests\*.ps1 | ForEach-Object {
    & pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $($_.Name)" }
}
```

Expected: five test scripts pass with no warnings.

- [ ] **Step 6: Commit**

```powershell
git add settings.json Install-AIUsageGauge.ps1 Show-AIUsageGaugeStatus.ps1 README.md docs/README-detailed.md tests/Test-AIUsageGauge.ps1
git commit -m "Document and expose automatic gauge health"
```

### Task 6: Verification, Deployment, and GitHub Integration

**Files:**
- Verify all edited `.ps1` files
- Deploy changed runtime files to `C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0`

- [ ] **Step 1: Run PowerShell 7 parser verification**

```powershell
$failed = $false
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $failed = $true; $errors | ForEach-Object { Write-Error "$($_.Extent.File): $($_.Message)" } }
}
if ($failed) { exit 1 }
```

Expected: exit 0 with no parser errors. Verify edited Japanese `.ps1` files
retain UTF-8 BOM bytes `EF BB BF`.

- [ ] **Step 2: Run the complete test suite from a clean process**

```powershell
Get-ChildItem .\tests\*.ps1 | Sort-Object Name | ForEach-Object {
    & pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: every test reports passed.

- [ ] **Step 3: Review the branch diff and commit the plan updates**

```powershell
git diff --check
git status --short
git log --oneline --decorate -8
```

Commit any final test-only corrections separately; do not amend previously
verified functional commits.

- [ ] **Step 4: Fast-forward the feature branch into main**

From the primary worktree:

```powershell
git merge --ff-only feature/fable-health-graphite
```

Expected: main advances without a merge commit.

- [ ] **Step 5: Deploy without stopping unrelated PowerShell processes**

Query `Win32_Process`, select only commands matching
`(?i)(^|\s)-File\s+['"]?.*Start-AIUsageGauge\.ps1`, stop those exact PIDs,
copy verified runtime files into the existing install directory, run its
installer quietly, and launch through `wscript.exe //B //Nologo` plus
`Start-AIUsageGauge-hidden.vbs`. Never enumerate a broad path for credentials.

- [ ] **Step 6: Verify the live application**

Confirm:

- exactly one matching gauge process;
- no visible terminal launcher;
- UI Automation text contains Codex `long` and Claude `5h`, `7d`, `Fable`, but
  no Codex `5h`;
- displayed Claude values equal a fresh sanitized `/api/oauth/usage` response;
- `%LOCALAPPDATA%\AIUsageGauge\health.json` advances its heartbeat without
  secret fields;
- window bounds fall inside an active monitor working area;
- the hidden refresh task is ready and its last result is successful;
- event log retention still contains only today and the previous day.

- [ ] **Step 7: Push and verify GitHub**

```powershell
git push origin main
git status --short
git rev-parse HEAD
git rev-parse origin/main
```

Expected: clean status and identical local/remote commit IDs.
