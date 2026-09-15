# Build 12 — Live Activity natural-end QA

Build identity `0.1 (12)`.

This focused candidate retains build 11 behavior and fixes its observed presentation defect: a naturally ended lock could leave its Live Activity visible. After durable natural-expiry and Managed Settings reconciliation, the DeviceActivity monitor now best-effort ends activities matching the exact session ID, frozen end, and immutable bedtime/focus kind. Foreground/relaunch also removes past-end focus/bedtime activities with stale—not release-claiming—presentation. Current, future, demo, and mismatched activities are excluded; ActivityKit remains non-authoritative and cannot affect enforcement.

Terra medium independently accepted the two-commit fix with no P0/P1/P2 findings. Its gates passed 100 root tests, 19 AmbientKit tests, all-extension simulator build, and signed generic-device build. Exact merged-tree validation repeated 100 root tests, 19 AmbientKit tests, and a signed build with bundle version 12. The first wireless install attempt failed with CoreDevice connection reset error 54; an immediate retry installed successfully and build 12 launched on the paired iPhone on 2026-09-14 at 17:00 local.

Physical QA must still prove whether iOS permits the monitor extension to enumerate/end the host-created activity and gives its asynchronous task time to complete. If not, foreground/relaunch is the bounded fallback.
