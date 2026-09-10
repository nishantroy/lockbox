# Phone Lockbox — product plan

Status: initial plan, not an implemented or device-validated product.

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
| Recurring schedule | One daily local-time window, including overnight windows. Reject ambiguous equal start/end times. Weekday variations are deferred. |
| Essentials selection | User selects available exceptions through supported system UI. Explain unavoidable exclusions and test critical access before commitment. |
| Scheduled lock | Apply restrictions without needing the main app to stay open; release at the scheduled end. Reliability must be tested. |
| Lock now | Start immediately with a clearly confirmed future end. Provisional default: the next configured morning end; never create an indefinite session. |
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
- Daytime denylist, usage quotas, weekday-specific schedules, or multiple profiles.
- NFC, accountability partners, remote approval, or a backend.
- Usage dashboards, sleep tracking, HealthKit integration, and behavioral scoring.
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

1. **Feasibility:** prove Apple authorization, shielding, scheduling, essential access, and cleanup on a real device.
2. **Bedtime MVP:** implement the interaction model, persistent policy, and deliberate recovery.
3. **Hardening and trial:** test edge cases and use nightly; revise from observed behavior.
4. **Optional expansion:** NFC, daytime restrictions, launcher widget, and public distribution.

Before public release, revisit entitlement approval, installation reliability, privacy disclosures, accessibility, support, and the tested device/OS matrix. Personal development signing is not an unattended long-term installation strategy without provisioning planning.

Related: [interaction design](interaction-design.md), [technical plan](technical-plan.md).
