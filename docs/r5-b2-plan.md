# R5 Slice B2 — friend approval releases the exact session

Status: **B2a, B2b and B2c merged on `r5-relay` (2026-10-02); build 17 installed on the owner's iPhone. Friend release is developer-gated (off by default) and not device-tested.** See [B2c integration](#integration-results-b2c-2026-10-02).

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
- **As merged:** no new `RuntimeOperation` cases. That enum decodes strictly, so a new case would make an older app or monitor fail to decode the whole document after a downgrade. Friend-release diagnostics reuse `.policyClearAttempted`/`.policyCleared`/`.conflictRejected`, with the friend-release detail in `RuntimeDiagnostic.detail`.

**4. Pure lifecycle functions in `RuntimeLifecycle`.** Each takes `now` explicitly.
- `prepareFriendRelease(_ doc:, intent:, at:) -> PrepareOutcome`. **As merged**, it takes no caller-supplied set; it computes the enforcement sessions itself after expiry:
  1. Runs `expireNaturalSessions`.
  2. Requires the session to exist, be in `.active`/`.recoveryPending` and be effective at `now`.
  3. Requires the target to be in the live enforcement set and `RuntimeActiveSet.id(for: thatSet) == intent.activeSetID`. **As merged, apply rechecks this too.** If the set changed after prepare, apply returns `.noOp(.activeSetMismatch)` and clears the intent. The relay `use` may already be consumed by then, so B2c must treat this as terminal.
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
   5. Clear the intent, record `.policyCleared` with friend-release detail text, `commit()`. **Every `.noOp` outcome from apply is terminal**, including `.activeSetMismatch` ("Your locks changed; ask again") and `.alreadyEnded`; never retry it, because the intent is already cleared.
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

## Integration results: B2a + B2b (2026-10-02)

**Delegation actually used:**
- Builders were Claude **Sonnet** subagents in isolated worktrees.
- Reviewers were independent Claude **Opus** subagents that wrote none of the code. No Luna/Terra models were used.
- **B2b** (Opus, high): approve with fixes, then one fix round, then approve.
- **B2a** (Opus, medium): approve with fixes, then three fix rounds, then approve. Each fix round was re-checked:
  1. **Idempotent `use` replay vs. rollback anchor.** The relay now returns the owner's current `(revision, stateRoot)` on an owner-signed replay. A helper replay keeps the commit-time pair (privacy).
  2. **Distinct anchor-violation error.** Added `CompanionError.relayRollback`.
  3. **`AsyncCompanionClient.UseFailureDisposition.classify`.** Pre-network local errors are `definitive`. Only `responseVerificationFailed`, `relayRollback` and `malformedResponse` are `integrityFatal`.
- Both worktrees were created at a stale base (`9d5ed89`); each builder fast-forwarded to `6338a2a` before working. No work was lost.

**API as merged (for B2c):**
- **`prepareFriendRelease`** (B2b) computes the enforcement set itself. Apply rechecks it, and every apply no-op is terminal.
- No new `RuntimeOperation` cases were added, for downgrade safety.
- **`OwnerApprovalCheck.verify(approval:request:trustedApprover:ownerIdentity:)`** with `TrustedApprover.init(pairing:consent:)`.
- **`AsyncCompanionClient.useApproval(_:request:useID:)`.**
- **`UseFailureDisposition`:**
  - `retryable`: transport errors, 5xx, `rate_limited`, relay `stale_revision`. Retry with the same `useID`.
  - `definitive`: call `abandonFriendRelease`.
  - `integrityFatal`: keep the intent and neither retry nor abandon; show an integrity error.
- **`describeCompanionError`** needs a `.relayRollback` case.

