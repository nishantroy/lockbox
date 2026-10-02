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

## Pairing acceptance boundary (R5 pairing v2, Slice P2b, 2026-10-02)

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
