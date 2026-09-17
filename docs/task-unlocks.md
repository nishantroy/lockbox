# Task unlocks — pure-core contract

Status: **framework only; not enabled or connected to runtime**. This document and `PhoneLockbox/Policy/TaskUnlock.swift` define an opt-in R10 experiment seam. They do not add HealthKit, camera, math delivery, UI, entitlements, Screen Time wiring, background work, a server, or production enforcement.

## Product boundary

A task is an **early-release condition** for a separately bounded distraction-only session. It is not a lock, an extension, a second session, medical care, fitness coaching, biometric proof, or anti-cheat protection. Every commitment freezes:

- a unique task commitment ID and the exact Lockbox session ID;
- provider kind and provider schema version;
- privacy-minimal provider configuration;
- creation and exact absolute start/cutoff instants; and
- a revisioned policy reference whose scope is `distractionOnly`.

The cutoff is always finite and absolute. It is the OS-managed safety boundary for the eventual runtime integration. A provider completion can make early release **eligible**, but cannot itself clear enforcement, extend the cutoff, start another task/session, or alter the selected policy. This pure core currently accepts only local recovery confirmation. Its grant time is metadata; the release event must carry trusted local `receivedAt` and `processedAt` times, which decide cutoff precedence. Friend approval is deliberately unavailable here: an arbitrary UUID is not an R5 capability. A future authenticated integration must supply a separately verified capability bound to the exact session and frozen policy, relationship, revocation state and one-use rule. A friend never receives task steps, photos, HealthKit data, selections, usage, or raw schedules.

Task settings are off by default. Disabling the setting or editing a provider applies only to later commitments. The exact-session snapshot is immutable while active. Cancelling a not-yet-started commitment is allowed; an active commitment cannot be cancelled or rewritten by a future-setting change.

## Core lifecycle and ordering

`TaskCommitmentState` is one of `committed`, `active`, `completionEligible`, `releasedEarly`, `naturallyExpired`, `cancelled`, or `disabledForFuture`. A completion stores only the provider-issued opaque evidence identifier for idempotency. Raw proof never enters the model.

The pure reducer accepts start, completion, early-release, cancellation, future-disable, and natural-cutoff events. Completion decisions distinguish accepted, duplicate, replay, late evidence, provider rejection/unavailability, wrong exact-session/provider binding, and inactive/disabled states. A repeated accepted identifier is a duplicate; a different identifier after acceptance is a replay. The same completion delivered at or after the cutoff is resolved as **natural cutoff wins**. A completion observed at/after the cutoff is late. For release, trusted local `receivedAt >= cutoffAt` always expires naturally before any early-release path; processing at/after the cutoff is also conservative natural expiry. This remains true after completion eligibility, delayed or out-of-order delivery, and Codable relaunch. Grant metadata can never override those local receipt/processing times. Natural cutoff wins any race while the commitment is not already terminally released; it never moves the cutoff or produces another terminal outcome. Cancellation and commitment-disabling are strictly pre-start (`date < startAt`); at the exact start boundary, cancellation is rejected and start wins when dispatched.

The provider protocol returns only `accepted`, `rejected`, or `unavailable`. `.accepted` means only that an untrusted adapter reported acceptance; it is not authenticated proof or a release authorization. It is an injection seam for a future implementation, not evidence that any provider currently works. Runtime integration must persist the commitment transition before changing Managed Settings and must reconcile using the exact session ID. This core intentionally has no runtime persistence field, callback registration, or enforcement call.

## Provider feasibility gates

No provider may be enabled merely because the shared types compile. Each candidate needs a written feasibility result on the supported OS/device, including foreground and background behavior, permission denial/revocation, deletion, crash/relaunch, cutoff races, accessibility, and abuse review.

### Morning steps (HealthKit candidate)

