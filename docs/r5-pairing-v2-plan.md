# R5 pairing v2: relay-delivered acceptance and one-tap confirm

Status: **P2a (relay and protocol) built and Opus-reviewed 2026-10-02 (approved, no P0/P1; P2-1..P2-5 follow-up fixes applied); P2b (app) not started.** It follows the pairing-links slice: the `phone-lockbox-companion` URL scheme, invite-link routing, Copy link and the `PhoneLockboxUITests` target. See [P2a build results](#build-results-p2a-2026-10-02).

## Owner decision (2026-10-02)

The owner no longer types the six-digit code read aloud by the friend. Instead:
1. The friend accepts the invite.
2. The relay delivers the signed acceptance to the owner's phone.
3. The owner sees "Someone accepted your invite", names them and taps **Confirm**, or taps **Not them**.

The owner chose this over a matching-word check and over fully automatic pairing.

**Why this is acceptable now:**
- An approver can only approve exact-session early-end requests the owner starts.
- Invites are single-use and expire.
- The typed code never protected against the relay, which stores the invite and its nonce.
- It also never protected against the owner pairing their own second device.

**Re-check before R6.** R6 notices and summaries share status with trusted people, so sending them to the wrong person is a privacy harm. R6 must add an explicit, informed confirmation before any status sharing is enabled. Consider adding a matching word at that point.

**Accepted risk (recorded):** a malicious relay operator could inject an acceptance from a key it controls. The owner might confirm it, thinking it is their friend, and the relay could then approve the owner's early ends. The relay is owner-operated in this prototype. The mitigation is the "Not them" choice, plus revoke at any time.

## Slice P2a: relay and protocol · Sonnet writer

**Owns:** `relay/**`, `CompanionKit/**` and `CompanionRelayService/**` (where an inbox exists), plus the vectors.

1. **Inbox field.** `InboxResponse` gains `pendingAcceptances: [PairingAcceptance]?`. It is additive and present only on an owner fetch of their own ledger. It lists the `ledger.pendingAcceptances` entries whose invite exists, is unconsumed and has not expired. Each entry includes the approver's signature material, so the owner can verify it. If the stored acceptance lacks the signature, return the signed form; add a minimal `SignedAcceptance` model if needed.
2. **Implementation parity.** Implement identically in the TS relay and `InMemoryCompanionRelay`, with vectors from `CompanionVectorGen`.
3. **Retention.** Pending acceptances are purged with their expired invite. The inbox must not show an acceptance for a consumed invite.
4. **`OwnerAcceptanceCheck.verify(signedAcceptance:invite:ownerIdentity:)`** is pure, in CompanionKit. It checks:
   - the approver signature;
   - `acceptance.owner == ownerIdentity`;
   - `inviteID` matches an invite **this device created** (passed in by the caller);
   - the invite has not expired;
   - `verificationCode == PairingAcceptance.code(invite:approver:)`.

   It returns the expected code, so the app can call `confirm(acceptance, verificationCode:)` without the owner typing anything.
5. **Tests:**
   - owner-only exposure;
   - cross-owner isolation;
   - nothing returned after confirm or expiry, or after retention;
   - every `OwnerAcceptanceCheck` rejection;
   - parity vectors.

## Slice P2b: app · Sonnet writer (after P2a merges)

**Owns:** `PhoneLockbox/Companion/CompanionCoordinator.swift`, `PhoneLockbox/Views/PeopleView.swift`, `PhoneLockboxTests/**` and `PhoneLockboxUITests/**`.

1. **Owner device stores the invites it creates.** It keeps the `Invitation` (and payload with nonce) in the App Group, keyed by `inviteID`. Entries are pruned when the invite is consumed or has expired.
2. **Showing pending acceptances.**
   - After any owner inbox fetch, verify each `pendingAcceptance` with `OwnerAcceptanceCheck` against the stored invite.
   - Drop anything that fails verification or has no matching local invite. Never show a relay-supplied acceptance for an invite this device didn't create.
   - Show each verified acceptance as a card: "Someone accepted your invite (sent ‹time›)". It has a name field, **Confirm** (primary) and **Not them**.
3. **Confirm** calls `confirm(acceptance, verificationCode: expected)` with the locally derived code, then shows the person as paired.
4. **Not them** hides that acceptance locally and discards the stored invite, so nothing further can be confirmed from it. If a relay cancel exists, use it. Otherwise local discard plus invite expiry is enough; document which.
5. **Friend side.**
   - After Accept, show "Waiting for ‹owner› to confirm". The owner's name isn't known, so use "the person who invited you".
   - Remove the "share acceptance code back" step and the typed-code UI.
   - Keep parsing legacy acceptance links only if trivial; otherwise remove them.
6. **Remove** the six-digit code field and its keyboard handling.
7. **UX fixes from the parent's simulator screenshot check (2026-10-02):**
   - **Incoming invite.** Opening an invite link must put the invite in front of the friend: a sheet or a top-of-page card saying "You've been invited to be a trusted person", with **Accept** and **Not now**. Don't leave it prefilled in a field below the fold.
   - **Invite link display.** Show the created invite as one truncated line (for example "Invite link ready"), not the raw base64 blob. Keep the full link in the accessibility value under identifier `inviteSomeone.inviteLinkText`, so the UI test can still read it.
   - **Copy.** Remove the outdated text "that approval isn't connected to your lock yet in this build", and every six-digit-code instruction. Replace them with short, accurate copy for one-tap confirm.
   - **Expired invites.** Validate an incoming invite link against the current time in `handleIncomingCompanionLink`, so an expired invite shows "This invite has expired; ask for a new one" instead of being prefilled. Also fix the doc comment there. A valid link must not clear unrelated companion errors.
   - **Layout.** Make sure the bottom tab bar doesn't cover actionable content: add bottom padding or a safe-area inset to the People scroll content.
8. **UI test** (`PhoneLockboxUITests`, simulator, local relay):
   1. The app (owner) creates an invite and copies the link.
   2. A scripted friend accepts over HTTP.
   3. The app pulls to refresh, sees the pending card, enters a name and taps **Confirm**. The person shows as paired. Attach screenshots.
   4. A second case: **Not them** removes the card, and the acceptance cannot be confirmed afterwards.

## Review gates

- **P2a:** Opus, medium. Checks owner-only exposure, parity and that verification is complete.
- **P2b:** Opus, medium. Checks:
  - local invite binding (no relay-only acceptances shown);
  - correct code derivation;
  - "Not them" semantics;
  - accessibility and copy;
  - UI-test evidence.
- **Parent:** all suites, simulator UI tests with screenshots, and a production smoke run (extend `tools/relay-smoke` to confirm via inbox-delivered acceptance). Then a phone build.

## Docs

Update `docs/companion-security.md`, the R5 relay plan contract table and the roadmap to record the removal of the typed code and the accepted risk above.

## Build results: P2a (2026-10-02)

**Delegation actually used:** built directly in a Claude Sonnet worktree (no separate P2a builder/reviewer split was available this session). Independently reviewed by a Claude Opus subagent that wrote none of this code: **approved, no P0/P1.** P2-1 through P2-5 below are that review's P2 (non-blocking) findings, addressed in a follow-up commit by the same Sonnet builder.

**Stored-signature finding.** Before this change, both the TS relay (`relay/src/reducer.ts`'s `"accept"` case) and the Swift reference relay (`InMemoryCompanionRelay.apply`'s `"accept"` case) stored only the bare, unsigned `PairingAcceptance` payload in `pendingAcceptances` — the approver's signature over it was verified once at submission time and then discarded, never retained. An inbox that returned this stored value as-is would hand the owner device something it cannot verify. Fixed by retaining the signature going forward:
- TS: `Ledger.pendingAcceptances` is now `Record<string, LedgerPendingAcceptance>` (`{ acceptance, signature? }`, `relay/src/ledger.ts`), written as `{ acceptance: signed.acceptance, signature: signed.signature }` by `"accept"`. `normalizePendingAcceptance(raw)` reads either the current wrapped shape or a legacy flat row (pre-existing production ledgers may still hold the old shape) and reports `signature: undefined` for the latter.
- Swift: `InMemoryCompanionRelay.pendingAcceptances` is now `[String: SignedAcceptance]`; `RelaySnapshot.pendingAcceptances` is `[SignedAcceptance]` (schema bumped 3 → 4 — this snapshot format is a reference/test-only developer-harness artifact per `docs/companion-security.md`, never a field build's persisted data, so the bump carries no production migration risk).
- The inbox never fabricates a signature: an entry with no retained signature (only reachable from a pre-existing/legacy row) is silently skipped rather than delivered unverifiable. `confirm` itself was unaffected either way — it only ever checked the owner's own confirmation signature, never the stored acceptance's.

**API added:**
- TS: `InboxResponse.pendingAcceptances?: SignedAcceptance[]` (contract v1.3, additive; owner-fetch only, mirrors `approvals`'s v1.2 presence rule). `encodeSignedAcceptance`, `normalizePendingAcceptance` (`relay/src/ledger.ts`).
- Swift: `InboxResponse.pendingAcceptances: [SignedAcceptance]?` (`DurableSemantics.swift`); `SignedAcceptance.validateSignature()` (`ProtocolModels.swift`); `OwnerAcceptanceCheck.verify(signedAcceptance:invite:ownerIdentity:now:) throws -> String` (new `OwnerAcceptanceCheck.swift`), returning the expected six-digit code so the caller can call `confirm(acceptance, verificationCode:)`/`AsyncCompanionClient.confirm` without the owner reading or typing anything.
- `CompanionVectorGen` adds `inboxResponseWithPendingAcceptanceSample`; `relay/test/vectors.test.ts` verifies parity and that a helper sample omits the key entirely.

**Files changed:** `relay/src/ledger.ts`, `relay/src/reducer.ts`, `relay/src/retention.ts`, `relay/src/service.ts`, `relay/src/protocol.ts`, `relay/test/pairing-v2-inbox.test.ts` (new), `relay/test/vectors.test.ts`, `relay/test/fixtures/vectors.json` (regenerated), `CompanionKit/Sources/CompanionKit/ProtocolModels.swift`, `CompanionKit/Sources/CompanionKit/DurableSemantics.swift`, `CompanionKit/Sources/CompanionKit/InMemoryRelay.swift`, `CompanionKit/Sources/CompanionKit/OwnerAcceptanceCheck.swift` (new), `CompanionKit/Tests/CompanionKitTests/OwnerAcceptanceCheckTests.swift` (new), `CompanionKit/Sources/CompanionVectorGen/main.swift`, `tools/relay-smoke/Sources/relay-smoke/main.swift`. `CompanionRelayService/**` was left unchanged: it has no inbox (per the plan's "(where an inbox exists)" scoping), so the same latent stored-signature gap there is out of scope for this slice.

**Validation (exact results):**
- `swift test --package-path CompanionKit`: 148 passed (was 140; +8 new `OwnerAcceptanceCheckTests`).
- `swift test --package-path CompanionRelayService`: 18 passed (unchanged; not touched).
- Root `swift test`: 177 passed (unchanged).
- `cd relay && npm run typecheck`: passed. `npm test` against Docker Postgres 16 (port 56330, `npm run db:migrate` applied): 149 passed (was 139; +7 new `test/pairing-v2-inbox.test.ts` + 3 new vector assertions).
- `relay-smoke`: **deviation** — port 8002 was already bound by a different worktree's `npm run dev` (not this one); left that process untouched and instead ran a throwaway instance on `RELAY_PORT=18002` against the same Docker Postgres, then stopped it. All 28 steps passed, including the new inbox-delivered-acceptance/`OwnerAcceptanceCheck`/locally-derived-code flow replacing the old out-of-band confirm.

**Known gaps / deviations:**
- `relay-smoke` ran against the local relay on an alternate port (18002), not 8002, for the reason above; it was not run against production, per instructions.
- P2b (app wiring, People UI, typed-code removal) has not started; `PhoneLockbox/**` is unchanged. The roadmap/companion-security.md updates for "removal of the typed code and the accepted risk" are deferred to when P2b lands, since the typed-code UI itself still exists until then.

**Forward-only ledger-shape change (P2-1).** Storing `{acceptance, signature}` instead of the bare `PairingAcceptance` in `ledger.pendingAcceptances` is additive for *reading* (a legacy row still decodes and confirms fine — see "Stored-signature finding" above) but is **not safe to roll back**: if the TS relay is ever reverted to the pre-P2a build while new wrapped rows already exist in production Postgres, the old reducer's `"confirm"` case reads `ledger.pendingAcceptances[acceptanceID]` expecting a bare `PairingAcceptance` and would instead get the `{acceptance, signature}` wrapper, so every field access (`.inviteID`, `.approver`, `.verificationCode`, …) resolves to `undefined` and confirm breaks for any invite accepted under the new code. This does **not** corrupt or desynchronize anything: `computeStateRoot` is a pure function of whatever is actually stored, so a reverted relay's own integrity check (`storedStateRoot` vs. a fresh recompute) still verifies correctly either way — only the application-level field access breaks, not the cryptographic anchor. Operationally this means: **do not roll back the relay deployment once P2a has served live traffic** without also rolling back any client that could still try to confirm against a wrapped row; roll forward instead.
- **Legacy acceptances cannot be delivered.** Any acceptance already `accept`-ed before this deploy (stored as the old bare, unsigned shape) will never appear in `pendingAcceptances` on the inbox — it has no retained signature, so it is correctly skipped rather than delivered unverifiable (see "Stored-signature finding"). Once P2b removes the typed six-digit-code UI, there is no other way left to confirm such a pre-existing acceptance: **the owner and friend need a fresh invite/accept** for anything that was pending across this deploy. In this prototype's current state (R5 pairing v2 not yet shipped to the field), this is expected to affect at most the owner's own in-progress testing, not real users.

## Follow-up fixes: P2-1 .. P2-5 (2026-10-02)

Non-blocking (P2) findings from the Opus review above, fixed in a separate commit by the same Sonnet builder; no re-review has happened on these specific fixes.

- **P2-1 (docs):** the "forward-only ledger-shape change" and "legacy acceptances cannot be delivered" notes above were added to this file.
- **P2-2 (Swift tests):** new `CompanionKit/Tests/CompanionKitTests/PendingAcceptanceInboxTests.swift`, mirroring `relay/test/pairing-v2-inbox.test.ts` against `InMemoryCompanionRelay` directly: a helper fetch returns `nil` for `pendingAcceptances`; the list is cleared from the owner's inbox after `confirm`; the list is empty once the invite expires (via `relay.advance(to:)`); and a schema-4 `RelaySnapshot` round trip (`snapshot()` + `checkpoint()` + the anchored `init(snapshot:checkpoint:)` restore) still delivers and verifies the signed pending acceptance.
- **P2-3 (TS regression test):** `relay/test/pairing-v2-inbox.test.ts` gained a test that writes a legacy flat `pendingAcceptances` row with its state root computed exactly once (via the existing `patchLedger` test helper), then runs an owner inbox fetch and a second, unrelated mutation (an "ack") — neither ever recomputes/rewrites that row — and asserts both resolve cleanly with no `integrity_error`.
- **P2-4 (`OwnerAcceptanceCheck` issuedAt bounds):** `verify` now additionally requires `acceptance.issuedAt >= invite.payload.issuedAt - 60`, `< invite.payload.expiresAt`, and `<= now + 60` (all three, `CompanionError.expired` on failure) — previously the acceptance's own timestamp was never checked at all, only the invite's expiry against `now`. Three new tests in `OwnerAcceptanceCheckTests.swift` cover: issued too far in the future relative to the device's clock, issued too long before the invite itself, and issued at-or-after the invite's own expiry.
- **P2-5 (TS/Swift parity):** the TS inbox filter (`relay/src/service.ts`) now also requires `signature.length === 64`, matching the Swift relay's existing `fetchInbox` filter (`signed.signature.count == 64`) — a truncated/corrupt signature is no more deliverable than a missing one.

**Validation after the follow-up (exact results):**
- `swift test --package-path CompanionKit`: **155 passed** (was 148; +4 `PendingAcceptanceInboxTests` + 3 new `OwnerAcceptanceCheckTests` issuedAt-bound cases).
- `cd relay && npm run typecheck`: passed. `npm test` against Docker Postgres 16 on 56330: **150 passed** (was 149; +1 new P2-3 regression test).
- Neither `CompanionRelayService` nor root `swift test` were re-run for this follow-up (nothing in `CompanionRelayService/**` or outside `CompanionKit`/`relay` changed); both were already green in the prior validation above.
- `relay-smoke` was not re-run for this follow-up (no protocol/wire change, no relay dev server was started — port 8002 was left bound to the other worktree's process throughout).

## Integration: P2a (2026-10-02, parent)

**Delegation:**
- Built by a Claude **Sonnet** subagent in a worktree.
- Reviewed by an independent Claude **Opus** subagent (medium): approve, with no P0/P1.
- All five P2 follow-ups were fixed in `ff77e98`. The parent verified them by tests only; they were not re-reviewed.

**Parent validation on merged `r5-relay`:**
- CompanionKit: 155 passed.
- CompanionRelayService: 18 passed.
- Root `swift test`: 177 passed.
- Relay typecheck passed, and `npm test` passed 150.

**Production:**
- Relay redeployed to production.
- `tools/relay-smoke` passed all 28 steps, including inbox-delivered acceptance, then `OwnerAcceptanceCheck`, then confirm with the derived code.
- A first `vercel deploy --prod` attempt produced no new deployment. The smoke run against the old relay failed at acceptance delivery, as expected. The second deploy succeeded.

**Compatibility:** builds 16–20 still use the typed-code confirm, which is unchanged, so they keep working. The ledger-shape change is forward-only (see above).
