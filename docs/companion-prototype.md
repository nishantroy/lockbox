# Accountless trusted-person companion prototype

This is a standalone Swift 6 package in [`../CompanionKit`](../CompanionKit) and a deliberately isolated native developer view in [`../PhoneLockbox/Companion/CompanionPrototype.swift`](../PhoneLockbox/Companion/CompanionPrototype.swift).

## What is implemented

- Owner and trusted-approver device identities use Curve25519 signing keys. `KeychainDeviceKeyStore` stores private key material with `ThisDeviceOnly` accessibility on iOS (`AfterFirstUnlockThisDeviceOnly`; macOS uses the closest available Keychain accessibility). A missing key produces `needsRepair`/`keyUnavailable`; an old trusted identity is never silently recreated.
- Invitation links are accountless, signed, bounded, one-use owner invitations. A link can be copied or forwarded, but possession only creates a pending acceptance. The approver signs acceptance, then the owner must explicitly confirm the exact approver and displayed six-digit verification code.
- Every relay mutation is a signed operation. Signatures use a domain-separated, framed canonical field encoding; operation bodies use sorted-key JSON only as a transport representation and are signed by digest. The relay checks the signer/key identity, role, ownership, pairing state, pairing epoch, request target, exact session ID and active-set ID, timestamps, expiry, and replay markers.
- R5 relationship permissions are versioned and bilateral. `approveEarlyEnd` and `receiveRequests` are granted by the owner and independently accepted by the trusted person for one exact pairing epoch. `mutualPact` is reserved until a separately pairing-bound pact operation is reviewed; it cannot authorize anything. Consent is enforced under the relay transaction lock; no consent is inferred from pairing. `earlyEndNotices` and `weeklySharedSummaries` are reserved schema capabilities and are never active or deliverable here.
- Exact-session requests select explicit pairing/approver bindings and have only the `approveEarlyEnd` purpose. Multiple selected approvers use one-of-N first-valid semantics: the first accepted approval wins, and each approval has a fresh nonce, immutable signature, and one-use operation/consumption markers. Requests carry no app selections, usage, steps, task material, start, extension, or rule-change authority; free-form legacy messages are dropped during decode.
- Requests have `pending`, `approved`, `declined`, `cancelled`, and `expired` states. Natural session end, cancellation, consent revocation, pairing revocation, and pairing/key replacement invalidate later use. A decline only updates that approver's decision. An approver cannot publish a session, extend it, or issue an untargeted/global approval.
- Approval verification is single-use. The relay stores the accepted approval immutably and the owner can consume only that exact record, with its approved decision, targeted identity, pairing epoch, request/session/active-set bindings, and current active session all matching. Both approval ID and use ID are replay protected. The owner may cancel an approved but not-yet-consumed request; cancellation is persisted under the relay lock and rejects later use. This returns a cryptographically bound verification record, not a Managed Settings action.
- `InMemoryCompanionRelay` is a deterministic, lock-protected relay-shaped test backend with signed-operation authentication, ownership authorization, revocation, rate limits, inbox fetch, and JSON snapshot/restart support. It is not HTTP, a server, a listener, APNs, or a production persistence service.
- `LocalRecoveryRequest` is an independent fixed 900-second local fallback. Natural session end supersedes confirmation; the caller cannot supply a shorter delay.
- `QuietHoursPolicy` suppresses only private local approver-notification presentation. Inbox state, expiry, approvals, and history are not changed. There are no scores or usage-sharing fields.
- Optional `BedtimePact` models two trusted participants signing their own finite period/profile digest. Acceptance never grants remote start, extension, enforcement, or access to the other participant's profile. An accepted pact cannot be cancelled as if it were an uncommitted proposal.

The native view is a minimal developer harness. It labels the relay as simulated and explicitly says that no remote unlock is connected. It does not import or call Screen Time, Family Controls, Managed Settings, or the existing coordinator. The parent can link the package later without creating app-global authorization side effects.

## Foreground transport contract

`CompanionTransport` has a signed `submit` operation and `fetchInbox`. Foreground fetch is authoritative. A future APNs integration may be a wake hint only; it must not carry authority or replace inbox reconciliation. No network transport or delivery claim is present in this repository, and no APNs credentials, listener, port, account, email, phone, SMS, hosting, or deployment setup is used.

Messages can be shared manually using `Invitation.shareLink` (for example, in Messages) as a reminder channel. The link is not an unlock token. The owner must verify the approver identity and code in the separate confirmation step.

## Validation

From the repository root:

```sh
swift test --package-path CompanionKit
```

