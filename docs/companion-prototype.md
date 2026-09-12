# Accountless trusted-person companion prototype

This is a standalone Swift 6 package in [`../CompanionKit`](../CompanionKit) and a deliberately isolated native developer view in [`../PhoneLockbox/Companion/CompanionPrototype.swift`](../PhoneLockbox/Companion/CompanionPrototype.swift).

## What is implemented

- Owner and trusted-approver device identities use Curve25519 signing keys. `KeychainDeviceKeyStore` stores private key material with `ThisDeviceOnly` accessibility on iOS (`AfterFirstUnlockThisDeviceOnly`; macOS uses the closest available Keychain accessibility). A missing key produces `needsRepair`/`keyUnavailable`; an old trusted identity is never silently recreated.
- Invitation links are accountless, signed, bounded, one-use owner invitations. A link can be copied or forwarded, but possession only creates a pending acceptance. The approver signs acceptance, then the owner must explicitly confirm the exact approver and displayed six-digit verification code.
- Every relay mutation is a signed operation. Signatures use a domain-separated, framed canonical field encoding; operation bodies use sorted-key JSON only as a transport representation and are signed by digest. The relay checks the signer/key identity, role, ownership, pairing state, pairing epoch, request target, exact session ID and active-set ID, timestamps, expiry, and replay markers.
- Requests have bounded optional messages and `pending`, `approved`, `declined`, `cancelled`, and `expired` states. Targets are explicit. Multiple active pairings can be targeted; any targeted approver may approve. A decline only updates that approver's decision. An approver cannot publish a session, extend it, or issue an untargeted/global approval.
- Approval verification is single-use. The owner consumes the signed approval against the exact request and current session; both approval ID and use ID are replay protected. This returns a cryptographically bound verification record, not a Managed Settings action.
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

The package tests cover forged and swapped identities, forwarded-link non-authority, replay and one-time approval use, revocation, exact session/active-set changes, expiry and cancellation, multiple-target decline/approval, rate limiting, quiet hours, restart snapshots, missing keys, delayed recovery, and the non-forcing pact model. They run with in-memory keys and a deterministic relay clock; they do not prove network delivery, Keychain behavior on a physical device, APNs behavior, or remote unlock.

## Security boundaries and follow-up

This is a protocol/harness prototype, not a deployed trusted service. The in-memory relay is process-local and its JSON snapshot is test persistence; a real service needs carefully reviewed durable atomic storage, authenticated transport, key rotation/re-pair UX, abuse monitoring that does not collect sensitive usage, and a threat-model review. Curve25519 signatures authenticate protocol records but cannot prove that the owner phone's local enforcement is currently active. The package intentionally does not implement remote enforcement or coordinator integration; the parent must decide how any verified approval is safely consumed by the local lock lifecycle.
