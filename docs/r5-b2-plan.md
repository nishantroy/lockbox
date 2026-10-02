# R5 Slice B2 — friend approval releases the exact session

Status: **planned 2026-10-02; not started.** Builds on Slices A and B1 on `r5-relay` (see [R5 relay plan](r5-relay-plan.md)). Nothing here is deployed or device-tested.

## Goal

When a trusted friend approves an early-end request, the owner can end **that exact lock session** from the app. The flow:

1. The owner device obtains the friend's signed `Approval` from its own anchored inbox and verifies it locally.
2. It calls the relay's `use` on that approval.
3. It persists an exact-session terminal event before clearing policy.
4. It releases only that session through the existing release ordering.

Natural end always wins. A stale, late, mismatched or already-used approval is a no-op, never an error that leaves the device in a worse state. Recovery and emergency access never depend on the relay.

## Owner-facing decisions (defaults chosen by the parent; owner may override)

- **Explicit tap.** The owner taps **End lock now** on an approved request and confirms. An approval arriving does not unlock automatically. The only automatic step is finishing a use the owner already started, if the app was interrupted.
- **Developer gate.** Add a persisted developer toggle, **Friend approval can end locks (prototype)**, in the Settings developer section. It defaults to **off**. When off, the People tab behaves exactly as today ("Approved", no action). This holds R5 out of ordinary UI until the R4/R5 gates pass (roadmap R4 "Blocks" and the R5 acceptance gate).
- **Scope of a release.** Exactly one session ID is released. An overlapping session that started later stays enforced. A recovery commitment targeting other sessions is preserved, and is normalized only for the released target.

## Why the protocol must change first

Today the relay's owner inbox returns requests (with decisions), pairings and consents, but never the signed `Approval`. Only the helper sees the approval, in its own submit response. The relay's `use` requires the submitted approval to equal the stored one, and `AsyncCompanionClient` has no `useApproval`. So B2a adds both.

## Slices and ownership

B2a and B2b are independent and run in parallel. B2c runs after both are merged into `r5-relay`.

### B2a — protocol: owner approval delivery and async `use` · Sonnet writer

**Owns:**
- `relay/**`
- `CompanionKit/**`
- `CompanionRelayService/**`
- `CompanionKit/Sources/CompanionVectorGen/**`
- `relay/test/fixtures/**`

**1. Inbox approvals (contract v1.2, additive).**
- `InboxResponse` gains `approvals: [Approval]?`.
- It is populated **only on an owner fetch of their own ledger**: the relay-stored accepted approval for each request in that response whose status is `approved`, or that has a recorded use.
- It is omitted (`nil`) on helper fetches, and decoding must tolerate its absence.
- Implement it identically in the TS relay (`relay/src/service.ts` inbox assembly and `protocol.ts` types), `InMemoryCompanionRelay` and the `CompanionRelayService` reference.
- The state root is unchanged, because approvals are already part of ledger state and this is only a projection. Confirm and test this.
- Retention already purges approvals with their terminal request; the inbox must not resurrect purged records.

**2. Async `useApproval`.**
- Add `AsyncCompanionClient.useApproval(_ approval: Approval, request: TrustedRequest, useID: String) async throws -> ApprovalVerification`.
- It submits kind `"use"` exactly as the sync client does.
- It **verifies the response**:
  - kind is `.verification`;
  - `verification.approval == approval`;
  - `verification.useID == useID`;
  - the approval signature is valid;
  - the approval binds `request.requestID`, `request.sessionID`, `request.activeSetID`, `request.pairingID`/`pairEpoch`/`consentGeneration`;
  - `decision == .approved`.
- It throws a typed error otherwise. Also harden the sync `CompanionClient.useApproval` with the same check.
- Same `useID` and approval must produce the same operation ID, so a retry gets the stored idempotent response. Add a test for this.

**3. Owner-side approval check (pure, in CompanionKit).**
- Add `OwnerApprovalCheck.verify(approval:request:trustedApprover:) throws`.
- `trustedApprover` carries the approver identity ID, signing public key, pairing ID, pair epoch and consent generation from the owner's own trusted pairing/consent cache.
- It rejects:
  - an unknown or revoked approver;
  - a key mismatch;
  - an epoch or generation mismatch;
  - a request that isn't owned by this owner;
  - an approval for a different request, session or active set;
  - an approval that isn't `.approved`.
- The app calls this before `use`.

**4. Vectors and parity.** Regenerate `relay/test/fixtures/vectors.json` via `CompanionVectorGen`, adding an owner inbox with `approvals` and a `use` round trip. TS and Swift must agree byte for byte on canonical encodings.