The package has 31 tests covering forged and swapped identities, forwarded-link non-authority, bilateral R5 consent, generation-bound revocation/regrant, legacy terminal migration, R6/reserved scope misuse, stale consent after pairing replacement, one-of-N first-valid approval, one-use approval nonces, one-use invite confirmation across competing acceptances, replay and one-time approval use, cancellation after approval (including restart), exact accepted-approval/request/session/active-set bindings, multiple same-identity pairings and revocation, declined-target rejection, cross-request approval-ID collisions, revocation, expiry and cancellation, multiple-target decline/approval, rate limiting, quiet hours, malformed and cross-owner snapshot graphs, tampered invitation signatures, bounded replay-marker snapshots, missing keys, delayed recovery, and the non-forcing pact model. The durable relay package adds 14 transactional authorization/integrity tests, including the closed command allowlist, owner-locked reducer, exact session/generation checks, crash/retry receipts and regrant invalidation. They run with in-memory keys and deterministic clocks; they do not prove network delivery, Keychain behavior on a physical device, APNs behavior, or remote unlock.

## Review disposition (Terra P1/P2 findings)

All findings in the latest companion review are fixed in the owned protocol/relay lane:

The friend-permission slice adds the following bounded guarantees:

- Consent is stored per relationship/pairing epoch with a schema version, backward decode defaults, and no capability inheritance across re-pairing. Owner grant and approver acceptance are separate signed operations and are checked atomically with request/approval authorization.
- A request is an exact active session/active-set record and names only selected relationship IDs and approver IDs. Each target carries the immutable bilateral-consent generation; approval signatures/nonces and use commands carry the same generation. Any consent mutation advances the generation and terminally expires outstanding requests in the same transaction, so regrant, restart, and lost acknowledgements cannot resurrect authority. Approval is accepted only for those bindings and for both active R5 scopes; a stale, revoked, replaced, cancelled, naturally ended, or already-won request cannot be consumed.
- R6/reserved names can be decoded for schema compatibility, but relay authorization rejects them and the durable command boundary is closed-default-deny: start, extend, policy/rule changes, delivery, summaries and unknown kinds are not accepted regardless of caller-supplied lists. This package does not add an inbox provider, listener, hosting choice, APNs sender, or production enforcement connection.

- **P1 approved-request cancellation:** owner cancellation now accepts pending or approved requests only while an approval is unconsumed, persists `.cancelled` before acknowledgement, and rejects use before and after snapshot restart.
- **P1 unaccepted or mismatched approval use:** `use` requires the relay's stored approval for the supplied ID to be value-identical, approved in the request's persisted decision map, explicitly targeted, and bound to the current request/session/active set and active pairing epoch. Directly signed, stale, wrong-set, and declined approvals are regression-tested.
- **P2 decoded pairing/snapshot validation:** pairing IDs and creation timestamps are validated; snapshot record counts and every replay-marker ID are bounded and validated before restore.
- **P2 approval-ID collision:** duplicate approval IDs are rejected before request state mutation, preventing cross-request audit overwrite.
- **P1 one-use invite confirmation:** confirmation checks the consumed-invite marker while holding the relay lock and atomically discards every other pending acceptance for that invite. A second confirmation returns replay; the two-acceptance regression covers this race shape.
- **P1 exact per-target pairing binding:** requests persist a binding for every target's pairing ID and epoch. Submission and consumption require that exact binding, not merely the approver identity. Same-identity re-pairing and revocation-after-approval are covered by regression tests.
- **P2 snapshot authentication and graph integrity:** restore verifies every invitation signature, requires a single relay owner for invitations/pairings/sessions/requests, checks request-to-session and request-to-pairing references, checks approval-to-request/pairing/decision references, and validates replay markers. The complete graph is validated before any decoded record is installed, so restore fails closed. Tampered signatures and cross-owner/cross-record snapshots are tested.

These are protocol/backend prototype guarantees only. The relay remains in-memory with test snapshot persistence and is not a deployed service.

## Security boundaries and follow-up

This is a protocol/harness prototype, not a deployed trusted service. The in-memory relay is process-local and its JSON snapshot is test persistence; a real service needs carefully reviewed durable atomic storage, authenticated transport, key rotation/re-pair UX, abuse monitoring that does not collect sensitive usage, and a threat-model review. Curve25519 signatures authenticate protocol records but cannot prove that the owner phone's local enforcement is currently active. The package intentionally does not implement remote enforcement or coordinator integration; the parent must decide how any verified approval is safely consumed by the local lock lifecycle.
