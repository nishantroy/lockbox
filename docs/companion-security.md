# Companion permission snapshot boundary

CompanionKit and CompanionRelayService restore mutable snapshots only with an
independently retained checkpoint. A checkpoint contains the exact owner
revision (or the exact per-owner revision map for the durable aggregate) and a
SHA-256 root over every authoritative state field using stable sorted
encoding. Requests also retain and validate their signed request operation/body
on anchored restore.

The embedding must keep the checkpoint in trusted monotonic storage separate
from the mutable snapshot/database. Copying the checkpoint beside the
snapshot, or deriving a new checkpoint from an untrusted snapshot, provides no
rollback or fork protection. Checkpoint rotation is permitted only after the
transaction that produced the corresponding state has committed. A revision
number without the canonical root is not an anchor.

The in-memory durable store and its checkpoint implementation are strict
reference/test adapters. They are not a production database, monotonic
storage provider, hosted service, transport, APNs provider, or authenticated
storage claim. A production adapter must independently protect and atomically
advance the checkpoint, preserve the signed operation records, and fail closed
when either checkpoint or state-root verification fails. The old unanchored
restore constructors are internal test seams only; public restore requires the
checkpoint overload.

## Pairing v3 token model and accepted risk (R5 pairing v3, Slice P3a, 2026-10-31)

`docs/r5-pairing-v3-plan.md` removed the owner confirm step: creating an invite is the owner's grant of
`approveEarlyEnd` + `receiveRequests`, and accepting it is the friend's consent. Security properties:

- **Token.** The owner device generates 16 random bytes (22 base64url characters). It is the relay lookup key and the
  bearer secret. Only its domain-separated SHA-256 (`tokenHash`) is signed into the invite and stored by the relay
  (ledger and `companion_invite_token`), so a database leak yields no live token. The plaintext appears only at lookup
  and in the friend's accept body (and is then dead: single use). The owner chooses the token (not the relay) and
  signs its hash, so the relay cannot swap one invite for another. Comparisons use `timingSafeEqual`.
- **Lookup.** `POST /v1/invite/lookup` is unauthenticated, rate limited per client IP, and returns only found /
  not-found (unknown, expired and used are one answer). A wrong token or unknown invite at accept time is a single
  `unauthorized`.
- **Coverage.** The owner signature covers token hash, owner name and granted scopes; the friend signature covers the
  token, friend name and accepted scopes (which must equal the grant). Names are metadata only, never authority.
- **Atomicity.** Accept verifies both signatures and the token, consumes the invite, creates the pairing and writes
  consent in one owner-row transaction; any failure leaves the invite usable.
- **Owner verification.** With no confirm step, the owner device must not take the relay's word for who joined. The
  relay returns the friend-signed acceptance behind each pairing and `JoinedAcceptanceCheck` proves it answers an
  invite this device created (token hash, scopes, signer, ID derivation, names).
- **Accepted risk.** Anyone holding an unexpired, unused link becomes a trusted person without owner approval, and a
  relay that observes the token in transit could race the friend with its own key. Acceptable because an approver can
  only approve ending a session the owner explicitly asks *them* about, never start, extend or observe a lock; links
  are single-use, short-lived (<=7 days, 1 hour by default) and unguessable; the owner sees every person (and the
  joined notice) and can remove them. R6 status sharing must add an explicit, informed confirmation first.

## Pairing acceptance boundary (superseded by pairing v3 above; R5 pairing v2, Slice P2b, 2026-10-02)

`docs/r5-pairing-v2-plan.md`'s "Owner decision" replaced the owner typing a
six-digit code read aloud by the friend with a relay-delivered acceptance the
owner confirms with one tap. The app-side (`CompanionCoordinator`) boundary
this depends on:

- The owner device keeps every `Invitation` it creates in local storage
  (`storedInvites`, App Group), keyed by `inviteID`, until it is consumed
  (confirmed) or explicitly discarded.
- A relay-delivered `SignedAcceptance` (`InboxResponse.pendingAcceptances`) is
  shown to the owner, and can be confirmed, **only** if it verifies with
  `CompanionKit.OwnerAcceptanceCheck.verify` against an invite found in that
  local store — never against the acceptance's own claimed `inviteID` alone.
  An acceptance for an invite this device never created, already confirmed,
  or already discarded is silently dropped, not shown.
- **Not them** removes the card immediately and discards the local invite. No
  relay "cancel invite" endpoint exists in this protocol version
  (`CompanionCoordinator.discardStoredInvite`'s doc comment records this), so
  the local discard is the only mechanism — but it is sufficient on its own,
  because the verification step above requires an invite this device still
  holds; once discarded, nothing (including the identical acceptance
  reappearing on a later inbox fetch) can ever be confirmed from it again on
  this device. The invite also still expires naturally relay-side.
- **Accepted risk (recorded in the pairing v2 plan):** a malicious relay
  operator could inject an acceptance signed by a key it controls. The owner
  might confirm it, believing it is their friend. The relay is owner-operated
  in this prototype; the mitigation is **Not them** plus revoke at any time —
  not a cryptographic guarantee that the relay is honest about who accepted.
  R6 (sharing status with trusted people) must add an explicit, informed
  confirmation before any status sharing is enabled, and should reconsider a
  matching-word check at that point.
