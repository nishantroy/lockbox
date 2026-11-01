# R5 slice P4 — APNs wake-up notifications (plan, 2026-11-01)

Status: **built and reviewed; review follow-up in progress.** Owner decision: build APNs now. APNs Key ID `ABC123DEFG` (Sandbox & Production, team-scoped). Team `ABCDE12345`, topic `com.phone-lockbox.app`. The owner adds the `.p8` to Vercel themselves; it never enters chat or the repo.

## Goal

When something needs a person's attention, their phone tells them, instead of them having to open the app and pull to refresh:

| Event (relay, after commit) | Who is notified | Banner text |
| --- | --- | --- |
| Owner sends **Ask now** (a new pending `TrustedRequest`) | every approver the request is addressed to | title `‹ownerName›`, body `Asks you to approve ending a lock early.` |
| Approver **approves** | owner | title `‹approverName›`, body `Approved your request. Open Phone Lockbox to end your lock.` |
| Approver **declines** | owner | title `‹approverName›`, body `Declined your request.` |
| Friend **accepts an invite** (pairing v3 accept) | owner | title `‹approverName›`, body `Joined as your trusted person.` |

Names are the signed display names the relay already stores (`ownerDisplayName` / `approverDisplayName` on the pairing / invite / acceptance). If a name is missing or blank, use `Phone Lockbox` as the title. Revocations, expiries and natural ends send nothing.

## Rules (unchanged R5 contract)

- **Push is a wake-up, never state or a credential.** The payload carries only the alert, `sound: default`, `thread-id: companion`, and a top-level `"kind": "request" | "answer" | "joined"`. No request IDs, approvals, signatures, tokens or session details. The app always fetches the signed inbox to learn what happened. Delivery failure changes nothing: the inbox fetch stays authoritative and recovery or emergency access never depend on it.
- **Never fail an operation because of push.** Sending runs after the database transaction commits, with a hard 3 s total timeout, errors swallowed and only counted. If APNs env vars are missing, push is disabled (a no-op); `/v1/health` is unaffected.
- **Never log** device tokens, the APNs JWT, the `.p8`, signatures or nonces. Logs may say `apns: sent n, failed m, pruned k`.

## Wire contract (both builders implement exactly this)

`POST /v1/push-token` — body is one `SignedOperation` (same envelope, signing and encoding as the inbox fetch) with `kind: "push_token"`, `expectedRevision: null`, and body bytes = Swift `JSONEncoder` `.sortedKeys` encoding (same date strategy as `InboxQuery`) of:

```
PushTokenRegistration {
  identityID: String         // must equal signer.identityID, else 403 unauthorized
  issuedAt: Date             // same freshness window as the inbox fetch (≤60 s future, ≤5 min old) else 401/expired
  token: String?             // lowercase hex APNs device token, 64–200 hex chars; null = unregister this identity's token(s) on `environment`
  environment: "sandbox" | "production"
}
```

Response `200 {"ok":true}`. Errors use the existing relay error codes and HTTP mapping (`malformed` 400, `invalid_signature` 401, `expired`, `unauthorized` 403, `rate_limited` 429, body too large 413). Global rate limits apply as for inbox.

A device can hold two identities (an owner identity and an approver identity). It registers the same device token under each identity it has.

## Slice P4-relay — Sonnet builder, owns `relay/**` only

