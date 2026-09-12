# R2/R3 safety follow-up — 2026-09-10

Worker: `openai-codex/gpt-5.6-luna`, high reasoning. Scope was limited to shared runtime, coordinator, monitor and runtime tests; no deployment or device state changes were performed by the worker.

Implemented and validated:

- Bounded terminal session/release history with current scheduled suppression retained.
- Bidirectional recovery commitment/session invariants and request-time target validation.
- Full active-session eligibility checks, including protection from newer sessions.
- Transactional schedule-stop decisions and scheduled activation fences for pending edits.
- Saved-policy finite Lock now, expected-end confirmation, semantic policy comparison, OS-registration relaunch checks and rollback ownership.
- Developer unlock releases current committed sessions/prototype state while preserving future configuration.
- Category expansion behavior remains intact; raw category allowance was not replaced with an unsupported exception model.

Validation reported by worker: `swift test` 56 passed; simulator build succeeded; `git diff --check` passed. Parent independently reran the 56 SwiftPM tests, regenerated XcodeGen output, built the simulator target and built/signed the generic iOS device target successfully.

Remaining evidence is physical-device behavior: OS-managed finite manual release, callback timing, relaunch/reboot, recovery after leaving the app, and native category enforcement. Build 3 (`0.1 (3)`) is prepared but has not yet been installed because the paired iPhone is currently unavailable to CoreDevice.
