# Build 13 — bounded Live Activity dismissal QA

Build identity `0.1 (13)`.

Build 12 proved that a fire-and-forget ActivityKit task from the DeviceActivity monitor was insufficient. Build 13 tried a deduplicated batch operation with a nominal 750 ms semaphore deadline, but owner device evidence showed the same platform boundary: natural enforcement ended correctly and recurrence remained registered, while the monitor recorded **no matching activity** and the host-created Live Activity stayed stale (“Might be stale”) until Phone Lockbox was reopened. Foreground cleanup then succeeded. This proves the extension cannot enumerate the host-created activity in this architecture; another wait or callback bridge is not an honest fix.

The final source correction removes the monitor ActivityKit termination attempt, bounded wait and presentation diagnostics. Natural enforcement callback behavior is unchanged. App-side ActivityKit helpers remain only for explicit app-owned release/expiry matching and foreground/relaunch stale cleanup. Local Live Activities are now opt-in and default off, including migrated pre-build-14 preferences; an explicit current-version opt-in is preserved. Reliable host-closed ending would require ActivityKit push infrastructure, which is not provisioned.

Terra high and the focused Terra medium gates found no remaining P0/P1/P2 issues. Independent evidence passed 100 root tests, 30 AmbientKit tests, all-extension simulator builds, signed generic-device builds, XcodeGen consistency, and clean-tree checks. Exact merged-tree validation repeated 100 root tests, 30 AmbientKit tests, and a signed build with bundle version 13. Build 13 was installed and launched successfully on the paired iPhone on 2026-09-16 at 16:06 local.

Device QA is still required before any automatic-dismissal claim.

## Build-13 custom-end owner QA finding — source-only candidate

Owner QA also found that choosing a custom end near the 15-minute minimum could show **“A finite system-managed end is not available for Lock now.”** The minute DatePicker had frozen sheet-open bounds with seconds while the coordinator correctly revalidated against the later transaction clock. This was a UX validation failure, not a reason to weaken finite safety.

The source candidate now computes minute-aligned bounds from the picker reference clock (ceil lower at or after 15 minutes, floor upper at or before seven days), rebases them when Custom is chosen, and initializes a roughly 30-minute value inside the range. The coordinator retains authoritative fresh-clock validation of the frozen absolute end and reports actionable too-soon/too-late errors without substitution or fallback. Pure runtime tests cover seconds/exact-minute bounds, DST/calendar behavior, delayed confirmation reasons, and unchanged finite acceptance.

This is not a device pass. The candidate must be installed only in a separately planned owner retest; do not change schedules during a scheduled-release interval.
