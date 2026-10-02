# R5 pairing v2: relay-delivered acceptance and one-tap confirm

Status: **P2a (relay and protocol) built 2026-10-02, awaiting Opus review; P2b (app) not started.** It follows the pairing-links slice: the `phone-lockbox-companion` URL scheme, invite-link routing, Copy link and the `PhoneLockboxUITests` target. See [P2a build results](#build-results-p2a-2026-10-02).

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
7. **UI test** (`PhoneLockboxUITests`, simulator, local relay):
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

**Delegation actually used:** built directly in a Claude Sonnet worktree (no separate P2a builder/reviewer split was available this session); an independent Opus review is still outstanding before this merges, per the review gates above.

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
- No Opus review has happened yet for this slice (see review gates above).
- `relay-smoke` ran against the local relay on an alternate port (18002), not 8002, for the reason above; it was not run against production, per instructions.
- P2b (app wiring, People UI, typed-code removal) has not started; `PhoneLockbox/**` is unchanged. The roadmap/companion-security.md updates for "removal of the typed code and the accepted risk" are deferred to when P2b lands, since the typed-code UI itself still exists until then.