**5. Tests.**
- Owner inbox includes the approval; a helper inbox omits it.
- Cross-owner isolation: owner A never sees owner B's approvals.
- `use` after natural end fails. `use` with a stale session or active set fails. `use` twice with the same `useID` is idempotent; a different `useID` on a consumed approval fails.
- The async client rejects a tampered verification response (wrong approval, wrong `useID`, bad signature).
- Each `OwnerApprovalCheck` rejection case.
- HTTP `URLProtocol` stub tests for the new paths.

**Out of scope for B2a:** `replace_pairing` learning, owner-signed `PairingConfirmation`, `natural_end` client, APNs.

### B2b — runtime: durable friend-release record and exact-session release · Sonnet writer

**Owns:**
- `Shared/RuntimeContracts.swift`
- `Shared/RuntimeLifecycle.swift`
- `Shared/RuntimeEngine.swift`
- new `Shared/RuntimeFriendRelease.swift`
- `RuntimeTests/**`

No app, extension or CompanionKit code. Shared stays free of CompanionKit types, so it uses plain strings and UUIDs.

**1. Active-set ID in Shared.** Move the derivation `SHA256("PhoneLockbox.active-set.v1|" + sorted session ID uuidStrings joined as today)` into a pure `RuntimeActiveSet.id(for sessionIDs:)` in Shared. It must be byte-identical to `ScreenTimeCoordinator.companionActiveSetID(for:)`; copy the exact joining rule and add a fixed-vector test. B2c switches the coordinator to call it.

**2. Durable pending friend release.**
- Add `RuntimeFriendReleaseIntent` with fields `sessionID: UUID`, `activeSetID: String`, `requestID`, `approvalID`, `useID`, `approverIdentityID` (strings) and `createdAt`.
- Add it to `RuntimeStoreDocument` as `pendingFriendRelease: RuntimeFriendReleaseIntent?` (at most one).
- **Additive and optional:** existing schema-2 documents must decode unchanged (`decodeIfPresent`), with no schema bump unless the existing decoder makes one unavoidable. If a bump is unavoidable, keep schema 2 readable and add a migration test.
- `validate()`: a pending intent must reference an existing session. Normalization drops it once that session is no longer `.active` or `.recoveryPending`.

**3. Release cause.**
- `RuntimeReleasedOccurrence` gains optional `cause: RuntimeReleaseCause?` (`recovery | developer | friendApproval`) and optional `friendUseID: String?`.
- Both are decoded with `decodeIfPresent`. Old markers decode as `nil`, which means unknown or legacy.
- The marker is the durable exact-session terminal event R6 can later read. Make sure `pruneTerminalSessions` and the 64-marker cap keep the most recent markers.
- Add `RuntimeOperation` cases `friendReleaseIntentRecorded`, `friendReleaseApplied`, `friendReleaseNoOp` (diagnostics only).

**4. Pure lifecycle functions in `RuntimeLifecycle`.** Each takes `now` explicitly.
- `prepareFriendRelease(_ doc:, intent:, effectiveSessionIDs:, now:) -> PrepareOutcome`:
  1. Runs `expireNaturalSessions`.
  2. Requires the session to exist, be in `.active`/`.recoveryPending` and be effective at `now`.
  3. Requires `RuntimeActiveSet.id(for: effectiveSessionIDs) == intent.activeSetID`.
  4. Requires no different pending intent to exist.
  5. On success, stores the intent and returns `.recorded`. Otherwise it returns `.noOp(reason)` with **no** state change beyond natural expiry.
  6. Re-preparing the identical intent is idempotent and returns `.recorded`.
- `applyFriendRelease(_ doc:, useID:, now:) -> ApplyOutcome`:
  1. Requires a pending intent with a matching `useID`.
  2. Runs `expireNaturalSessions`.
  3. If the target is no longer active or effective (natural end won, or it was released another way), clears the intent and returns `.noOp(.alreadyEnded)`.
  4. Otherwise calls `release(_:sessionIDs: [intent.sessionID], …)` with cause `.friendApproval` and `friendUseID`, clears the intent, and returns `.released(remainingEffective:)`.
  5. Must convert the existing "already ended" throw into `.noOp`.
- `abandonFriendRelease(_ doc:, useID:)` clears a matching pending intent; used after a definitive relay rejection.
- The policy intent (`.clear` if nothing remains, else `.apply`) and the route-stop decision stay with the caller, as in `confirmRecovery`. Expose a pure helper returning what the caller must do, so B2c does not re-derive it.

**5. Tests** (new `RuntimeTests/FriendReleaseTests.swift`, plus contract tests).
- Releases only the target. A later overlapping scheduled or manual session stays enforced and the policy intent is `.apply`.
- Natural end before apply produces a no-op and clears the intent. Natural end exactly at `end` is also a no-op.
- An active-set mismatch at prepare is a no-op.
- A crash between prepare and apply (persisted intent survives round trip) leads to a replayed apply that is idempotent.
- A second, different intent is rejected while one is pending.
- A pending intent for an expired session is normalized away.
- A recovery commitment targeting the same session is normalized. One targeting another session is preserved.
- Released scheduled occurrences still fence and suppress late callbacks.
- Schema-2 document fixtures without the new fields decode.
- Active-set ID fixed vector.

