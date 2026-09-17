# Weekend rule core (R8 first slice)

Status: **pure source-only contract; not integrated with the app runtime**.

This document describes the bounded first multi-rule slice in
`PhoneLockbox/Policy/WeekendSchedule.swift`. It does not authorize a DeviceActivity
registration, a ManagedSettings mutation, or a storage migration.

## Scope and invariants

The model has exactly two optional slots:

- `weekday` — stable rule identity `weekday`; enabled days are a non-empty subset
  of Monday through Friday.
- `weekend` — stable rule identity `weekend`; enabled days are a non-empty subset
  of Saturday and Sunday.

A slot contains its enabled day set, local `start` and `end` (`LocalTime`), and an
opaque `WeekendPolicySnapshot`. The snapshot contains a stable digest reference,
a bounded non-negative policy revision, and immutable serialized policy bytes. The
reference is exactly `sha256:<64 lowercase hexadecimal digits>` for the snapshot
bytes; the core verifies that digest without interpreting or logging the opaque
bytes. References are at most 128 UTF-8 bytes and snapshots are non-empty and at
most 64 KiB. There is no arbitrary rule array, third priority, priority/precedence,
skip, vacation, snooze, or one-off exception.

A present rule must have at least one enabled day and different boundaries. The
schedule revision is bounded to `0...999,999,999` and must increase for each
persisted schedule edit. The constructor rejects a rule in the wrong slot and
rejects any conflict before a schedule can be resolved.

## Schema and legacy shape

`WeekendSchedule` encodes schema version 1:

```json
{
  "schemaVersion": 1,
  "revision": 12,
  "weekday": {
    "id": "weekday",
    "enabledDays": ["monday"],
    "start": { "hour": 22, "minute": 0 },
    "end": { "hour": 7, "minute": 0 },
    "policy": {
      "reference": "sha256:039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
      "revision": 7,
      "snapshotData": "AQID"
    }
  },
  "weekend": null
}
```

`enabledDays` is encoded as a bounded, non-empty array of the exact lowercase
strings `sunday`, `monday`, `tuesday`, `wednesday`, `thursday`, `friday`, and
`saturday`, in Sunday-to-Saturday order. Decoding rejects integer day values,
unknown/mixed-case names, duplicates, unsorted arrays, and arrays longer than
seven before constructing the set. Rule identity is encoded and checked, rather
than inferred from a display label. A schedule can be empty because both profiles
are optional. There is no v1 integer-day compatibility migration; old integer or
malformed documents are rejected and must remain available for a separately
approved, locked migration.

`WeekendScheduleMigration.fromLegacyDaily` is intentionally a pure conversion
from the existing `LockboxConfiguration` (`start`, `end`, `enabled`). An enabled
legacy daily rule, which historically applied every day, becomes two profiles
with the same local boundaries and policy snapshot: the weekday profile owns
Monday-Friday and the weekend profile owns Saturday-Sunday. A valid but disabled
legacy configuration becomes an empty schedule. Invalid legacy boundaries fail
migration; no best-effort or broad fallback is allowed.

The migration function does not read or write App Group data. The eventual
storage migration must be a separate, locked transaction: decode and validate the
old document, construct and validate this shape, write a temporary new document,
fsync/atomically replace it, and only then record the schema/revision migration
marker. On any decode, conflict, or write failure, retain the old document and
surface the failure. Do not let the app and monitor observe different versions.

## Resolution contract

`currentOrNext(after:calendar:)` and `nextOccurrence(after:calendar:)` accept only a
Gregorian `Calendar` with a Foundation-recognized timezone identifier. Resolution
reconstructs a Gregorian calendar from that timezone, rather than inheriting an
alternate calendar contract, and returns a value type containing:

- a stable `WeekendOccurrenceID`;
- rule identity and schedule revision;
- the local civil date on which the rule starts;
- absolute `start` and `end` dates;
- the calendar timezone identifier used for resolution; and
- the exact frozen policy snapshot from the rule.

