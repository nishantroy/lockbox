# Build 13 — bounded Live Activity dismissal QA

Build identity `0.1 (13)`.

Build 12 proved that a fire-and-forget ActivityKit task from the DeviceActivity monitor was insufficient: enforcement ended correctly, but the Live Activity remained stale. Build 13 retains exact session/end/kind matching and replaces that task with one deduplicated batch operation and one configured nominal 750 ms semaphore deadline after durable natural expiry and Managed Settings replay. The deadline is not a wall-clock guarantee under extension preemption or watchdog termination. ActivityKit remains presentation-only and cannot delay enforcement before release, roll it back, or change recurrence.

Privacy-minimal Developer diagnostics report only aggregate ended/no-match/timeout/failure results. Their App Group read/modify/write uses a separate nonblocking `flock`; contention drops diagnostics immediately. A nonblocking in-process fallback is used only when the App Group lock URL is unavailable. Diagnostics never enter the enforcement transaction or persist session identities, selections, tokens, or raw errors.

Terra high and the focused Terra medium gates found no remaining P0/P1/P2 issues. Independent evidence passed 100 root tests, 30 AmbientKit tests, all-extension simulator builds, signed generic-device builds, XcodeGen consistency, and clean-tree checks. Exact merged-tree validation repeated 100 root tests, 30 AmbientKit tests, and a signed build with bundle version 13. Build 13 was installed and launched successfully on the paired iPhone on 2026-09-16 at 16:06 local.

Device QA is still required before any automatic-dismissal claim.

## Build-13 custom-end owner QA finding — source-only candidate

Owner QA also found that choosing a custom end near the 15-minute minimum could show **“A finite system-managed end is not available for Lock now.”** The minute DatePicker had frozen sheet-open bounds with seconds while the coordinator correctly revalidated against the later transaction clock. This was a UX validation failure, not a reason to weaken finite safety.

The source candidate now computes minute-aligned bounds from the picker reference clock (ceil lower at or after 15 minutes, floor upper at or before seven days), rebases them when Custom is chosen, and initializes a roughly 30-minute value inside the range. The coordinator retains authoritative fresh-clock validation of the frozen absolute end and reports actionable too-soon/too-late errors without substitution or fallback. Pure runtime tests cover seconds/exact-minute bounds, DST/calendar behavior, delayed confirmation reasons, and unchanged finite acceptance.

This is not a device pass. The candidate must be installed only in a separately planned owner retest; do not change schedules during a scheduled-release interval.
