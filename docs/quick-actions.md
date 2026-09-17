# Quick Actions candidate

Phone Lockbox includes a source-only Shortcuts/App Intents candidate for four bounded navigation actions:

- start a 30-minute focus session;
- start a one-hour focus session;
- show the current Lockbox status; and
- open Recovery.

The two focus actions open the existing **Lock now** sheet with the requested preset selected. The user must review and explicitly confirm the finite end; a shortcut never applies Managed Settings directly. Recovery opens the existing delayed recovery flow, and status opens the normal Lockbox surface. Authorization, registration and enforcement remain reported by the app and are never inferred from an accepted intent.

Routes use the `phonelockbox://quick-action/v1/...` scheme configured in `project.yml`. Each generated route carries a unique nonce for queue deduplication, an integer issuance time, and an exact five-minute expiry. The parser accepts only the exact regenerated URL spelling: canonical absolute paths, query names/order, percent encoding, canonical integer/UUID values, the exact query allowlist, and routes within the bounded issuance-age and clock-skew window. Unknown, malformed, duplicate, future-dated, stale, or expired routes fail closed without changing a rule, active session or recovery state. These values are freshness and delivery metadata only, not authentication or provenance.

## Delivery and crash behavior

The App Group handoff is a bounded, versioned file queue under its own cross-process `flock` lock. The queue is capped at **32 entries and 32 KiB** before decoding/allocation; each identifier, claim token and URL also has a small byte limit. Reads verify regular-file metadata under the lock and then use a `FileHandle` read capped at max+1. Unsupported schema/counts/strings and corrupt data fail closed without overwriting the original bytes.

Queue entries are strict FIFO. An unexpired lease on the head intentionally blocks later entries rather than allowing overtaking. A significant wall-clock rollback (more than five minutes relative to a queued timestamp or lease) deterministically drops the navigation-only queue and its leases, freeing capacity; it cannot wedge delivery. This is safe because the queue never contains enforcement authority.

Writes use a same-directory temporary file, complete data write, file `fsync`, atomic rename, and containing-directory `fsync` where the platform supports it. Hard I/O failures fail closed; unsupported directory sync is treated as the platform's safe atomic-rename fallback. The queue, lock file, temporary replacement and App Group directory use `NSFileProtectionCompleteUntilFirstUserAuthentication` on iOS so delivery is available after first unlock without weakening pre-unlock protection. Device validation of Data Protection and power-loss durability remains required.

A claimed entry is not acknowledged when the coordinator publishes in-memory state. The claim's ID and lease token are retained in `PendingQuickAction` and passed to the UI presentation callback:

- focus is acknowledged only from the presented Lock now sheet;
- recovery is acknowledged only from the presented Recovery destination; and
- status is acknowledged by the visible Lockbox destination's explicit consumption callback.

If the host crashes, the scene tears down, or a sheet/navigation presentation fails before that callback, no acknowledgement is written; the lease expires and the route can be retried after relaunch. Acknowledgement matches both ID and token, so a stale callback cannot delete a re-leased entry. Repeated status/recovery presentation is idempotent, and repeated focus routes still require the existing finite confirmation and cannot mutate an active lock.

The implementation uses stable App Group files and `flock`, and the test suite exercises concurrent operations from multiple threads with separate descriptors. The iOS unit-test target cannot safely spawn an independent signed App Group process; genuine independently spawned-process lock contention and provisioned-device reboot/power-loss/file-protection behavior remain explicit device/host gates for R9 rather than being claimed by the thread test.

This is a source candidate only. Siri/Shortcuts availability, voice feedback, duplicate invocation and device behavior still require the R9 acceptance gate. No installation, Siri prompt, schedule change or enforcement result is implied by this implementation. Indefinite locks, background enforcement, instant recovery and active-rule edits are deliberately not exposed.
