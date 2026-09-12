# Phone Lockbox — technical plan

Status: target architecture; a working device prototype now exists, but shared session/recovery integration and dependable automatic release remain unfinished. Paid-team development signing and immediate category shielding work on the owner's phone. Distribution entitlement approval is separate and has not been established. See [current evidence](status-and-qa.md), [execution roadmap](roadmap.md), and [Sol review](reviews/2026-09-10-sol.md) before implementing.

Related: [product plan](product-plan.md), [interaction design](interaction-design.md).

## Approach

Use Swift and SwiftUI with Apple's Screen Time frameworks. Begin with a disposable feasibility slice before investing in UI or abstraction. No HTTP listener, database server, backend, or local port is needed.

The current project targets iOS 17 with Swift 6 and builds against the installed iOS 26.5 SDK. Oldest-supported-OS runtime/API compatibility still needs validation; the device prototype has only been exercised on the owner's newer OS. Do not infer compatibility from a deployment-target setting alone.

## Proposed targets and responsibilities

| Component | Responsibility |
| --- | --- |
| Main iOS app | Onboarding, individual authorization, selection, configuration, session/recovery UI, reconciliation when opened. |
| Device Activity monitor extension | React to scheduled interval callbacks and reconcile applicable restrictions without the main app running. |
| Shield configuration extension | Minimal system shield appearance using the limited supported extension surface. |
| Shield action extension | Add only if a validated shield-button behavior needs it. Not required merely to customize appearance. |
| Shared policy module | Deterministic occurrence, edit, overlap, and recovery decisions; no UI dependency. |
| App Group storage | Share versioned configuration and session state with required extensions. |

Use `FamilyControls` for individual authorization and privacy-preserving selection, `ManagedSettings` for shielding, and `DeviceActivity` for scheduling. Native selections contain opaque tokens: do not assume they expose arbitrary bundle identifiers or provide general app launching.

The exact broad-shielding/exception policy, browser restrictions, selection limits, and system exclusions must be verified against current Apple documentation and on the target phone. If the requested allowlist experience cannot be achieved, document supported coverage and ask whether a denylist fallback is acceptable before changing scope.

## Phase 1: feasibility spike

### Prerequisites

First inspect the available Xcode/SDK and developer tooling without changing global settings. Then request only what is needed:

- An iPhone and its iOS version for real-device tests.
- The owner's participation in device connection, trust, Developer Mode, and authorization prompts as required.
- An Apple signing team/account setup compatible with the required development capabilities. Personal Teams do not support the Family Controls (Development) capability; actual Screen Time enforcement therefore requires an eligible paid Apple Developer team (and distribution later requires the separate approval process).

Never ask the owner to paste credentials or signing secrets into the repository. Choose bundle identifiers and App Group identifiers after a signing team is available. Verify development entitlement availability rather than assuming a free provisioning profile is sufficient.

### Experiments and evidence

| Experiment | Evidence to record | Gate |
| --- | --- | --- |
| Individual authorization | Prompt outcomes, denial/retry, revocation while active, restoration | Correctly identify unavailable permission. |
| Broad shielding with exceptions | Exact policy used, tested apps/categories, unavoidable exclusions, main-app accessibility | Essentials-only behavior is useful and honest. |
| Essential functions | Calls including normal access to emergency UI without placing a test emergency call; camera, messages, Maps, authentication/medical needs as applicable | No nightly trial before critical access is reviewed. |
| Browser paths | Safari, alternate browser, selected domains, embedded web views where relevant | Explicitly document reachable distractions; no universal filter claim. |
| Scheduled start/end | Requested boundaries vs observed transitions with main app open, closed, and force-quit | System-driven execution and acceptable measured timing. |
| Reboot | Reboot before/during lock and around its end; first unlock afterward | Document persistence and cleanup behavior. |
| Cleanup | Clear owned restrictions after normal end, recovery, stale state, and failed registration | Tested owner recovery instructions exist. |
| Shield customization | Supported text, token labels, end-time presentation, button actions | UI plan matches extension APIs. |
| Storage and callbacks | Extension access to shared state, duplicate callbacks, concurrent writes, callbacks after edits | No stale callback can resurrect a recovered/expired occurrence. |
| Clock changes | Time zone, forward/back clock shifts where permitted, DST boundary simulation and device observations | Separate desired semantics from OS behavior. |

Do not treat simulator success as sufficient proof of Screen Time enforcement. Unit tests and previews are useful in the simulator; critical enforcement gates require a physical device.