1. **Migration `006_push_tokens.sql`:** table `companion_push_token (identity_id text, token text, environment text check in ('sandbox','production'), updated_at bigint, primary key (identity_id, token))`, index on `identity_id`. At most 5 rows per identity: on insert, delete the oldest beyond 5. Registering an existing `(identity, token)` updates `environment` and `updated_at`.
2. **Endpoint:** `relay/api/v1/push-token.ts` → `handlePushToken` in `handlers.ts` → `registerPushToken(rawBody, now, clientIP)` in `service.ts`, mirroring `fetchInboxOperation`'s decode → signature → rate limit → body decode → identity check → freshness order. Add `decodePushTokenRegistration` in `protocol.ts`.
3. **Sender `src/apns.ts`:**
   - ES256 JWT (`iss` = `APNS_TEAM_ID`, `kid` = `APNS_KEY_ID`, `iat`), signed with Node `crypto` from `APNS_KEY_P8` (PEM text; also accept `\n`-escaped). Cache the JWT in module scope and refresh after 50 minutes.
   - HTTP/2 via `node:http2` to `api.sandbox.push.apple.com` or `api.push.apple.com`, chosen per token row. Headers: `apns-topic` = `APNS_TOPIC` (default `com.phone-lockbox.app`), `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration` = now + 1 hour.
   - On `410`, or `400` with reason `BadDeviceToken` / `DeviceTokenNotForTopic`, delete that token row.
   - Behind a small `PushSender` interface so tests inject a fake. The real sender is used only when `APNS_KEY_P8`, `APNS_KEY_ID` and `APNS_TEAM_ID` are all set.
4. **Hooks in `submitOperation`** (after a successful commit only, never on idempotent replays that did not change state): compute the recipient identities and banner per the table above from the committed state, read their tokens, and send with the 3 s budget (`Promise.allSettled` plus a timeout). Await it before returning, because Vercel may freeze the function after the response; the budget keeps latency bounded.
5. **Retention:** the existing sweep also deletes token rows with `updated_at` older than 90 days.
6. **Tests** (vitest, local Postgres as today):
   - registration happy path, replacing and updating rows, the 5-row cap, unregister with `token: null`;
   - every error path (wrong identity, stale or future `issuedAt`, bad hex, bad environment, bad signature);
   - each of the four events notifies exactly the right identities with the right title and body;
   - no push on an idempotent replay or a failed operation;
   - sender errors or timeouts never fail the operation;
   - 410 and `BadDeviceToken` prune the row;
   - the JWT has the right header and claims and verifies with the public key (generate a throwaway P-256 key in the test);
   - the payload contains no IDs or secrets (assert its exact key set);
   - disabled when env vars are missing.

   Also add Swift-produced fixture bytes for a `PushTokenRegistration` operation to `test/fixtures`, produced by the same helper path as the existing fixtures if there is one; otherwise hand-build them with the existing canonical encoder and note it.
7. `npm test` and `npm run typecheck` must pass. Update `relay/README.md` with the endpoint and the env vars. **Do not deploy.**

## Slice P4-app — Sonnet builder, owns `CompanionKit/**`, `PhoneLockbox/**`, `PhoneLockboxTests/**`, `project.yml`, `PhoneLockbox/PhoneLockbox.entitlements`

1. **CompanionKit:** `PushTokenRegistration` model (same encoding as `InboxQuery`), a signed-operation builder for kind `push_token`, and `registerPushToken(token:environment:)` on the async client / HTTP transport → `POST /v1/push-token`. Encoding test plus a test that the signature verifies.
2. **Entitlement:** add `aps-environment` = `development` to `PhoneLockbox/PhoneLockbox.entitlements`; add it through `project.yml` if entitlements are generated there. Preserve the team, bundle IDs and App Group. No background modes.
3. **Token flow** (in a small `CompanionPushRegistrar` owned by `CompanionCoordinator` or the app):
   - A `UIApplicationDelegateAdaptor` (or the existing app delegate, if one exists) forwards `didRegisterForRemoteNotificationsWithDeviceToken` as lowercase hex.
   - On launch, if notifications are already authorized, call `registerForRemoteNotifications()`.
   - Ask for notification permission (`.alert, .sound, .badge`) at the moment it matters, never on first launch: right after the owner creates an invite link, after a friend taps Accept, and after the owner taps Ask now. If permission was already decided, don't ask again.
   - Register the token under every local identity (owner and/or approver) with the relay. Persist a hash of `(identityID, token, environment)` in the App Group; re-send only when it changes or every 7 days. Failures retry on the next launch or foreground. `environment` is `sandbox` in DEBUG builds and `production` otherwise.
   - When a new identity is created (the first invite or accept), register for it too.
   - Never log the token.
