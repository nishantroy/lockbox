# Build 13 — bounded Live Activity dismissal QA

Build identity `0.1 (13)`.

Build 12 proved that a fire-and-forget ActivityKit task from the DeviceActivity monitor was insufficient: enforcement ended correctly, but the Live Activity remained stale. Build 13 retains exact session/end/kind matching and replaces that task with one deduplicated batch operation and one configured nominal 750 ms semaphore deadline after durable natural expiry and Managed Settings replay. The deadline is not a wall-clock guarantee under extension preemption or watchdog termination. ActivityKit remains presentation-only and cannot delay enforcement before release, roll it back, or change recurrence.

Privacy-minimal Developer diagnostics report only aggregate ended/no-match/timeout/failure results. Their App Group read/modify/write uses a separate nonblocking `flock`; contention drops diagnostics immediately. A nonblocking in-process fallback is used only when the App Group lock URL is unavailable. Diagnostics never enter the enforcement transaction or persist session identities, selections, tokens, or raw errors.

Terra high and the focused Terra medium gates found no remaining P0/P1/P2 issues. Independent evidence passed 100 root tests, 30 AmbientKit tests, all-extension simulator builds, signed generic-device builds, XcodeGen consistency, and clean-tree checks. Device QA is still required before any automatic-dismissal claim.