Use bounded scheduled test sessions and retain a known recovery route. The current immediate prototype test bypasses Device Activity and must be cleared manually; it is not a bounded production session. Do not block required utilities overnight while exploring cleanup behavior. Apple documents a **15-minute minimum** and one-week maximum Device Activity interval (verified 2026-09-10; see [platform research](reviews/2026-09-10-platform.md)). Use a 20-minute scheduled QA window for margin, rather than the previous hour/90-minute suggestions. Registration still may fail for other reasons; capture exact errors. Apple also documents callbacks as device-use-dependent, so don't promise exact wall-clock delivery while idle.

Create a feasibility report when experiments start, with OS/device/build details, exact steps, expected/actual behavior, timing, and unresolved limitations. Reports must exclude sensitive app selections and personal identifiers by default.

### Exit decision

Proceed to the MVP only when useful exception coverage, scheduled release, and recovery are demonstrated. If scheduling cannot safely provide automatic release under tested conditions, stop and revisit the design rather than substituting a background timer or overstating reliability.

## Phase 2: MVP architecture

### Persisted model (conceptual)

- `Configuration`: schema version, confirmed/enabled flag, daily local start/end, essential-selection tokens, policy revision.
- `PendingConfiguration`: proposed revision and an explicit activation boundary after the current effective lock.
- `SessionOccurrence`: stable ID, origin (scheduled/manual), resolved start/end instants, policy snapshot, lifecycle state, source revision.
- `RecoveryRequest`: occurrence/effective-lock association, request time, eligibility time, cancelled/completed status.
- `ReleasedOccurrence`: sufficient persisted identity/boundary to prevent that occurrence from being resurrected; bounded retention.
- `OperationalStatus`: last attempted/successful schedule registration and policy application, failures, and timestamps. Never confuse this with independently verified global device state.

Avoid implementing a general workflow engine. This model only needs one daily schedule and bounded manual sessions, but must handle their overlap without an early unlock.

### Policy evaluation

Given persisted state and time, compute the desired restrictions and next transitions. Keep this pure enough to test without Screen Time entitlements.

Rules:

1. An occurrence's baseline and resolved end are frozen on activation; stronger edits may add restrictions, but ordinary configuration edits cannot relax it.
2. Expired and recovered occurrences contribute no restrictions.
3. If multiple sessions apply, restrictions are combined conservatively; ending one does not clear another's required policy.
4. A recovery flow applies to the effective current lock, with the confirmation identifying which active occurrences it ends. Future occurrences remain enabled.
5. Settings updates cannot recreate a released occurrence within its original window. Pending revision activation and occurrence identity must be tested together.
6. Clearing owned policy affects only this app's settings stores, never assumes control over other Screen Time policies.

Opaque category/app selection comparisons may make “strictly stronger” difficult to establish. If safe comparison is not supported, queue all essential-list edits until after the lock instead of guessing.

### Scheduling and reconciliation

- Use OS-managed Device Activity monitoring, not an always-running process, `Timer`, background fetch, or silent push as the enforcement foundation.
- Monitor callbacks and main-app foregrounding reconcile persisted desired state with this app's Managed Settings stores.
- Registration success means registration succeeded; it does not prove future callbacks will occur exactly on time.
- Callbacks must be idempotent. Validate occurrence identity, revision, current time, and release markers; do not interpret every start callback as permission to lock anew.
- Model manual-session endings and overlaps explicitly. Validate whether the desired active-session time-zone rule can coexist with repeating OS schedules before finalizing registration strategy.
- Store end boundaries and clear expired restrictions when execution is available. Reconciliation on app launch is a fallback, not a substitute for a reliable automatic morning release.
- For recovery, persist intent before applying the change and reconcile safely after crashes. Report failed clearance rather than claiming success.
- Screen Time application and local persistence are not one atomic transaction. Specify an idempotent ordering and crash recovery for each transition, including partial failures.

### Storage and concurrency

Start with the smallest shared local store that supports consistent read/modify/write across app and extension processes. App Group `UserDefaults` is not a multi-field transactional database or a cross-process lock. For structured state, evaluate atomic file replacement plus coordinated access/locking, or a small transactional store if needed; decide during the spike.

Keep writes bounded for extension execution limits. Add schema versioning, corruption handling, and migration tests. Do not silently reset corrupted state and then report protection as healthy. Protect data using appropriate iOS file-protection settings while testing the extension's actual access before/after first unlock following a reboot.

### Recovery timing

