# Build 11 — Midnight + Start bedtime now QA

Build identity `0.1 (11)`.

This candidate adds the reviewed **Start bedtime now** flow to build 10's Midnight Original production UI. The Tonight card previews and confirms the exact next saved morning opening time, freezes that absolute date through confirmation, uses the saved bedtime policy, creates a bedtime-purpose finite session, and preserves future recurrence. Durable occurrence fences and generation-bound manual-route ownership protect against time-zone changes and stale end callbacks. Notification permission presentation is also truthful for not-requested, granted, and denied states.

Terra medium independently reviewed the exact combined source and reported no P0/P1/P2 findings with an **INSTALL-READY: YES** verdict for bounded signed-device QA. Independent evidence: 100 root tests, 15 AmbientKit tests, production and standalone-gallery simulator builds, contrast/drift audit, generated-project consistency, and clean-tree checks passed.

Physical DeviceActivity timing, reboot/file-protection behavior, authorization transitions, notification delivery, Live Activity lifetime, accessibility, browser/category coverage, and extended reliability remain device QA gates rather than certified behavior.