`WeekendCivilDate` validates a real Gregorian date. `WeekendOccurrenceID` and all
schedule/policy revisions reject negatives and values above `999,999,999`.
Occurrence decoding validates that the timezone identifier exists, that `start`
and `end` are finite with `end > start`, that every duplicated identity field
matches the ID, and that the decoded local start date is exactly the Gregorian
civil date of `start` in the reconstructed timezone. A detached or malformed
occurrence is rejected.

Occurrences are half-open: `[start, end)`. At the start boundary the occurrence
is current; at the end boundary it is over and the resolver returns a later
occurrence. Overnight windows use the next local civil day for `end`. The resolver
checks every enabled day around the query, including the previous week, so a
Saturday or Sunday morning can correctly be the tail of an overnight occurrence
whose start day is Friday or Sunday.

Civil boundaries use Foundation's `.nextTime` and `.first` repeated-time policy:

- a nonexistent DST boundary moves to the next valid instant (for example,
  02:30 becomes 03:00 on a spring-forward day);
- a repeated boundary uses its first occurrence; and
- future resolution uses the current calendar timezone. A timezone change can
  therefore produce different future absolute dates while preserving local
  clock values.

Once an occurrence is handed to a later runtime, its absolute end and policy
snapshot are frozen. A timezone change, edit, or policy revision must not
recompute or mutate that active occurrence. A new schedule revision receives new
occurrence identities.

## Conflict contract

There is no precedence. The schedule rejects the pair when weekly local-time
intervals overlap. Boundary contact is rejected as a conflict as well, even
though runtime occurrence resolution is half-open; this keeps registration and
callback ownership unambiguous. Weekly comparisons include the repeated week so
these cases are covered:

- same-day overlap;
- a Friday weekday window crossing into Saturday;
- a Sunday weekend window crossing into Monday;
- strict overnight overlap; and
- overnight end exactly touching the other rule's start boundary.

The error identifies both stable rule IDs, each start day, and whether the
conflict is boundary-only. No conflict is silently resolved by priority or by
changing a policy.

## Future adapter decisions (not implemented here)

`WeekendScheduleAdapter` defines names without importing or registering Apple's
frameworks:

- activity names are fixed `phone-lockbox.schedule.v1.weekday` and
  `phone-lockbox.schedule.v1.weekend`; they do not contain a display name,
  timezone, or policy bytes;
- occurrence identity is
  `phone-lockbox.occurrence.v1.<rule>.r<scheduleRevision>.<YYYY-MM-DD>`;
- occurrence identity uses the local civil **start** date, not a recomputed epoch,
  so a timezone change or duplicate callback cannot create a second identity for
  the same resolved rule occurrence; and
- the adapter must bind callbacks to both activity/rule identity and occurrence
  identity, then use the persisted frozen end and policy snapshot. It must not
  treat a stable activity name as proof that an occurrence is active.

The core deliberately does not call `DeviceActivityCenter.startMonitoring`,
`stopMonitoring`, `ManagedSettingsStore`, or existing `RuntimeStore` APIs. Policy
bytes remain opaque value data; the digest is the only reference/snapshot binding
performed here, and a later adapter must still validate its own policy format
before applying it.

## Integration gates

Before app/monitor integration, a reviewer must accept this pure core and its
exhaustive tests. The later integration change must then provide all of the
following before device QA:

1. an atomic App Group schema migration with rollback-safe old-data retention;
2. one shared validated document consumed by app and monitor, with no local
   defaults fallback;
3. conflict preview and rejection in the editor before any side effect;
4. a persisted schedule revision and active occurrence record written before
   registration or policy application;
5. frozen absolute end and policy snapshot for every active occurrence, including
   relaunch, reboot, callback replay, and timezone/DST changes;
6. callback handling bound to the stable rule/activity and occurrence IDs, with
   natural-end precedence and stale/duplicate suppression;
7. registration replacement that stops old activities only after the new
   validated intent is durable, and no broad clear on an unrelated end callback;
8. authorization, selection validation, error, and accessibility gates matching
   the existing R4 evidence requirements; and
9. focused device tests for weekday/weekend boundaries, overnight cross-day
   rejection, DST, timezone changes, reboot/relaunch, and the unchanged single
   daily migration path.

Until every gate passes, the existing production runtime remains the only runtime
path and this file remains a source-only design contract.
