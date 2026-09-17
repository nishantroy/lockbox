# Phone Lockbox — execution roadmap

Updated: 2026-09-16. **Current milestone: build-14 focused QA and the R4 reliability gate.** R1–R3 source integration is complete and has automated coverage; physical-device acceptance is still required for the remaining lifecycle, accessibility and seven-night evidence. Build 14 is a source/install candidate, not a new device pass. Its Live Activity correction makes presentation opt-in and default-off. Build-13 device evidence still records natural enforcement end and recurrence, while a host-created Live Activity stayed stale until foreground cleanup; dependable host-closed ending requires unprovisioned ActivityKit push infrastructure. See [status and QA evidence](status-and-qa.md), [R2/R3 checklist](r2-r3-qa.md), and [R1 progress](r1-progress.md).

This document is the authoritative execution sequence. Product specifications describe intended behavior; they do not certify implementation or device reliability.

## Start here

1. Read [status and QA evidence](status-and-qa.md), the [Sol review](reviews/2026-09-10-sol.md), and this roadmap.
2. Read [product plan](product-plan.md), [technical plan](technical-plan.md), [interaction design](interaction-design.md), and [layout v1 contract](layout-v1-contract.md).
3. Preserve the historical build-2/build-3 and build-13 evidence. Do not repeat a passed case without a relevant source or device change.
4. Complete R4 before exposing any future feature. R5 production infrastructure is a prerequisite for R6 friend approvals and accountability; neither is represented by the local pairing or relay simulations.
5. Do not change code, build identity, device schedules or installation as part of this planning update.

## Current product boundaries

- Native SwiftUI iPhone app using individual Screen Time authorization, local configuration and one daily window until the approved weekend slice is implemented.
- Both **Block selected** and **Allow only selected** remain supported through Apple's selection model. Category expansion is not a promise of universal coverage; critical apps, browsers and system paths require device testing.
- Active sessions have finite, frozen ends and policy snapshots. Relaxing edits, disabling recurrence and recovery affect future work or the current committed occurrence according to the tested lifecycle rules; they never become an instant bypass.
- Recovery is delayed and explicit. Natural end wins, network delivery is never required for safety or recovery, and developer cleanup remains visibly separate until the reliability gate is closed.
- The interface is calm, accessible and non-shaming: no streaks, scores, feeds, guilt language or engagement loops.
- The task feature described below is opt-in and disableable outside an active commitment. Disabling it cannot rewrite an active session and affects only future sessions.
- General schedule exceptions (vacation, skip, snooze, one-off overrides) are not in the approved scope. This is different from the bounded weekend schedule slice and from a deliberate recovery of the current session.

## Completed source milestones and preserved history

### R1 — Honest operational state and observable scheduling

R1 diagnostics, authorization/selection validation, registration status, shared policy mapping, manual/scheduled ownership boundaries and the target-family configuration correction are integrated in source. Registration success is still not proof of callback delivery or universal enforcement. The documented 15-minute minimum and usage-dependent callbacks remain platform constraints; QA uses a bounded 20-minute interval.

### R2 — Shared persisted lifecycle and reconciliation

The shared session/recovery core, stable occurrence identity, frozen active snapshots, release markers, schema handling, intent replay and ownership/reconciliation paths are integrated and covered by automated tests. This does not turn historical source work into a device certification: concurrent-process, reboot, file-protection, callback-timing and platform coverage remain R4 evidence.

### R3 — Recovery and active-session UX

Finite Lock now, delayed explicit recovery, immutable active-session behavior, pending edits, natural-end precedence and recurrence preservation are integrated in the current source candidate. Build-14 custom-end bounds and exact-end validation are source-only until focused device QA. The normal product UI must never confuse developer reset with recovery or successful release.

## R4 — Build-14 reliability, accessibility and seven-night gate (current)

**Depends on:** R1–R3 source integration. **Blocks:** all ordinary exposure of R5 and later features.

### R4.1 Focused build-14 QA

