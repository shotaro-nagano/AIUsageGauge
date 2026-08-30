# Shared OpenAI Quota Gauge Design

## Context

ChatGPT now presents plan usage as two shared limits covering Codex, Work,
workspace agents, and other listed products: a five-hour limit and a weekly
limit. The official usage response currently supplies both an 18,000-second
window and a 604,800-second window. AI Usage Gauge already classifies these
windows by duration, but its Codex UI intentionally hides the short window.

## Decision

- Keep the section title `Codex rate`.
- Render the classified short window as `5h` and the classified long window as
  `7d`, matching the compact labels already used by the Claude section.
- Preserve duration-based classification; never depend on primary/secondary
  response ordering.
- Render an independently missing window as `--` and omit its notification.
- Format the footer as `reset {short} / {long}` with independent optional reset
  values.
- Notify independently when either Codex window has 10 percent or less
  remaining.
- Increase only the fixed window height required for the extra row.

## Boundaries

Do not change the official `chatgpt.com` request, Codex authentication, Claude
usage, refresh scheduling, watchdog recovery, colors, or placement behavior.
Do not log or display authentication values or raw API responses.

## Verification

- Static UI tests require exactly one Codex `5h` row followed by one `7d` row.
- Mapping tests require nullable rendering and notifications for both classified
  windows and the two-value reset footer.
- Existing mapping tests continue to cover unordered and missing API windows.
- PowerShell 7 parsing, the complete test suite, UTF-8 BOM checks, installed-file
  hashes, health state, and UI Automation text are verified before completion.

