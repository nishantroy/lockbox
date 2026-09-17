# Build 14 — custom end and honest Live Activity defaults

Build identity `0.1 (14)`.

This candidate fixes the owner-observed custom Lock now rejection. Custom picker bounds are minute-aligned safely inside the 15-minute-to-seven-day runtime limits; confirmation uses a fresh clock and gives specific too-soon/too-late guidance while preserving the exact selected absolute end. A selected custom end survives preset round-trips and is never silently replaced. Runtime and OS registration still revalidate the finite end authoritatively.

Build 13 device evidence established that the DeviceActivity extension reports **no matching activity** for the host-created Live Activity. The local background cleanup bridge and its diagnostics have therefore been removed. Live Activities now migrate off once using a single encoded preference record; fresh installs are off, legacy true values fail safe off, and explicit build-14 opt-in persists. Foreground cleanup remains. Settings explains that force-closing can leave an opted-in activity stale until reopen and that reliable host-closed ending requires unprovisioned ActivityKit push infrastructure.

Terra medium accepted the custom-end and cleanup/migration changes with no P0/P1/P2 findings. Independent evidence passed 105 root tests, 30 AmbientKit tests, XcodeGen consistency, all-extension simulator builds, signed generic-device builds, contrast checks, and clean-tree checks. Exact merged-tree validation repeated 105 root tests, 30 AmbientKit tests, and a signed build with bundle version 14.

The first wireless delivery attempt failed with CoreDevice connection reset error 54. A one-time retry installed build 14 successfully on 2026-09-16; automatic launch was denied because the iPhone was locked. Device migration and custom-end behavior still require focused QA.