### B2c — app wiring, People UI and developer gate · Sonnet writer (after B2a + B2b merge)

**Owns:**
- `PhoneLockbox/ScreenTimeCoordinator.swift` (new release method; switch to `RuntimeActiveSet`)
- `PhoneLockbox/Companion/CompanionCoordinator.swift`
- `PhoneLockbox/Views/PeopleView.swift`
- `PhoneLockbox/Views/SettingsView.swift` (developer toggle only)
- `PhoneLockboxTests/**` for any host-testable pieces

**Flow (owner taps End lock now on an approved request):**
1. `CompanionCoordinator` finds the request and its `approvals` entry in the latest **owner-anchored** inbox. It checks the approval with `OwnerApprovalCheck` against its people/consent cache.
2. It generates `useID` and builds the intent.
3. `ScreenTimeCoordinator.prepareFriendRelease(intent)` runs under `store.withTransaction` with the injected clock and commits. A no-op result is shown as "This lock already ended", or as "This approval is for a different lock".
4. `client.useApproval(approval, request:, useID:)` is called.
   - **Definitive relay rejection** (`replay`, `expired`, `wrong_target`, `unauthorized`, …): call `abandonFriendRelease` and show a calm message.
   - **Transient failure** (network, 5xx, 429): keep the pending intent and say "Couldn't reach the relay; try again." Do not release.
5. On a verified response, `ScreenTimeCoordinator.applyFriendRelease(useID:)` runs inside one transaction, mirroring the `confirmRecovery` ordering:
   1. Apply → `.released`, or `.noOp`.
   2. Set `policyIntent` and record `.policyClearAttempted`.
   3. `commit()`.
   4. `applyEffectivePolicy`.
   5. Clear the intent, record `.policyCleared` and `.friendReleaseApplied`, `commit()`.
   6. `stopManualRouteIfOwned` only for the released session's route generation.
   7. Activate and re-register a pending configuration exactly as `confirmRecovery` does.
6. **Replay on foreground:** if a `pendingFriendRelease` exists, retry `use` with the same `useID`, which is idempotent, then continue at step 5. If its session is no longer active, normalization has already dropped it.

**Rules:**
- Use the coordinator's injected clock (`currentDate()`) on the whole new path, not `Date()`.
- CompanionKit stays app-only. The monitor extension needs no changes: it already treats `.released` sessions as non-enforcing.
- **People tab:**
  - With the gate **on**, an owner's approved, unused request shows **End lock now**, with a confirmation naming the friend and the lock's end time.
  - A used request shows "Used to end lock". After natural end, a request shows "Lock already ended". A pending intent shows "Finishing…".
  - With the gate off, nothing changes from today. Use full-row tappable controls and VoiceOver labels.
- Update the `AskToEndEarlyCard` copy ("never ends your lock by itself") so it is accurate under each gate state.

**Tests:**
- Whatever is host-testable without FamilyControls: inbox selection, the error classification of definitive vs transient, gate-off hiding.
- The rest is covered by B2a and B2b tests plus the parent's simulator smoke run.

## Review gates

- **B2a:** Opus reviewer, medium. Checks parity across TS, in-memory and durable implementations; cross-owner isolation; response verification completeness; idempotency; vector regeneration.
- **B2b:** Opus reviewer, **high** (R2/R3 safety core). Checks ordering, natural-end races, exact-session scope, overlap and recovery-commitment interactions, backward-compatible decoding, pruning.
- **B2c:** Opus reviewer, **high**. Checks the end-to-end ordering across the network call, the transient vs definitive classification, gate enforcement, no release without a verified `use`, the clock, the route stop, and UI copy.

## Parent integration and validation

- `swift test` (root), `swift test --package-path CompanionKit`, `swift test --package-path CompanionRelayService`.
- `cd relay && npm run typecheck && npm test` against Docker Postgres on 56330.
- `xcodegen generate` (no diff expected) and the iOS simulator build.
- A local HTTP smoke run on 8002, extending the B1 script: owner fetches the approval in the anchored inbox, then `use` succeeds, then an idempotent retry returns the same record, then a second use is rejected, then `use` after the session's natural end is rejected.
- Record the actual models used and results in `r5-relay-plan.md`/this file and the roadmap. A device run with two phones remains owner QA and is **not** claimed here.

## Deferred (still open after B2)

- Vercel and Neon deployment, plus `vercel dev` validation.
- `replace_pairing` learning.
- Owner-signed `PairingConfirmation` in the helper inbox.
- "Expired consent, try again" copy.
- `natural_end` client.
- APNs.
- R6 notices and summaries.
