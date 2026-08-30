# Shared OpenAI Quota Gauge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the current shared OpenAI five-hour and weekly limits as Codex `5h` and `7d` rows.

**Architecture:** Reuse `Convert-CodexRateLimitWindows`, which already classifies optional API windows by duration. Restore the short row only at the WPF rendering boundary, keep each row nullable, and format both reset values independently.

**Tech Stack:** PowerShell 7, WPF, AST-based PowerShell tests, Windows UI Automation.

---

### Task 1: Specify the two-row UI contract

**Files:**
- Modify: `tests/Test-AIUsageGauge.ps1`
- Modify: `tests/Test-CodexWindowMapping.ps1`

- [x] **Step 1: Write the failing static and mapping assertions**

Require one `codex5hRow` labeled `5h`, one `codex7dRow` labeled `7d`, nullable
rendering and low-quota notification for `ShortRemaining` and `LongRemaining`,
and a footer using both optional reset durations.

- [x] **Step 2: Run focused tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\tests\Test-CodexWindowMapping.ps1
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1
```

Expected: assertions fail because the UI still renders only `weeklyRow` as
`long` and does not consume `ShortRemaining`.

### Task 2: Restore the shared-limit rows

**Files:**
- Modify: `Start-AIUsageGauge.ps1`

- [x] **Step 1: Add the Codex rows and fixed height**

Create `codex5hRow = New-Row '5h'` and `codex7dRow = New-Row '7d'` in that
order, initialize both unavailable, and increase the window height enough for
one additional compact row.

- [x] **Step 2: Render both classified windows**

Guard `Set-Row` and `Notify-IfLowRemaining` independently for
`ShortRemaining` and `LongRemaining`; otherwise call `Set-RowUnavailable`.
Set the footer with `Format-OptionalDuration $usage.ShortReset` and
`Format-OptionalDuration $usage.LongReset`.

- [x] **Step 3: Run focused tests and verify GREEN**

Run the two commands from Task 1. Expected: both print their passed message and
exit zero.

### Task 3: Document, deploy, and verify

**Files:**
- Modify: `README.md`
- Modify: `docs/README-detailed.md`

- [x] **Step 1: Replace Codex `long`-only documentation with `5h / 7d` shared-limit behavior**

State that Codex, Work, workspace agents, and the products named by ChatGPT
share these plan limits while the gauge obtains the values from the existing
official usage response.

- [x] **Step 2: Run complete verification**

Run all `tests/Test-*.ps1`, parse all PS1 files with PowerShell 7, verify BOMs,
and run `git diff --check`. Expected: no failures.

- [x] **Step 3: Deploy and restart safely**

Copy owned files to the installed directory. Stop only the single process whose
Windows command line exactly executes the canonical installed
`Start-AIUsageGauge.ps1`, then launch through the existing hidden VBS.

- [x] **Step 4: Verify the live result**

Use UI Automation to confirm Codex `5h` and `7d` values, Claude `5h`, `7d`, and
`Fable`, one gauge process, a fresh heartbeat, and both services `ok`.

- [x] **Step 5: Commit, push, and update the existing Notion log**

Commit the focused change, push `main`, verify local and remote SHAs match, and
append token-free evidence to `AI Usage Gauge Codex long表示調査`.
