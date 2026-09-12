# Overnight build contract — 2026-09-12

## Owner-approved scope

The owner approved Luna high/xhigh implementation, Terra code-quality/correctness review, non-overlapping ownership and meaningful commits. No visual redesign without the owner. Minimal functional Live Activity/developer prototype presentation is approved. No TestFlight work, device installation, phone schedule changes, account provisioning or hosted deployment while the owner is away.

Baseline `75c6a8d` checkpoints build 3 source, the 56-test suite and historical owner QA. It is a rollback point, not certification that all interruption paths are safe. Known post-QA findings remain to fix. Existing device remains `0.1 (3)`.

### Priority 1: reliability

Close interrupted manual release/expiry cleanup, recurrence ownership, midnight/pending activation suppression, history pruning and recovery relationship edge cases. Preserve developer unlock and serialized emergency reset. No repeated request for previously passed baseline QA absent relevant change.

### Priority 2: same-app trusted-person foundation

- No mandatory email/phone account; device-held signing keys, mutually confirmed pairing.
- Companion-only role needs no Screen Time permission.
- Expiring, single-use approvals for exact current sessions, never remote start/extend.
- Multiple approvers, optional bounded request messages, status/cancellation.
- Push is a wake hint; foreground fetch is authoritative. Manually textable links are not approval credentials.
- Pair revocation/re-pairing, missing-key handling, no app selections/usage sent to service.
- Delayed recovery remains an alternative. Configurable recovery delay outside commitment is approved for later integration; never change active-session delay.
- Optional mutual bedtime pact: each participant independently accepts their own commitment; nobody gains remote control over another person's policy.
- Optional approver quiet hours and private event history; no scores/streaks/contact uploads.

Protocol and relay simulations must be clearly labeled. Real remote delivery requires a deployed authenticated transport and APNs setup; no claim that a local two-identity demo is a working cross-phone service. No HTTP listener is assigned in this batch; any future listener must first reserve ports in the repository-wide registry.

### Priority 3: ambient prototypes

Opt-in wind-down local reminders and a Live Activity with a fixed end/recovery status (no ticking countdown). Notifications and Live Activities never enforce/release restrictions. Account for Live Activity lifetime and stale state; do not promise overnight visibility or background updates while the app is terminated. NFC is deferred.

## Ownership and integration

| Branch/worktree lane | Model | Exclusive implementation paths |
| --- | --- | --- |
| `overnight/reliability` | Luna xhigh | `Shared/`, `RuntimeTests/`, coordinator, monitor, own review note |
| `overnight/companion` | Luna high | New `CompanionKit/`, `PhoneLockbox/Companion/`, companion prototype documentation |
| `overnight/ambient` | Luna high | New `AmbientKit/`, `PhoneLockbox/Ambient/`, `Extensions/LockboxLiveActivity/`, ambient prototype documentation |
| Parent integration | Parent | Existing UI entry points, package/project linking, build identity, common docs; integration only after branch review |

Each lane commits its own coherent changes. A supervisor starts a **Terra medium read-only review** after each implementation finishes. Parent triages reports, fixes verified blockers, integrates reviewed branches in separable commits, then runs whole-project tests/builds. New frameworks never implicitly activate on launch or require Screen Time authorization for companion-only use.

## Morning handoff requirements

- Commit hashes and feature boundaries for revisit/revert.
- Exact validation run, report dispositions, and unresolved blockers.
- Clearly separate live native prototypes from simulated relay/approval/pact behavior.
- Focused next QA and any required credentials/hosting decisions, without claiming device results for source-only changes.
- Preserve build-3 owner evidence; that evidence is not certification of new source.
