# Phone Lockbox — product plan

Status: target product specification. A device-tested feasibility prototype exists; the dependable bedtime MVP is not complete. See [current evidence](status-and-qa.md) and [execution roadmap](roadmap.md) for actual progress.

## Purpose

Keep the useful parts of an iPhone while interrupting compulsive app-hopping at bedtime. Start with one person's phone; consider publishing only after the experience proves useful.

The primary problem is cycling among social apps, video, browsing, messages, and work—not one particular distracting app. The initial solution is scheduled, broad app restrictions with a small set of user-selected essentials.

Success means fewer nights spent cycling through apps in bed without losing genuinely necessary access. We are not claiming to treat insomnia or measuring success by engagement with this app.

## Agreed direction

- Native iPhone app, personal use first.
- Bedtime schedule and essential apps are configurable during onboarding and later; their values are not prerequisites for implementation.
- Prefer essentials-only nighttime rules over chasing an expanding denylist.
- Restrictions should be hard to relax impulsively. No casual snooze or “five more minutes” button.
- Local-only configuration, no account, backend, advertising, or analytics SDK.
- Simple, calm interface without streaks, rewards, guilt, or feeds.
- Defer building a launcher. An existing launcher can be used independently while we prove blocking.

## Honest boundaries

An ordinary self-control app cannot replace the iOS Home Screen or guarantee owner-proof restrictions. Individual Screen Time authorization can be revoked, and deleting the app is a bypass. Device-clock manipulation and other settings changes must be investigated rather than assumed preventable.

“Essentials-only” means broad shielding with exceptions within Apple's supported policy model. It does not guarantee every app, system function, website, embedded browser, or notification is controllable. Actual coverage is a feasibility gate.

Focus, notification settings, and Home Screen simplification are optional guided system setup, not settings this app promises to control globally. Do not market the app as an emergency-access guarantee or tamper-proof lockbox.

## MVP scope

| Capability | Intended behavior |
| --- | --- |
| Authorization | Explain and request individual Screen Time authorization; expose missing authorization clearly. |
| Recurring schedule | One daily local-time window, including overnight windows. Reject ambiguous equal start/end times. A bounded weekday/weekend slice is a later roadmap phase; general schedule exceptions remain out of scope. |
| Restriction selection | Support Block selected and Allow only selected through system app/category/website selection. Category allowance currently expands to individual token exceptions; explain coverage limits and test critical access before commitment. |
| Scheduled lock | Apply restrictions without needing the main app to stay open; release at the scheduled end. Reliability must be tested. |
| Lock now | Start immediately with a clearly confirmed finite end (30 minutes, 1 hour, or a validated custom end). Never create an indefinite session or silently use the bedtime end. |
| Active-rule protection | Freeze the current session's baseline. Relaxations and schedule changes cannot shorten it through ordinary settings. |
| Recovery | A deliberate, delayed request to end the current lock, subject to a feasibility gate. No instant temporary access. |
| Status | Show configured end, pending changes, recovery state, and known authorization/enforcement problems without claiming live verification the app cannot perform. |
| Local storage | Persist configuration and session state across main-app termination; share only required state with extensions. |

### Provisional recovery design

For the first MVP, use a 15-minute waiting period followed by an explicit confirmation in the main app. This is a product starting point, not a user requirement or proven enforcement mechanism. No need to keep the screen on, and no automatic release just because the waiting period elapsed. Cancelling resets the request; repeated requests cannot shorten the wait.

Recovery ends the current session, rather than granting a short timed exception. This avoids making temporary-access reblocking another MVP reliability dependency. The next scheduled session remains configured. Record only a minimal local recovery event for debugging or optional reflection.

Recovery must suppress reapplication for that same occurrence across callbacks and app launches. It must not suppress future nights. Before implementation, test whether this friction is adequate; NFC outside the bedroom is a later candidate.

## Non-goals for the first release

- Custom Home Screen launcher or widget.
- Daytime denylist, usage quotas, general schedule exceptions, or multiple profiles in the first release. A bounded weekday/weekend slice and later named rules are future roadmap phases, not first-release scope.
- NFC, accountability partners, remote approval, or a backend in the first release; the separately gated future trusted-person capability is described below.
- Usage dashboards, sleep tracking, HealthKit/task providers, and behavioral scoring in the first release. A local DeviceActivityReport feasibility spike and opt-in task experiments are separately gated future work; they do not imply raw usage export or medical claims.
- MDM, supervised-device setup, parental-control workflows, or private APIs.
- Preventing uninstall, authorization revocation, or all owner-controlled bypasses.
- Payments, App Store marketing, cross-device synchronization, and Android support.

## Acceptance criteria

These are targets, not claims that tests have passed.