- Verify custom Lock now preset and custom-end behavior, including the 15-minute minimum, seven-day maximum, delayed confirmation and preservation of the selected absolute end.
- Verify the default-off Live Activity migration and explicit opt-in behavior. Record stale foreground cleanup honestly; do not call it automatic dismissal.
- Run natural end, overnight, force-quit, reboot/first-unlock, pending-edit, overlap, recovery/relaunch, stale-state and time-zone/DST cases using the [QA matrix](status-and-qa.md).
- Test authorization denial, revoke/restore, registration failure, critical essentials, browser paths and category coverage. Do not change a scheduled-release interval during its QA observation.

### R4.2 Accessibility and safety review

Check VoiceOver, Dynamic Type, contrast, reduced motion and full-row/tappable controls across setup, status, errors, active lock, recovery and settings. Run the critical-app/browser/system checklist, including normal emergency UI access without placing a test emergency call. Accessibility is a release gate, not a separate engagement feature.

### R4.3 Seven-night personal trial

Begin only after automatic release and cleanup are demonstrated under the recorded conditions. Record reliability and usefulness outside bedtime with minimal local operational data; do not collect app choices or remote telemetry.

**R4 acceptance gate:** no unresolved high-severity lifecycle, release, authorization or critical-access finding; automatic release works with the main app closed under documented conditions; accessibility checks pass; known platform and owner-bypass limits are documented; and the seven-night evidence does not rely on foreground cleanup. A failed gate keeps the product in prototype/hardening and does not get reclassified as a pass.

## R5 — Production trusted-person infrastructure and exact-session friend unlock

**Depends on:** R4 gate for ordinary exposure. This is two sequential subphases under one production prerequisite; the local companion/pairing and relay simulations remain developer-only.

### R5.1 Durable relay and identity lifecycle

Replace simulations with a deployed authenticated transport, real PostgreSQL adapter, durable server inbox/fetch, device-held signing keys, explicit pairing and re-pairing, and documented identity/key rotation and revocation. Preserve accountless companion use where approved; do not require Screen Time authorization for companion-only setup. APNs or text may wake/remind, but never carry approval credentials or become authoritative delivery.

The outbox must be bounded, idempotent and retryable. Define offline, reinstall, clock-rollback, retention/deletion, recipient opt-out and cross-owner isolation behavior. Recovery, emergency access and enforcement must remain safe when the relay is unavailable.

### R5.2 Friend unlock delivery and per-person permissions

For each trusted person, sender consent and recipient consent are separate, explicit and revocable. The owner configures these scopes independently:

- **Approve early end:** may approve release of the owner's current session only.
- **Receive requests:** may receive a request for that exact current session.
- **Receive early-end notices:** may receive a privacy-minimal terminal notice for an ended-early session.
- **Receive weekly shared summaries:** may receive the separate plain weekly summary described in R6.
- **Mutual pact:** opt into a second, independent one-way relationship; each person controls only their own lock and sharing.

A valid approval is a one-use signed capability bound to the exact session/occurrence, frozen policy identity and recipient relationship. The initial release rule is **one-of-N first valid approval** when more than one approved person is available; one approver cannot start, extend, or change a lock. No friend can see selections, usage, task steps, raw schedules or task details, start a session, extend a cutoff, change rules, or bypass the owner's local safety flow. Network delivery is never required for recovery or emergency access. Later quorum choices are out of scope until separately decided and tested.

Record the exact-session terminal event before clearing policy, queue it offline with a stable idempotency key, and ensure natural end wins a late approval race. Revocation cancels pending capability use and future delivery where possible; it cannot silently reattach to another identity.

**R5 acceptance gate:** deployed-path tests prove authentication, pairing/re-pairing, identity and per-person consent/revocation, signed exact-session one-use binding, one-of-N first release, duplicate/late/out-of-order delivery handling, server-authoritative fetch, cross-owner isolation, privacy payloads, accessibility, retention/deletion, and offline/network/emergency independence. Any failed infrastructure or security gate keeps friend unlock and accountability unavailable in ordinary UI.

## R6 — Opt-in accountability and shared summaries

**Depends on:** the complete R5 gate. Accountability remains supportive status sharing, not surveillance or owner-proof control.

