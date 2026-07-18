# Codex Window Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display each Codex quota under the correct `5h` or `long` row even when the API changes the primary/secondary ordering or omits one window.

**Architecture:** Add one pure classifier to `Start-AIUsageGauge.ps1` that maps optional API windows by `limit_window_seconds`. Keep the fixed two-row WPF layout, but give missing rows an explicit unavailable renderer so null can never be coerced to a false percentage.

**Tech Stack:** PowerShell 7.6, WPF, PowerShell AST-based test loading, existing script test harness.

---

### Task 1: Classify Codex API Windows by Duration

**Files:**
- Create: `tests/Test-CodexWindowMapping.ps1`
- Modify: `Start-AIUsageGauge.ps1:385-415`

- [ ] **Step 1: Write the failing classifier test**

Create an AST-based test that loads the real `Clamp-Percent` and `Convert-CodexRateLimitWindows` function definitions without starting WPF. Assert that a 604800-second primary window with null secondary maps only to `LongRemaining`, and that the traditional 18000/604800 pair maps to both rows.

```powershell
$requiredFunctions = @('Clamp-Percent', 'Convert-CodexRateLimitWindows')
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in $requiredFunctions) {
    $definition = $functions | Where-Object Name -eq $name | Select-Object -First 1
    Assert-True ($null -ne $definition) "Function $name is missing"
    Invoke-Expression $definition.Extent.Text
}

$weeklyOnly = Convert-CodexRateLimitWindows ([pscustomobject]@{
    primary_window = [pscustomobject]@{ used_percent = 33; limit_window_seconds = 604800; reset_after_seconds = 596050 }
    secondary_window = $null
})
Assert-True ($null -eq $weeklyOnly.ShortRemaining) 'Missing short window must stay unavailable'
Assert-Equal 67 $weeklyOnly.LongRemaining 'Seven-day primary must map to long'
```

- [ ] **Step 2: Run the classifier test and verify RED**

Run: `pwsh -NoProfile -File tests/Test-CodexWindowMapping.ps1`

Expected: FAIL with `Function Convert-CodexRateLimitWindows is missing`.

- [ ] **Step 3: Implement the minimal duration classifier**

Add `Convert-CodexRateLimitWindows` before `Get-CodexUsage`. Iterate over non-null primary and secondary windows, reject non-positive `limit_window_seconds`, classify durations up to 86400 seconds as short and longer durations as long, and return nullable `ShortRemaining`, `LongRemaining`, `ShortReset`, and `LongReset` properties.

Update `Get-CodexUsage` to call the classifier and expose those four properties while preserving `Allowed`, `LimitReached`, `PlanType`, and `UpdatedAt`.

```powershell
$windows = Convert-CodexRateLimitWindows $usage.rate_limit
[pscustomobject]@{
    ShortRemaining = $windows.ShortRemaining
    LongRemaining = $windows.LongRemaining
    ShortReset = $windows.ShortReset
    LongReset = $windows.LongReset
    Allowed = [bool]$usage.rate_limit.allowed
    LimitReached = [bool]$usage.rate_limit.limit_reached
    PlanType = [string]$usage.plan_type
    UpdatedAt = Get-Date
}
```

- [ ] **Step 4: Run the classifier test and verify GREEN**

Run: `pwsh -NoProfile -File tests/Test-CodexWindowMapping.ps1`

Expected: `Codex window mapping tests passed` with exit code 0.

### Task 2: Render Missing Quota Windows Explicitly

**Files:**
- Modify: `tests/Test-CodexWindowMapping.ps1`
- Modify: `Start-AIUsageGauge.ps1:657-664,763-787`

- [ ] **Step 1: Add failing UI contract checks**

Add source assertions requiring `Set-RowUnavailable`, the literal `--`, gray fill `#475569`, null guards around short/long notifications, and `Format-OptionalDuration` for nullable reset values.

```powershell
Assert-True ($source -match 'function Set-RowUnavailable') 'Missing rows need an unavailable renderer'
Assert-True ($source -match "Value\.Text\s*=\s*'--'") 'Unavailable rows must display --'
Assert-True ($source -match "Fill\.Fill\s*=\s*'#475569'") 'Unavailable rows must use a neutral gray fill'
Assert-True ($source -match 'function Format-OptionalDuration') 'Nullable resets need an explicit formatter'
Assert-True ($source -match '\$null -ne \$usage\.ShortRemaining') 'Short notifications must be guarded by availability'
Assert-True ($source -match '\$null -ne \$usage\.LongRemaining') 'Long notifications must be guarded by availability'
```

- [ ] **Step 2: Run the UI contract test and verify RED**

Run: `pwsh -NoProfile -File tests/Test-CodexWindowMapping.ps1`

Expected: FAIL with `Missing rows need an unavailable renderer`.

- [ ] **Step 3: Implement unavailable row rendering**

Add `Set-RowUnavailable` to render a two-pixel gray fill and `--`, and make `Set-Row` restore the normal value color when data returns. Add `Format-OptionalDuration` to return `--` for null and delegate present values to `Format-Duration`.

In `Update-Usage`, render and notify each row only when its corresponding remaining value is present. Format short and long reset values independently and preserve the existing footer order.

```powershell
if ($null -ne $usage.ShortRemaining) {
    Set-Row $primaryRow $usage.ShortRemaining
    Notify-IfLowRemaining -Service 'Codex' -Window '5h' -RemainingPercent $usage.ShortRemaining
} else {
    Set-RowUnavailable $primaryRow
}
```

- [ ] **Step 4: Run focused and full tests**

Run: `pwsh -NoProfile -File tests/Test-CodexWindowMapping.ps1`

Expected: `Codex window mapping tests passed`.

Run: `pwsh -NoProfile -File tests/Test-AIUsageGauge.ps1`

Expected: `AI Usage Gauge tests passed`.

### Task 3: Verify, Deploy, and Publish

**Files:**
- Modify: installed `C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0\Start-AIUsageGauge.ps1`
- Update: Notion AI conversation log entry for the Codex long display issue

- [ ] **Step 1: Run PowerShell parser and repository checks**

Run the PowerShell 7 parser against every repository `.ps1`, then run both tests, `git diff --check`, and inspect `git diff` for token-like content.

Expected: no parser errors, both tests pass, no whitespace errors, and no secrets in the diff.

- [ ] **Step 2: Install the verified script and restart safely**

Copy only the verified `Start-AIUsageGauge.ps1` to the known install directory. Stop only PowerShell processes whose command line matches `-File ... Start-AIUsageGauge.ps1`, start `Start-AIUsageGauge-hidden.vbs`, and confirm exactly one matching process remains.

- [ ] **Step 3: Verify the live API-to-display mapping**

Call the official Codex usage endpoint once without printing the token. Feed only `rate_limit` into the classifier and confirm the current 604800-second window maps to long while short is null. Confirm the installed file hash matches the repository file.

- [ ] **Step 4: Review and publish**

Review the final diff against the design, fix any critical or important findings, commit with `Fix Codex quota window classification`, push `main` to `origin`, and verify `origin/main` points to the local commit.

- [ ] **Step 5: Update shared memory**

Append the implemented behavior, verification evidence, commit hash, and deployment result to the existing Notion page `AI Usage Gauge Codex long表示調査`, without storing credentials or raw API responses.
