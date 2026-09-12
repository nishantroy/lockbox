# Build 5 — tabbed layout candidate

Prepared 2026-09-12. Installed and launched successfully on the owner's paired iPhone at 14:30 PDT on explicit request. Installation did not itself change schedules, authorization or notification settings.

## Included

- Three-tab product structure: **Lockbox**, **People**, **Settings**.
- Lockbox home prioritizes finite Lock now with 30 minutes preselected, 1 hour and custom end; the confirmed absolute end and saved policy are revalidated/frozen.
- Active home distinguishes scheduled **Get some rest** from manual **Focus time**, shows the fixed end, recovery entry and pending changes.
- Tonight/saved-rules status is separate from the primary Lock now flow.
- Wind-down derives from the saved bedtime start and exposes only enabled/lead controls; permission remains explicit.
- Best-effort Live Activity preference defaults on and remains non-authoritative for enforcement/release.
- People truthfully describes trusted recovery while remote transport is unavailable; no fake approval controls.
- Configuration, diagnostics and visible developer escape hatches moved to Settings. No final visual theme/palette was selected.

## Validation

- Luna xhigh integration commit `345bacb`.
- Root SwiftPM: **84 passed**; AmbientKit: **13 passed**.
- Generic simulator build including all extensions: passed.
- Terra medium fresh review: no findings; verdict **OK with notes**.
- Parent bumped identity to `0.1 (5)` and completed a signed generic-device build successfully.

## Remaining device evidence

Focused smoke test of tabs, configuration picker persistence, 30-minute/one-hour/custom Lock now, active origin copy, derived wind-down settings and automatic foreground Live Activity reconciliation. Do not install or modify schedules during an active release-QA interval. Existing build-3/build-4 evidence does not automatically validate this layout/runtime change.