R6 adds the early-end notice and weekly shared summary choices described in R5.2. Notices and summaries are independently consented per person, revocable by either side, and delivered through the durable inbox/fetch. A mutual pact is two independent relationships, never shared control. Shared material contains only planned, naturally completed, ended-early and unavailable/integrity-unknown counts/statuses. It excludes app selections, app/site usage, messages, raw schedules, task steps and content. Use generic notification previews, quiet hours and supportive “ended early” language; no scores, streaks, rankings or shame.

**R6 acceptance gate:** exact-session event binding, terminal classification, idempotent delivery/retry, no duplicate weekly counts, approval/recovery/natural-end races, offline queueing, revocation and opt-out, quiet hours/late delivery, reinstall and clock rollback, privacy inspection, accessibility/copy, retention/deletion, cross-owner isolation and deployed PostgreSQL/authenticated product QA all pass. See [accountability design](accountability-design.md). A local simulation never satisfies this gate.

## Post-R6 product sequence

The following phases are deliberately ordered. Each is a feasibility or bounded product slice; none changes the R4 enforcement foundation. Each phase gets its own privacy, accessibility and device acceptance gate before broadening scope.

### R7 — Local insights and safety assistance

#### R7.1 DeviceActivityReport / Screen Time Insights feasibility spike — first

Before building any usage surface, verify the supported `DeviceActivityReport`/Screen Time APIs on the target OS and device. Explore a local-only report for **Today** and **7 days** with top apps/categories, time inside versus outside protected periods, and a by-hour/day heatmap only if the API supports it. Pickups and notifications appear only if the platform exposes them through the supported report APIs.

Treat report extensions as privacy boundaries: do not assume raw usage export, arbitrary bundle identifiers, server upload or a general-purpose usage database. Document report-extension data availability, rendering limits, retention and any inability to export raw data. This spike does not block enforcement, scheduling or the R4 trial.

**Gate:** written feasibility evidence and privacy review; useful local rendering without unsupported raw-data claims; no analytics SDK, telemetry or sharing by default; VoiceOver/Dynamic Type review; and a clear fallback when a metric is unavailable.

#### R7.2 Safety assistant

Add a non-authoritative preflight and review assistant: essentials checklist, allow-only warnings, browser/system/critical-app test flow, authorization/enforcement status and a clear reminder that emergency access is not guaranteed by this app. It may guide or link to system settings but must not silently alter the policy or promise to test every path.

**Gate:** warnings are strict and actionable, critical-access checks are reproducible, failures do not claim safety, and accessible recovery/setup copy passes review. There is no false emergency guarantee.

#### R7.3 Personal weekly review

Provide a supportive local review distinct from the R6 shared summary. It may show protected time, naturally completed sessions, ended-early sessions and unknown/integrity counts, plus usage patterns only within the supported Apple report limits. It does not show app data that the report API cannot safely provide, and it has no streaks, scores, rankings, shame or remote sharing by default.

**Gate:** report limitations and uncertainty remain visible, local deletion/retention is explicit, the review cannot be mistaken for the trusted-person summary, and accessibility checks pass.

### R8 — Bounded schedule expansion: weekend first

Implement the first multi-schedule slice as exactly two named slots: a weekday rule and a weekend rule. Each rule has its own days, local start/end and policy selection. Freeze the active occurrence's resolved end and policy snapshot. Reject overlapping rules up front rather than inventing precedence; reject equal/invalid boundaries with clear feedback.

This is not a general exception system. Do not add vacation, skip, snooze, ad-hoc exceptions or arbitrary overrides. After device evidence for the weekend slice, a later phase may add different named rules for different times of day. Same-mode composition or priority is a separate design and test decision, not an implicit result of adding another rule.

**Gate:** conflict preview and rejection are deterministic, active-session immutability and recurrence are preserved, migration is safe, and device tests cover boundaries, DST/time zones, reboot, overlapping rejection and accessibility.

### R9 — Shortcuts, App Intents and quick actions

Expose only finite, confirmed actions: start a 30-minute session, start a one-hour session, start a named rule, show status, and open recovery. Parameters must be validated against the same persisted session authority and auth/enforcement truth shown in the app. The action must never create an indefinite lock, provide an instant recovery bypass, silently change active rules or claim enforcement merely because an intent was accepted.

**Gate:** duplicate invocation is idempotent, confirmation and parameter safety are clear in Shortcuts and Siri surfaces, unavailable authorization is truthful, active-session rules remain frozen, and accessibility/voice feedback is understandable.

