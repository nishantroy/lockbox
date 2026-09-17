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
