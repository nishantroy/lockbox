# Phone Lockbox — accountability design

Status: **approved future capability, deferred**. This is a product and protocol specification, not evidence that the current prototype can deliver accountability. It may not be enabled until the production trusted-person relay, authenticated transport, identity lifecycle, and explicit product QA gates below are complete. The existing in-memory core and relay simulations are not production-ready.

Related: [roadmap](roadmap.md), [product plan](product-plan.md), [interaction design](interaction-design.md), [overnight build plan](overnight-build-plan.md).

## Purpose and boundary

Accountability is an opt-in companion to the owner's own lock, not a remote-control system. The owner may select individual accepted trusted people who receive a privacy-minimal notice when an active session ends early. The owner may separately opt into a plain weekly summary for each person. It is supportive status sharing, not surveillance, punishment, or proof that a person has failed.

This feature is ordered after the production trusted-person relay and before optional growth or distribution work. A same-app pairing or local simulation can exercise UI and protocol shapes, but must be labelled as a simulation and must never imply that a deployed service exists.

### What is and is not shared

By default, an event or summary contains no app selections, app/site usage, messages, raw schedule times, titles, URLs, or content. The minimum event is the owner's identity within the authenticated relationship, an exact session/event identifier, a coarse event status, and the necessary event time/status metadata. A summary contains only counts and statuses:

- planned;
- naturally completed;
- ended early; and
- unavailable or integrity unknown.

There are no streaks, scores, rankings, guilt language, or shame prompts. A developer cleanup or emergency cleanup is not recast as a natural completion or an ended-early user event; it is separately auditable and may make the affected period unavailable or integrity unknown.

## Consent and relationship model

- The owner explicitly enables accountability and selects people one by one. There is no default recipient and no contact upload.
- Sender consent and recipient consent are separate, recorded, revocable decisions. For each person, the sender separately chooses approval of early end, receipt of exact-session requests, early-end notices, weekly shared summaries and (optionally) a mutual pact; the recipient accepts the stated purpose and categories independently.
- A recipient can opt out at any time. Opting out stops future delivery and does not expose a reason or reveal other relationships. Revocation cancels pending approvals and queued delivery for that relationship where possible, while already delivered device notifications cannot be reliably removed from the operating system.
- Multiple trusted people are supported. Each approval is a one-use signed capability scoped to the exact current session/occurrence, frozen policy identity and relationship. The initial release policy is one-of-N first valid approval; no trusted person can start, extend or change a lock, and no friend can see selections, usage, raw schedules or task steps. Any later quorum or tie behavior requires a separate decision and tests; an approval never becomes a general-purpose credential.
- One-way relationships are independent. A mutual pact is two separately consented one-way relationships: each person controls their own policy, events, and recipients. Neither participant can inspect or change the other's lock, selections, schedule, or recovery settings.
- Pairing, re-pairing, identity-key changes, and revocation are explicit lifecycle operations. A lost key, deleted relationship, or identity replacement must fail closed for sharing rather than silently attaching an event to another owner.

## Event semantics

Every event binds to the immutable session/occurrence identity and its frozen policy snapshot. The local device records the terminal classification before ordinary recovery or a valid exact-session friend release clears policy; it then queues the minimum event for delivery. This ordering must hold even when the network is unavailable. Emergency access and the owner's local recovery must never wait for delivery, server confirmation, APNs, or text. A late or duplicate approval cannot reclassify a natural end or release another session.

The authoritative inbox/fetch service stores and returns events. APNs or text messages are wake/reminder hints only: they do not contain approval credentials, are not authoritative delivery, and may be delayed, duplicated, or absent. Foreground authenticated fetch reconciles delivery and acknowledgement idempotently.

Use supportive copy such as **“This lock ended early”** or **“Your Lockbox session ended early.”** Do not use “failure,” “bad behavior,” or “you broke your promise.” Distinguish these outcomes in the event model and UI:

| Outcome | Meaning | Accountability treatment |
| --- | --- | --- |
| Natural end | The committed end was reached without a recorded early release. | Count as naturally completed. |
| Owner recovery | The owner completed the deliberate recovery flow for this exact session. | Count as ended early; identify only the agreed status, not private details. |
| Trusted approval/release | A valid, bounded approval contributed to release of this exact session. | Count as ended early; retain approval provenance only as needed for the relationship. |
| Authorization loss or integrity warning | Enforcement or state could not be established or trusted. | Count as unavailable/integrity unknown; never claim a natural or early end. |
| Developer/emergency cleanup | A bounded maintenance or emergency route cleared policy. | Keep out of ordinary accountability classifications; surface unavailable/integrity unknown when the period cannot be trusted. |

Natural expiry wins races against a late recovery or approval. A terminal outcome is written once; duplicate, late, or out-of-order callbacks cannot create a second event or reclassify a natural end. Cancellation of a recovery request or approval request produces no ended-early event unless the release actually completes.

## Notification and weekly summary presentation

An event notification is a calm status update, for example: **“Your Lockbox session ended early.”** The default notification preview is privacy-minimal and does not include apps, sites, messages, raw schedules, or a detailed reason. The sender can use system notification settings to hide previews; the product must not treat a preview as a secure channel.

Each recipient has independent quiet-hours presentation. During quiet hours, do not send an urgent push or bypass system settings. Keep the event in the authoritative inbox, show its queued/available state in the sender and recipient views when known, and deliver on the next permitted fetch/presentation opportunity. A late notice must say that delivery was delayed when that distinction is useful; it must not imply real-time observation. Cancellation or revocation before delivery prevents future delivery when possible, but cannot retract an already displayed system notification.

The optional weekly summary is plain and non-comparative. It reports counts/statuses for the agreed period, with no streaks, scores, rankings, or shame. Each source event contributes at most once even after retries, duplicate fetches, recovery races, or a late clock correction. If the period includes uncertain enforcement, show unavailable/integrity unknown rather than infer success. The owner can disable summaries per person; a recipient can opt out without losing independent event-control choices where the sender still has consent.

## Durability, privacy, and authority

Before clearing policy for ordinary recovery or trusted release, persist the event and an outbox record atomically with the session's terminal transition. Retry with a stable event ID and bounded backoff while offline. Delivery acknowledgement is separate from release, and failure to deliver never blocks recovery or emergency access.

The deployed relay must use the real PostgreSQL adapter, authenticated transport, and a documented identity/key lifecycle. The server inbox/fetch record is authoritative for delivery status; local state is authoritative for the immediate safety transition. The in-memory core, a local HTTP listener, APNs, SMS/text, or a manually copied link cannot substitute for this authority.

Retain only the minimum event and consent metadata for a bounded, documented period. The relay must delete or expire undelivered events and revoked relationship data according to that policy; owner relationship deletion must remove server-side accountability records where legally and operationally possible. Local history and summary material must have an explicit deletion action and bounded retention. Recipient deletion of a local notification/history copy cannot guarantee removal from OS notification caches, backups, or screenshots, so the UI must not promise that it does.

A locally controlled, reinstalled, clock-rolled-back, or permanently offline device cannot make accountability tamper-proof without a deployed durable authority. Reinstall must not silently recreate consent or a prior relationship. Clock rollback must not backdate an event, duplicate a weekly count, or turn an uncertain period into a natural end. These limitations are shown plainly in setup and the relationship status.

## Production acceptance gates

Do not expose this capability in ordinary release UI until the following specification-level tests and product QA are complete:

1. exact-session event binding, including frozen policy/session identity;
2. idempotent event delivery, acknowledgement, and retry;
3. offline outbox persistence and retry without delaying emergency access;
4. no duplicate weekly count across retries, duplicate fetches, or late events;
5. sender, recipient, pair, and identity revocation;
6. cross-owner isolation for identities, inboxes, summaries, and keys;
7. per-person quiet hours, queued presentation, cancellation, and late delivery;
8. natural-end versus recovery, trusted approval, authorization loss/integrity warning, and developer/emergency cleanup classification;
9. approval/recovery/natural-expiry race and duplicate/out-of-order callback handling;
10. reinstall, identity replacement, offline operation, and clock rollback;
11. privacy payload inspection proving no app selections, usage, messages, or raw schedules leak;
12. accessible consent, recipient selection, opt-out, status, notification, and supportive copy; and
13. production adapter, authenticated transport, identity lifecycle, retention/deletion, and explicit device/product QA using the deployed path.

Any failed gate leaves accountability deferred and the existing local recovery path intact.