The provisional 15-minute delay needs no scheduled background wake: the app checks eligibility on reopening and again at confirmation. The existing session still ends normally through its scheduled mechanism.

Wall-clock-only checks can be accelerated by changing the device clock. Investigate monotonic elapsed-time validation during a boot and conservative handling across reboots. Explicitly document remaining bypasses; do not promise tamper-proof elapsed time on an owner-controlled device. A request must never extend the ordinary session end.

## Phase 3: validation and personal trial

### Automated tests

- Same-day and overnight intervals; exact boundaries; equal-time validation.
- Stable occurrence IDs and finite end times.
- DST skipped/repeated times and local time-zone transitions using an injected clock/calendar.
- Manual/scheduled overlap and conservative policy union.
- Deferred relaxation, disabling future schedules, and immutable active end.
- Stronger edits or conservative deferral when comparison is unavailable.
- Recovery eligibility, cancellation, repeated requests, confirmation, and natural expiry.
- Duplicate/out-of-order callbacks; recovered occurrence suppression after schedule edits.
- Permission loss/restoration and failed schedule/policy operations through adapters.
- Serialization, corrupted state, concurrent updates, and crash-recovery ordering.

### Device regression matrix

Repeat core cases with the main app foregrounded, backgrounded, force-quit, and after reboot. Include denied/revoked authorization, overlapping manual and scheduled sessions, pending edits, recovery during a lock, and morning cleanup. Investigate Low Power Mode and offline operation. Record unsupported or unreliable combinations; do not infer guarantees from a single successful run.

Accessibility checks cover VoiceOver, large text, contrast, and reduced motion. Verify the entire recovery flow, not only onboarding.

Then run the seven-night personal trial from the product plan. Keep reflection lightweight and outside bedtime. Collect only minimal local operational events needed to debug reliability; avoid full usage history or remote telemetry.

## Phase 4: optional features and distribution

- NFC recovery: requires a physical tag and Core NFC feasibility work; keep it separate from first-release blocking. Tag presence adds physical friction, not secure owner-proof authorization.
- Launcher: WidgetKit plus supported links/Shortcuts and setup guidance. It cannot replace SpringBoard or enumerate/launch arbitrary apps through one public universal API.
- Daytime restrictions: add only after overnight behavior is stable.
- Public release: request Apple's Family Controls distribution entitlement for the app and applicable extension identifiers according to current requirements. Approval is not guaranteed.
- Plan provisioning/renewal for personal use. TestFlight also has build expiration; it is not a permanent unattended deployment solution.

## Risk register

| Risk | Mitigation or decision |
| --- | --- |
| Entitlement/signing unavailable | Resolve early before building polished UI. |
| Broad exception policy insufficient | Produce a coverage report and discuss fallback rather than quietly changing the product. |
| Delayed/missing callbacks or stale shields | Measure on device, persist bounded sessions, reconcile idempotently, test cleanup; stop trial if safe release is unresolved. |
| Owner bypass | Disclose limits; evaluate physical separation if software friction fails. |
| Inadvertently restricted essential access | Test selections in bounded sessions before nighttime use. |
| Recovery becomes the new habit | Evaluate during trial; consider physical NFC friction, not an engaging unlock puzzle. |
| Complex edits/overlaps resurrect locks | Stable occurrence identity, immutable snapshots, release markers, focused state-machine tests. |
| Signing expires | Document installation lifetime and renewal; do not claim set-and-forget personal deployment. |

## Reference starting points

These are official documentation entry points to review against the installed SDK during implementation. Not every platform constraint in the plan has been authoritatively verified; record specific references as feasibility work resolves them:

- [FamilyControls](https://developer.apple.com/documentation/familycontrols)
- [ManagedSettings](https://developer.apple.com/documentation/managedsettings)
- [DeviceActivity](https://developer.apple.com/documentation/deviceactivity)
- [ManagedSettingsUI](https://developer.apple.com/documentation/managedsettingsui)
- [Family Controls distribution entitlement request](https://developer.apple.com/contact/request/family-controls-distribution)

## When owner input is needed

No further product questionnaire is required now. Interrupt for:

1. Signing/team setup, device availability, and system permission prompts before real-device experiments.
2. A platform limitation that materially changes essentials-only coverage, safe automatic release, or recovery.
3. Review of critical app access before enabling overnight use.
4. Approval of physical hardware purchases or public distribution steps, if pursued later.

Bedtime times and essential selections belong in configurable onboarding, not in source code or planning prerequisites.