**Parent validation on the merged branch:**
- `swift test --package-path CompanionKit`: 140 passed.
- `swift test --package-path CompanionRelayService`: 18 passed. The first run crashed with signal 11 from stale SwiftPM incremental state; it passed after removing `CompanionRelayService/.build`.
- Root `swift test`: 177 passed.
- Relay `npm run typecheck` passed, and `npm test` passed 139 against Docker Postgres 16.
- `xcodegen generate`: the only diff adds `Shared/RuntimeFriendRelease.swift` to the app and monitor targets. The iOS simulator build succeeded.
- Production relay redeployed with B2a. `tools/relay-smoke` against `https://relay.example.com` passed all 17 steps.
- The smoke tool does not yet exercise approval delivery or `use`. That is added with B2c.

## Integration results: B2c (2026-10-02)

**Delegation actually used:**
- Builder: a Claude **Sonnet** subagent in an isolated worktree. The worktree started at a stale base and was fast-forwarded to `6c941ff`.
- Reviewer: an independent Claude **Opus** subagent at high effort. No Luna/Terra models were used.

**Review history:**
- **First review:** approve with fixes; no P0.
  - P1 findings:
    - single-flight across tap, pull-to-refresh and foreground replay;
    - `confirmRecovery`-style recovery on `applyFriendRelease` errors;
    - orchestration tests.
  - Twelve P2s were also fixed.
- **Re-review:** approve.
- **Final P2 round (R2-1 to R2-5)**, checked by the parent from the diff and tests only, without another review:
  - R2-1: the success shortcut requires the exact `useID` marker.
  - R2-2: Discard is disabled while a release is in flight.
  - R2-3: a conflicting-request message.
  - R2-4: a bounded `requestID -> useID` UI map.
  - R2-5: replay selects the pinned `approvalID`.
  - The single-flight test was made deterministic (5/5 iterations passed).

**What shipped:**
- **Developer toggle:** "Friend approval can end locks (prototype)", off by default, persisted in the App Group.
- **With the toggle on:**
  - An owner's approved request shows **End lock now**, behind a confirmation naming the friend and the lock's end time.
  - The flow is: freshly fetched owner-anchored inbox → `selectFriendRelease`/`OwnerApprovalCheck` → `prepareFriendRelease` (durable intent) → `useApproval` → `applyFriendRelease`, in `confirmRecovery` ordering.
- **Failure handling:**
  - `retryable` keeps the intent ("Pull to refresh to finish").
  - `definitive` abandons it, with specific calm copy.
  - `integrityFatal` keeps it and shows an integrity message.
  - Every apply no-op is terminal.
- **Replay:** foreground and People-tab replay only finish an existing intent. "Finishing…" is shown regardless of the toggle.
- **Developer escape hatch:** "Discard pending friend release" clears the intent only and never releases.

**Parent validation on the merged branch:**
- Root `swift test`: 177 passed.
- CompanionKit: 140 passed.
- CompanionRelayService: 18 passed.
- Relay typecheck passed, and `npm test` passed 139.
- `xcodegen generate` produced no diff.
- `PhoneLockboxTests`: 74 passed, 1 pre-existing skip.
- `tools/relay-smoke` against production passed all 25 steps, including:
  - approval delivery;
  - `OwnerApprovalCheck`;
  - `use`;
  - an idempotent retry;
  - a different `useID` rejected as definitive;
  - `use` after the session is superseded rejected.
- The relay code is unchanged by B2c, so no redeploy was needed.

**Build 17:** built for generic iOS and installed on the owner's iPhone. The launch failed because the phone was locked; that is not a build or signing problem. **No device or two-phone QA has been done.**

**Known gaps:**
- **Two-phone device QA:** pair, approve, tap End lock now, and confirm the shield lifts for that exact lock only.
- **Deferred P2-9 (CompanionKit):** `classify` maps wrapped `.malformed` integrity failures from the transport (owner identity mismatch, missing state root) to `definitive` instead of `integrityFatal`. This fails closed: the intent is abandoned and the lock stays on.
- `replace_pairing` learning, the owner-signed `PairingConfirmation`, and APNs remain deferred.