- **Proposed behavior:** count incremental steps from the task gate's start instant, locally, with an illustrative version-1 target of 2,000. The target and eventual finite cutoff remain owner decisions after feasibility work.
- **Feasibility questions:** whether the supported HealthKit APIs provide the needed incremental query, authorization and reliable foreground reconciliation; whether background delivery is delayed or unavailable; and what happens across reboot, clock change, device lock, and authorization revocation.
- **Privacy:** request only the minimum step read permission if this experiment proceeds. Keep samples and totals on device; do not share steps with friends or a service, put them in completion evidence, or infer health/fitness outcomes. Provide deletion and an unavailable state.
- **Accessibility:** do not require walking, a particular pace, or visual-only progress. Provide a non-health alternative or disable this provider when the user cannot or does not want to grant access.
- **Gate:** no claim of exact background delivery or medical/fitness benefit. A foreground result and the finite OS cutoff remain authoritative.

### Private photo ritual (camera candidate)

- **Proposed behavior:** a private, user-confirmed homemade espresso ritual. Version 1 stores `confirmation=required` and `storage=none`, not image bytes or a remote upload.
- **Feasibility questions:** camera permission denial/revocation, interruption, relaunch, deletion, and whether the flow can remain private and usable without background camera access.
- **Privacy:** default to no photo storage, indexing, upload, or friend/server sharing. If a future experiment needs temporary bytes, define explicit lifetime/deletion and disclosure before implementation. A photo is not biometric or ML verification.
- **Abuse:** the user can photograph anything or confirm without meaningful proof. Treat this as an intentional ritual/friction experiment, never as evidence of espresso preparation, compliance, or safety.
- **Accessibility:** provide a non-camera equivalent and a confirmation flow usable with VoiceOver, Dynamic Type, reduced motion, and permission errors.
- **Gate:** explicit confirmation, honest bypass copy, private deletion behavior, and device-tested permission handling must pass before any camera code exists.

### Math challenge (local challenge candidate)

- **Proposed behavior:** a small bounded local challenge (version-1 default: three problems), with no streaks, scores, feed, reward, or engagement loop.
- **Feasibility questions:** deterministic bounded generation, timeout/cutoff behavior, relaunch/replay handling, and whether answer entry is usable without retaining unnecessary answers or prompts.
- **Privacy and abuse:** keep challenge content local and ephemeral where possible. Answers are not friend payloads. This is trivially bypassable and must not be marketed as anti-cheat, identity, cognitive, or ability proof.
- **Accessibility:** offer a non-math alternative or disable the provider. Support assistive technologies, large text, keyboard/input alternatives, and users with dyscalculia or motor/visual needs.
- **Gate:** no provider implementation until the bounded, non-gamified, accessible flow and bypass disclosure are reviewed.

## Cross-provider safety and abuse gates

Before any runtime or UI work:

1. Verify the finite absolute cutoff under foreground, background, force-quit, reboot, delayed callback, offline, DST/time-zone, clock rollback, and provider-permission failure conditions.
2. Prove completion is scoped to one exact commitment/session and cannot start, extend, or release another session. Duplicate and out-of-order evidence must be idempotent.
3. Prove natural cutoff wins a completion/recovery race. Recovery remains usable without a provider. Friend approval remains unavailable until R5 supplies a separately verified exact-session-and-policy capability.
4. Reject critical essentials as a task-gated policy by contract. The policy reference has only the `distractionOnly` scope; the task framework must never broaden it or infer a safe app list.
5. Keep provider data local and minimal. Do not collect raw HealthKit samples, images, answers, app choices, usage, messages, or schedules for sharing or analytics.
6. Make disabling the task feature safe: it prevents future commitments but cannot shorten or rewrite an active one. Configuration edits become pending for later activation.
7. Provide a clear non-task recovery path, permission errors, deletion behavior, and an accessible alternative for every provider. Never shame, score, rank, streak, or pressure a user to complete a task.
8. Label all provider outcomes as unavailable or integrity-unknown when delivery/proof cannot be trusted. A local provider result is not tamper-proof on an owner-controlled device.

## Acceptance gate

This source-only framework is complete when pure tests cover finite bounds and Codable rejection, provider/version/config privacy constraints, exact-session binding, immutable snapshots, activation/cancellation/future-disable, accepted completion, duplicate/replay/late evidence, natural-cutoff ordering, no extension/start of another session, trusted local recovery authorization binding, rejection of friend-approval placeholders, and terminal idempotence. A later provider feasibility review and physical-device evidence are required before adding any provider, runtime connection, UI, permission, entitlement, or production claim.
