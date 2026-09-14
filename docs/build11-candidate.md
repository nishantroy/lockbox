# Build 11 — Midnight + Start bedtime now QA

Build identity `0.1 (11)`.

This candidate adds the reviewed **Start bedtime now** flow to build 10's Midnight Original production UI. The Tonight card previews and confirms the exact next saved morning opening time, freezes that absolute date through confirmation, uses the saved bedtime policy, creates a bedtime-purpose finite session, and preserves future recurrence. Durable occurrence fences and generation-bound manual-route ownership protect against time-zone changes and stale end callbacks. Notification permission presentation is also truthful for not-requested, granted, and denied states.

Terra medium independently reviewed the exact combined source and reported no P0/P1/P2 findings with an **INSTALL-READY: YES** verdict for bounded signed-device QA. Independent evidence: 100 root tests, 15 AmbientKit tests, production and standalone-gallery simulator builds, contrast/drift audit, generated-project consistency, and clean-tree checks passed.

Exact merged-tree validation passed: 100 root tests, 15 AmbientKit tests, and the signed generic-device build with bundle version 11. Build 11 was installed and launched successfully on the paired iPhone on 2026-09-14 at 01:58 local.

## Build-11 owner QA update — Live Activity natural-end finding

The owner confirmed that **Start bedtime now** ended at the exact confirmed time, **Get some rest** worked, enforcement survived force-close, and tomorrow's recurrence remained. The same QA also found that the Live Activity did **not** disappear after the naturally ended session. These are owner observations of the installed build-11 device run; they do not certify the source-only fix below.

The source candidate now ends the exact session's app-owned bedtime/focus activity only after the monitor commits natural expiry and replays the effective policy. The host foreground/relaunch path also sweeps past immutable ends as stale presentation, including when terminal history was pruned. ActivityKit remains best-effort and non-authoritative; extension process lifetime and device behavior still require validation.

Physical DeviceActivity timing, reboot/file-protection behavior, authorization transitions, notification delivery, Live Activity lifetime/extension ownership, accessibility, browser/category coverage, and extended reliability remain device QA gates rather than certified behavior.