1. A user can authorize, choose exceptions, and configure an overnight schedule without developer-supplied app choices or times.
2. Representative nonessential apps are shielded when opened from their icons, Search, and the App Library; selected essentials and critical system functions are tested on the target phone.
3. Scheduled start and end work with the main app closed on the supported device/OS combination. Reboot and timing results are recorded, including measured delays and failures.
4. The interface does not offer immediate in-app weakening of an active lock. Pending edits survive app restarts and do not mutate the active session's baseline.
5. Recovery cannot complete before its persisted waiting period; it requires confirmation, affects only the current occurrence, and remains consistent across duplicate callbacks.
6. The scheduled end clears only this app's restrictions. The app cannot promise to remove Screen Time or other restrictions owned elsewhere.
7. Missing authorization is shown as unavailable protection when detected. Unknown enforcement status is not presented as independently verified blocking.
8. Failure tests demonstrate a documented recovery procedure for stale shields before nightly use.
9. No app choices, schedule data, or recovery history are transmitted by the app. Diagnostics avoid raw app identifiers and unnecessary personal data.
10. Large text, VoiceOver, and sufficient contrast work for setup, status, and recovery.

## Personal trial

After technical and safety gates pass, use it for seven nights. A short retrospective outside bedtime is enough:

- Did the app-hopping loop stop or move elsewhere?
- Were any necessary tasks unexpectedly blocked?
- Were schedule transitions and release dependable?
- Was recovery used intentionally, or did it become routine?
- Did deleting the app or revoking permission become the escape route?

If software bypass becomes routine, consider a physical timed lockbox rather than claiming additional UI friction can provide a complete block.

## Roadmap and decision gates

The authoritative sequence is [roadmap](roadmap.md): R4 build-14 reliability, accessibility and seven-night evidence; R5 production trusted-person infrastructure plus exact-session friend unlock permissions; R6 opt-in accountability; then the ordered R7–R12 local insights, safety assistant, weekend scheduling, personal review, quick actions, task experiments, named rules and reliable Live Activity phases. A plan is not implementation evidence.

The first release remains a dependable, finite bedtime lock with delayed recovery. Future insights are local and limited by Apple's report APIs; future task providers are opt-in, disableable outside active commitments and never gate critical essentials. General schedule exceptions, automatic adaptive blocking, task proof/sharing and arbitrary ML photo verification remain non-goals.

Before public release, revisit entitlement approval, installation reliability, privacy disclosures, accessibility, support, and the tested device/OS matrix. Personal development signing is not an unattended long-term installation strategy without provisioning planning.

## Approved future capability: opt-in accountability

This is deliberately **after the bedtime MVP**. It may be enabled only after the production trusted-person relay has a real PostgreSQL adapter, authenticated transport, durable server inbox/fetch, and a tested identity/consent lifecycle. The current in-memory core, pairing demo, or relay simulation is not production-ready. See the [accountability design](accountability-design.md) for the protocol and acceptance gates.

An owner may opt in and select accepted trusted people individually. For each person, the owner independently chooses whether that person may approve an early end, receive exact-session requests, receive early-end notices, receive weekly shared summaries, or participate in a mutual pact. Sender and recipient consent are separate and revocable. Friend approval is one-use, signed and bound to the exact session; the initial release policy is one-of-N first valid approval. A friend cannot start or extend a lock, change rules, or see selections, usage or task steps. Network delivery never becomes a recovery or emergency prerequisite. Multiple trusted people are independent, and a mutual pact is two independent one-way relationships: neither person controls, inspects, or extends the other's lock.

The event is durably recorded locally before ordinary recovery or trusted release clears policy and is queued for offline delivery. Emergency access never depends on network delivery. The authenticated server inbox/fetch is authoritative; APNs and text are wake/reminder hints only. Use supportive “ended early” language, never shame or failure language. Natural ends, recovery, trusted approval, authorization loss/integrity warnings, and developer/emergency cleanup remain distinct outcomes.

The default payload exposes no app selections, app/site usage, messages, or raw schedules. A weekly summary contains only planned, naturally completed, ended early, and unavailable/integrity-unknown counts/statuses—never streaks, scores, rankings, or shame. Quiet hours, notification previews, late delivery, cancellation, recipient opt-out, retention/deletion, and the limitation that a locally controlled, reinstalled, or offline device cannot be tamper-proof without deployed durable authority are part of the design, not follow-up polish.

### Production accountability gates

Before ordinary UI exposure, acceptance tests must cover exact-session binding, idempotent delivery, offline queue/retry, no duplicate weekly counts, revocation, cross-owner isolation, quiet hours, natural-versus-early classification, approval/recovery races, reinstall and clock rollback, privacy payload inspection, and accessibility/supportive copy. Product QA must exercise the deployed PostgreSQL/authenticated path and identity lifecycle; the local in-memory implementation must not be represented as production accountability.

Related: [interaction design](interaction-design.md), [technical plan](technical-plan.md), [accountability design](accountability-design.md).
