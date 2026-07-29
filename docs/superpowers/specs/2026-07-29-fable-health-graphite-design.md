# Fable, Health Recovery, and Graphite UI Design

## Problem

The gauge needs three coordinated changes:

- Codex no longer needs its short-window row, while Claude now needs a Fable
  weekly row below `7d`.
- The current Claude probe spends a token on the Messages API and only exposes
  the generic five-hour and seven-day response headers. It cannot report the
  Fable-specific weekly limit.
- The watchdog only detects a missing process. A live but frozen WPF process can
  leave the gauge stale indefinitely, and saved offsets can place the window
  outside the visible working area after a monitor or DPI change.

The visual treatment is also brighter and more saturated than desired. The
approved direction is the compact, low-saturation Graphite option.

## Usage Data Design

### Codex

- Keep the existing Codex usage request and unordered-window classification.
- Render only the classified long window.
- Remove the short row, short reset text, and short-window notification.
- Keep missing long data as unavailable (`--`); never infer `100%` remaining.

### Claude

- Replace the one-token Messages API probe with the endpoint used by the
  installed Claude CLI: `GET https://api.anthropic.com/api/oauth/usage`.
- Continue reading the OAuth access token only from the known
  `~/.claude/.credentials.json` file and never log or return it.
- Parse `five_hour.utilization` and `seven_day.utilization` as used percentages.
- Locate Fable by selecting a `limits` entry whose `kind` is `weekly_scoped`
  and whose `scope.model.display_name` is `Fable`, case-insensitively. Parse its
  `percent` as the used percentage.
- Convert each available used percentage to remaining percentage with
  `Clamp-Percent (100 - used)`.
- Parse the standard `resets_at` timestamps. The footer keeps the existing
  five-hour and seven-day reset summary; the Fable scoped limit shares the
  weekly group and does not require a third footer value.
- If the Fable entry or any individual utilization value is absent, represent
  that row as unavailable (`--`) and suppress its low-remaining notification.
- Authentication expiry keeps the existing relogin-required state and
  one-click relogin action. Rate limiting and transient failures keep last good
  values with a visible stale state.

The usage endpoint is an official Anthropic endpoint observed in the public
behavior of Claude Code 2.1.209. No traffic is sent outside the existing
approved Anthropic domain.

## Graphite UI Design

- Keep a compact always-on-top WPF window with no taskbar entry.
- Render `Codex rate` with one `long` row, then `Claude rate` with `5h`, `7d`,
  and `Fable` rows in that order. The total row count remains unchanged, so the
  window can retain approximately its current footprint.
- Use a near-neutral graphite surface, a subtle gray border, 7 px outer corner
  radius, tighter 2 px bar radii, and low-contrast secondary text.
- Use muted Codex green and muted Claude bronze for healthy values. Preserve the
  existing five-level remaining-percentage color semantics with calmer red,
  amber, ochre, and sage variants for lower ranges.
- Keep unavailable values gray with `--`; stale values and auth failure remain
  explicit rather than relying on color alone.
- Preserve dragging, right-click close, topmost behavior, notifications, and
  existing reset/footer interactions.

## Health State Design

Add a token-free local state file at
`%LOCALAPPDATA%\AIUsageGauge\health.json`. The gauge updates it atomically and
includes only operational metadata:

- process ID and process start time;
- last UI heartbeat time;
- last update-attempt time;
- last successful Codex and Claude update times;
- current Codex and Claude health categories such as `ok`, `stale`, `auth`,
  `rate_limited`, or `unavailable`;
- last automatic screen correction time.

No token, authorization header, request or response body, prompt, account ID,
or organization ID is stored. The existing event log retention continues to
keep only today and the previous day.

The WPF dispatcher writes a heartbeat at most every 30 seconds. Service update
attempts update their own fields without replacing the other service's state.
Writes use a temporary file followed by an atomic replace/move so the watchdog
never consumes a partially written JSON document.

## Automatic Recovery Design

The existing five-minute hidden health invocation remains the recovery driver.
The watchdog applies targeted rules:

1. If no matching gauge process exists, start it through the hidden VBS launcher
   as today.
2. If a matching process exists and its heartbeat is current, do nothing.
3. If `health.json` is missing, malformed, belongs to another PID, or the
   process is still in its startup grace period, log the condition but do not
   stop any process.
4. If the heartbeat for the same PID is older than ten minutes, wait briefly
   and reread it. This confirmation allows dispatcher timers to recover after
   sleep or resume.
5. Only if the same heartbeat remains stale, reread `Win32_Process` for that PID
   and require its command line to match `-File ... Start-AIUsageGauge.ps1`.
   Stop only that verified PID, wait for exit, and restart through the hidden
   launcher.
6. API errors alone never trigger a process restart. Authentication uses the
   existing refresh/relogin flow, and a broken scheduled refresh task uses the
   existing task repair flow.

Recovery actions and reasons are written to the token-free event log. This is a
deliberate change from the previous policy of never stopping automatically; the
strict command-line and PID revalidation is the safety boundary.

## Visible-Screen Recovery Design

- Calculate the desired position from the desktop companion plus the persisted
  manual offset as today.
- Select the nearest active monitor working area for the desired window bounds.
- Convert monitor bounds into WPF device-independent coordinates and clamp the
  full gauge inside that working area with a small margin.
- Run the clamp on startup, during the existing position timer, after dragging,
  and when Windows reports display settings changes.
- When an automatic correction occurs, recompute the manual offset from the
  current base position and persist the corrected offset. This prevents the old
  off-screen offset from being reapplied on the next timer tick or restart.
- Log only the correction reason and monitor-safe coordinates; no unrelated
  desktop or window data is recorded.

## Error Handling

- Missing individual usage values produce `--`, not a fabricated percentage.
- A malformed present percentage fails that service refresh and retains the
  last good value as stale.
- Health-state write failures do not terminate the UI; they are rate-limited in
  the event log.
- A malformed or stale health file cannot authorize a process stop without a
  live PID and command-line revalidation.
- Monitor enumeration failure falls back to the primary WPF work area.

## Tests

- Claude usage parsing covers five-hour, seven-day, and Fable weekly-scoped
  values, including a missing Fable entry and malformed percentages.
- The Claude request targets only `api.anthropic.com/api/oauth/usage`, uses GET,
  and does not call the Messages API usage probe.
- The Codex UI contains only the long row and does not notify for the removed
  short window.
- The Claude UI contains Fable below `7d`; missing data renders `--` without a
  notification.
- Graphite colors, compact radii, and retained five-level warning semantics are
  covered by focused static assertions.
- Screen-clamping tests cover negative-coordinate monitors, oversized offsets,
  monitor removal, and already-visible positions.
- Watchdog tests cover a fresh heartbeat, missing/malformed/mismatched health
  state, a heartbeat that recovers during confirmation, and a confirmed stale
  heartbeat.
- Process-stop tests require both the exact PID and a command line containing
  `-File ... Start-AIUsageGauge.ps1`; unrelated `pwsh` processes are never
  selected.
- Existing parser, installer, refresh, notification, log-retention, single
  instance, and Codex mapping tests continue to pass under PowerShell 7.

## Deployment

- Preserve UTF-8 BOM on edited PowerShell files that contain Japanese text.
- Run the PowerShell 7 parser against every edited `.ps1` file.
- Run all repository tests before installation.
- Install to the existing desktop location, restart only a process whose command
  line matches `-File ... Start-AIUsageGauge.ps1`, and verify the live WPF text,
  process count, health heartbeat, hidden refresh task, and on-screen bounds.
- Commit implementation separately from this design and push both commits to
  the canonical GitHub repository.