4. **Receiving:** a `UNUserNotificationCenterDelegate` that coexists with the existing wind-down notification handling (inspect it first and keep its behavior byte-for-byte).
   - For payloads with a top-level `kind` in `request | answer | joined`, refresh the companion inbox. In the foreground, still show the banner with sound.
   - On tap, switch to the People tab and refresh.
   - Other notifications keep their current behavior.
5. **People UX:** if notification permission is **denied**, show one quiet row in People: `Notifications are off, so you won't hear about requests.` with an **Open Settings** button (`UIApplication.openSettingsURLString`). Show it only when the person has at least one pairing. Real copy, no "relay". Accessibility label and Dynamic Type.
6. **Tests** (host-testable, no simulator runs by you):
   - the registrar's dedupe and 7-day logic with an injected clock and transport;
   - hex formatting;
   - environment selection;
   - kind parsing (unknown kinds are ignored);
   - the denied-row visibility rule.
7. Validate with `swift test` (CompanionKit and the root package), plus a compile-only `xcodebuild build` for the simulator SDK into your worktree's `.build-cache` folder. **No simulator, no `xcodebuild test`.** Run `xcodegen generate` if you touch `project.yml`.

## Gates

1. Each builder commits on its own branch in its worktree. The parent merges both into `r5-relay` (compile-only).
2. **Opus review, high:** relay and app together. It checks:
   - no secrets or IDs in payloads or logs;
   - push never affects an operation's outcome;
   - correct recipients, with cross-owner isolation (only that request's approvers are notified);
   - token ownership checks;
   - retention;
   - coexistence with the existing notification delegate;
   - the permission prompt timing.
3. **Relay deploy**, needing the owner: migration 006 runs, then `vercel env add` for `APNS_KEY_P8` (the owner pastes the `.p8` contents), plus `APNS_KEY_ID=ABC123DEFG`, `APNS_TEAM_ID=ABCDE12345` and `APNS_TOPIC=com.phone-lockbox.app`, then `vercel deploy --prod`, health, and `relay-smoke`.
4. The pre-push unit and UI suites run, followed by the UX review of the new People row and the permission prompt timing.
5. **Device QA by the owner:** Ask now on the iPhone produces a banner on the friend simulator (simulators on Apple silicon receive sandbox pushes); approve produces a banner on the iPhone; tapping it opens People. With the developer toggle **Friend approval can end locks (prototype)** on, **End lock now** releases that exact lock. That last step is the long-pending device test of friend release.

## Build results (2026-11-01)

- **P4-relay:** Sonnet builder (`claude-sonnet-5-5`), commit 3e2e9e2, merged as 5af97f2. Adds migration 006, `POST /v1/push-token`, `src/apns.ts` (ES256 JWT, `node:http2`, `PushSender` interface), `src/push-store.ts`, the hooks in `submitOperation`, and the 90-day token purge. Relay checks after merge, run by the parent: typecheck clean; `npm test` **222/222**.
- **P4-app:** Sonnet builder (`claude-sonnet-5-5`), commits 18c4451, 8674d25 and 5e1dd3e, merged as 92b79ea. Adds `PushTokenRegistration` and `registerPushToken` in CompanionKit, `PushWakeup.swift` (registrar, ledger, kind parsing; host-tested), `PushNotificationSupport.swift` (app delegate, notification delegate, wake bridge), the `aps-environment` entitlement and the People "Notifications are off" row. The prompt is asked only after create invite, Accept or Ask now.
- **Parent checks on the merged tree (66ba25e):**
  - CompanionKit `swift test` **165/0**; root `swift test` **187/0**;
  - compile-only simulator build **succeeded**;
  - `tools/relay-smoke` (which now registers and unregisters push tokens) against the local relay: **all 26 steps passed**. This proves that Swift-signed `push_token` operations are accepted by the TypeScript relay. APNs was not configured locally, so no real push was sent.

## Opus review (high, `claude-opus-5-5`), f3063e8..66ba25e

No P1. Findings and disposition:

| ID | Finding | Disposition |
| --- | --- | --- |
| P2-1 | Approvers who paired on an earlier build are never asked for permission, so they never register | Fix: a fourth moment, when People appears with an active approver pairing and permission is undecided |
| P3-1 | 5-row cap can be exceeded under concurrent registrations | Fix: advisory transaction lock |
| P3-2 | Cached JWT kept after a 403 | Fix: reset on 403 |
| P3-3 | Stream closed without `end`/`error` waits for the 3 s budget | Fix: resolve on `close` |
| P3-4 | Environment from DEBUG vs entitlement hard-coded `development` | Latent (device builds are Debug); revisit with TestFlight |
| P3-5 | Registration counted as sent when self/identity is missing | Fix: throw |
| P3-6 | 7-day dedupe doesn't notice relay-side pruning | Accepted for the prototype |
| P3-7 | No Swift byte check of the relay fixture | Covered by the passing relay-smoke interop run |
| P3-8 | Decline copy with several approvers | Left for the UX review |
| Nits | Migration comment; duplicate hex helper; app never unregisters | Fix the first two; the third is fine (no identity-reset path) |

## Follow-ups after review (2026-11-01)

All builders were Sonnet (`claude-sonnet-5-5`); all reviewers were Opus (`claude-opus-5-5`).

- **Code review follow-up** (merge 78e34e5):
  - P2-1: a prompt moment for approvers who are already paired;
  - P3-1: advisory lock on the 5-row cap (16-way concurrency test);
  - P3-2: JWT reset on a 403;
  - P3-3: stream resolves on `close`;
  - P3-5: registration throws instead of counting as sent;
  - one hex helper; migration comment fixed.

  Relay 227/227; root 188/0.
- **First pre-push suites** (78e34e5): unit **138/0 (1 skipped)**, UI **4/4**. They fed the UX review in [2026-11-01-ux-apns.md](reviews/2026-11-01-ux-apns.md).
- **UX review fixes** (merge e239e80):
  - P1-1: the decline banner is decided from the committed request status (pending → "Declined. Others you asked can still answer."; declined → "Declined your request."; approved → none);
  - approve copy is "Approved ending your lock early.";
  - request copy is "Asks to end their lock early." (and the Waiting row reads "‹Name› asks to end their lock early");
  - fallback titles;
  - invite prompt deferred until the owner returns to the app or taps Copy link, with a footnote;
  - "Get notified" card replaces the automatic prompt when People appears;
  - role-aware denied-row copy and a quiet "Turn On" row;
  - no foreground banner while on People;
  - only `[.alert, .sound]` requested;
  - accepted-notice copy;
  - Copy link label no longer cross-fades.

  P3-7 (lock-screen placeholder) left as is. Relay 231/231; root 195/0.
- **Delta code review (medium)** of e239e80: no P1. Fixed:
  - P2-1: the deferred invite prompt now expires after 10 minutes, because the share sheet doesn't change the scene phase;
  - P3-1: the card also shows for owners with trusted people;
  - P3-2: the checkmark animates again.

  P3-3 (unreachable defensive guard) kept. Merge 492a8aa, plus the parent's title fix 261e0ed.
- **Second pre-push run** (e239e80): unit 138/0. UI: 4 of 5; `testNotificationsOffRow…` failed once with `notFound` from the scripted friend's invite lookup, then passed when run alone. The follow-up added a lookup retry helper with step-labelled failures and waits for the link value. The root cause was not confirmed.
- **Final pre-push suites** (261e0ed): unit **138 tests, 0 failures, 1 skipped**; UI **5/5** (new denied-row screenshot `09-notifications-off-row`). Host checks: CompanionKit 165/0, root 197/0, relay 231/231.