### R10 — Opt-in task-based unlock experiments

First complete a task-provider feasibility, abuse, privacy and accessibility review. These are experiments, not medical tools and not anti-cheat claims. The entire task feature is opt-in and can be disabled outside an active commitment; disabling it affects future sessions only.

The shared framework models a task as an **early-release condition** for a separate finite distraction-only or task-gated session. At session start, freeze the task, cutoff, policy and exact session ID. A successful task can make release eligible, but the release remains bounded by the session's delayed recovery/confirmation and any exact-session friend approval. Every session has an immutable absolute safety cutoff enforced by the OS-managed finite end. A task can never extend a session, change its policy, gate critical essentials, or create a second completion; completion is idempotent for that exact session. Friend permissions never expose task steps, photos or HealthKit data.

Initial feasibility candidates:

1. **Morning steps via HealthKit:** count incremental steps from the gate start, locally, with an illustrative default of 2,000 and a maximum absolute cutoff to be chosen after the prototype. Background delivery is not exact; foreground reconciliation and the OS end remain authoritative. Do not share steps or make a health/fitness claim.
2. **Homemade espresso photo:** a private ritual with camera permission and explicit user confirmation. Default to no storage or upload. It is not biometric or ML proof; acknowledge easy bypass and the privacy tradeoff.
3. **Math problems:** a small bounded local challenge with no engagement loop, streaks or gamification. Offer an accessible alternative or disable the provider.

**Gate:** each provider passes abuse/bypass review, privacy and deletion review, permission/error handling, foreground/background reconciliation, absolute-cutoff testing, accessible alternatives and a clear non-medical/non-anti-cheat explanation. No task provider ships by implication of the framework.

### R11 — Multiple daily named rules

Only after R8 proves the weekend slice, expand to a small bounded number of named rules for different times of day. Each rule retains days/time/policy fields. Show a conflict preview before saving and reject overlaps initially; do not invent precedence or general exceptions. Same-mode composition or priority may be considered later only with an explicit contract, migration plan and exhaustive lifecycle tests.

**Gate:** active occurrence freeze, conflict handling, recovery/release identity, DST/time-zone behavior, accessibility and device evidence pass without weakening R4 safety constraints.

### R12 — Reliable Live Activity ending

ActivityKit remains optional and default-off until production infrastructure can support reliable host-closed ending. A future push-enabled implementation depends on the approved production transport, authenticated device/activity identity, bounded stale-state handling and explicit privacy review. Live Activity state is presentation only: it never enforces, releases or replaces the persisted session authority. Until this gate, foreground best-effort cleanup and the documented stale-presentation limitation remain the honest behavior.

## Explicit deferred and non-goals

- General schedule exceptions, vacation/skip/snooze controls and arbitrary one-off overrides.
- Automatic adaptive blocking, inferred schedules and behavior-based policy changes.
- Sharing task proof, HealthKit steps, photos, usage, selections, messages or raw schedules with friends or a server.
- Arbitrary ML or biometric photo verification; the espresso candidate is a private, user-confirmed ritual only.
- Medical, sleep-treatment, anti-cheat or emergency-access guarantees.
- Indefinite locks, instant recovery bypasses, friend-initiated starts/extensions/rule changes, and remote control of another person's device.
- NFC, custom launcher/widget, public distribution and other expansion unless separately re-approved after the gates above.

## Decision log and owner decisions still open

The roadmap does not choose unresolved infrastructure or policy details. Owner decisions are required before the relevant gate: hosting/provider and deployment region for R5, retention/deletion periods, exact notification copy and quiet hours, future friend quorum beyond one-of-N, the default morning-step target and absolute cutoff after provider feasibility, supported report metrics after the DeviceActivity spike, and whether same-mode rule composition/priority is ever wanted. None of these decisions blocks R4 QA or changes the current local enforcement contract.

## Review and delivery discipline

Keep [status and QA evidence](status-and-qa.md) current with exact build/device distinctions. Do not claim implementation, device reliability or production delivery from a plan or simulation. Run focused tests/builds after code changes, preserve the developer cleanup route until release is proven, and update this roadmap when a gate actually passes.
