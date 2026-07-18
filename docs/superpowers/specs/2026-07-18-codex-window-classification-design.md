# Codex Window Classification Design

## Problem

The Codex usage API no longer guarantees that `primary_window` is the five-hour
window and `secondary_window` is the long window. A live Plus response returned
a seven-day `primary_window` and a null `secondary_window`. The current gauge
therefore displays the seven-day value as `5h` and converts the missing long
window to a false `100%` value.

## Design

- Treat `primary_window` and `secondary_window` as unordered optional windows.
- Classify each present window from `limit_window_seconds`:
  - up to 24 hours: short (`5h`) row;
  - over 24 hours: long row.
- Preserve the API's `used_percent` and `reset_after_seconds` for the classified
  row, then calculate remaining percent as today.
- Represent an unavailable row with a null remaining value and null reset.
- Render unavailable rows as a gray empty bar with `--`, and render their reset
  value as `--`. Never infer `0% used` from a missing API object.
- Keep the existing two-row layout, colors for available values, notifications,
  refresh interval, Codex authentication flow, and Claude behavior unchanged.

## Error Handling

Missing or null windows are valid API states and do not mark the whole Codex
section stale. A malformed present window still fails the Codex refresh through
the existing catch path so stale data remains visibly marked.

## Tests

- A seven-day primary window with no secondary window maps to `long`, while the
  `5h` row is unavailable.
- Traditional five-hour primary plus seven-day secondary responses map to both
  existing rows.
- Unavailable rows render as `--` and do not trigger low-quota notifications.
- Existing static security and installer checks continue to pass.
