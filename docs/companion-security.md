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

- **The token never reaches the relay.** The owner device generates 16 random bytes (22 base64url characters); it
  lives only in the link and on the owner's device (the app must persist it while the invite is live). Three
  domain-separated values derive from it:
  - `lookupKey = H("invite-lookup", token)`: the only handle the relay stores or is asked for
    (`companion_invite_token.lookup_key`, the signed invite payload, and the friend's `POST /v1/invite/lookup` body).
    Anyone with the link can compute it; the relay cannot invert it.
  - `tokenHash = H("invite-token", token, ownerPublicKey, inviteID)`: signed into the invite. The friend recomputes it
    from the token in the link, so an invite not issued by that owner for that token is rejected. A relay that only
    knows the lookup key cannot forge or swap an invitation (it can return one, but it cannot make `tokenHash` match).
  - a **possession keypair**: Ed25519 with seed `H("invite-possession", token)`. Its public key is signed into the
    invite; the acceptance carries a signature by the private key over (acceptanceID, inviteID, owner, approver key,
    lookup key). The relay verifies it before consuming the invite, so a database or log reader who holds only the
    lookup key cannot burn invites.
  - `tokenProof = H("accept-proof", token, approverPublicKey, acceptanceID)`: carried in the friend's acceptance and
    stored by the relay (ledger pairing record and operation log) but verifiable only by someone holding the token.
- **Who verifies what.** The relay gates accept on the lookup key, the friend's signature and the possession signature;
  it cannot check `tokenProof`. The **owner device** verifies it (`JoinedAcceptanceCheck`) against the invite and token it stored, plus the
  signer, scopes, pairing ID derivation and names. A relay that stores the lookup key can create a pairing for its own
  key, but the owner will not show or trust it. It can still deny service (consume the invite).
- **Lookup.** `POST /v1/invite/lookup` is unauthenticated, rate limited per client IP, and returns only found /
  not-found (unknown, expired and consumed are one answer). A wrong lookup key or unknown invite at accept time is a
  single `unauthorized`. Comparisons use constant-time equality.
- **Coverage.** The owner signature covers token hash, lookup key, owner name and granted scopes; the friend signature
  covers lookup key, proof, friend name and accepted scopes (which must equal the grant). Names are metadata only,
  never authority; both sides apply identical rules (1-40 scalars, well-formed Unicode with no lone surrogates, no
  control, bidi or invisible-mark scalars, not blank).
- **Atomicity.** Accept verifies both signatures, consumes the invite, creates the pairing and writes consent in one
  owner-row transaction; any failure leaves the invite usable. A retry of a lost response under a new operation ID
  returns the same friend's existing pairing instead of an error.
- **Single use and tombstones.** The token row stays as a consumed tombstone until the invite expires so no other owner
  can re-register the lookup key. Token rows (live, expired or consumed) are deleted by the daily retention cron 30 days
  after `max(consumedAt, expiresAt)` (for a consumed invite that is its expiry, never earlier), together with the ledger invite, so an expired lookup key cannot be re-registered; lookups reject
  expired and consumed invites regardless.
- **Where secret-derived material is stored.** Never the token. The relay stores the lookup key, token hash and proof
  (in the owner ledger, the token index and the operation log) for the 30-day retention window, plus the friend-signed
  acceptance with the pairing. None of these lets the relay forge an invite or an owner-trusted acceptance.
- **Owner storage.** The owner must keep each `IssuedInvite` (invitation plus token, now `Codable`) for as long as the
  pairing it created exists and delete it when the owner removes that person: `JoinedAcceptanceCheck.verify` needs it on
  every inbox fetch. The token is a secret; keep it in the Keychain or another protected store, not plain defaults. `IssuedInvite` redacts the token from `description`, `debugDescription` and `Mirror`/`dump`, but its `Codable` form contains it, so persisted bytes must go to the Keychain.
- **Trust sources.** Pairings created before v3 or by `replace_pairing` carry no acceptance, so `verifiedPairings`
  never returns them; the app needs another trust source for those (prototype: re-pair).
- **Accepted risk.** Anyone holding an unexpired, unused link becomes a trusted person without owner approval. That is
  the accepted risk: link holders, not the relay. It is acceptable because an approver can only approve ending a session
  the owner explicitly asks *them* about, never start, extend or observe a lock; links are single-use, short-lived
  (at most 7 days; the app chooses the lifetime) and unguessable; the owner sees every person (and the joined notice)
  and can remove them. A link leaked to a third party, or intercepted before the friend uses it, has the same effect.
  R6 status sharing must add an explicit, informed confirmation first.
- **Deploy order (forward only).** Apply migrations 004 and 005, deploy the relay, then ship the app. There is no
  rollback once v3 pairings exist: an old reducer cannot read v3 invites or pairing records.

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
