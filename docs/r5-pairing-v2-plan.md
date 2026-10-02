# R5 pairing v2: relay-delivered acceptance and one-tap confirm

Status: **P2a (relay and protocol) built and Opus-reviewed 2026-10-02 (approved, no P0/P1; P2-1..P2-5 follow-up fixes applied); P2b (app) built 2026-10-02, not yet independently reviewed.** It follows the pairing-links slice: the `phone-lockbox-companion` URL scheme, invite-link routing, Copy link and the `PhoneLockboxUITests` target. See [P2a build results](#build-results-p2a-2026-10-02) and [P2b build results](#build-results-p2b-2026-10-02).

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

## Build results: P2b (2026-10-02)

**Delegation actually used:** built directly in a Claude Sonnet worktree (no separate P2b builder/reviewer split was available this session, same as P2a). Not yet independently reviewed — the plan's gate calls for an Opus review (medium) checking local-invite binding, correct code derivation, "Not them" semantics, accessibility/copy, and UI-test evidence; that review has not happened yet.

**Base:** fast-forwarded to `f447139` (the merged pairing-links slice: `phone-lockbox-companion` scheme, `handleIncomingCompanionLink`, `prefillInviteLink`, Copy link, `inviteSomeone.inviteLinkText`, `PhoneLockboxUITests`, DEBUG reset/relay launch arguments) before starting; the worktree had no unique commits beyond it.

**What shipped (every P2b item):**
1. **Local invite storage.** `CompanionCoordinator.storedInvites: [String: Invitation]` (App Group-persisted, `com.phone-lockbox.companion.storedInvites.v1`), keyed by `inviteID`. `createInvite()` stores the invite it creates; `pruneStoredInvites(now:)` drops expired entries (called at launch and at the start of every `refreshInbox()`); `discardStoredInvite(inviteID:)` removes one on confirm or "Not them".
2. **Showing pending acceptances.** `CompanionCoordinator.verifyPendingAcceptances(_:storedInvites:ownerIdentity:now:)` (static, pure — directly unit-tested) binds every `InboxResponse.pendingAcceptances` entry to `storedInvites` and runs `OwnerAcceptanceCheck.verify`; anything with no matching local invite or that fails verification is silently dropped. `refreshInbox()` calls it on every successful owner-anchored fetch and replaces `@Published pendingOwnerAcceptances` wholesale (a failed fetch leaves the previous value untouched, matching how `inboxItems` behaves elsewhere in the same method). `PeopleView`'s new `PendingAcceptanceCard` shows each one: "Someone accepted your invite", "Sent ‹time›" (the acceptance's own `issuedAt`), a name field, **Confirm** (primary) and **Not them**.
3. **Confirm.** `confirmPendingAcceptance(_:nickname:)` calls `AsyncCompanionClient.confirm(_:verificationCode:now:)` with the code `OwnerAcceptanceCheck` itself derived (never a typed or relay-supplied code), upserts the pairing, discards the consumed invite, and removes the card immediately (not merely on the next refresh).
4. **Not them.** `dismissPendingAcceptance(_:)` removes the card immediately and discards the stored invite. **No relay cancel-invite endpoint exists in this protocol version** — documented in `discardStoredInvite`'s doc comment and in `docs/companion-security.md`'s new "Pairing acceptance boundary" section: local discard is sufficient on its own because `OwnerAcceptanceCheck.verify` requires an invite this device still holds, so once discarded, the identical acceptance can never be confirmed again on this device even if the relay keeps reporting it. The invite also still expires naturally relay-side.
5. **Friend side.** After `acceptInvite`, `AcceptInviteCard` shows "Waiting for the person who invited you to confirm" (the owner's name isn't known to this device) whenever `pendingAcceptance != nil`, replacing the old "Your code" / share-acceptance-code UI entirely. The typed-code UI, `confirmAcceptance(_:typedVerificationCode:nickname:)`, `decodeAcceptance(from:)`, `acceptanceShareText(_:)`, and the `PLBX-ACCEPT:` legacy link format were all removed outright (not kept for legacy parsing) — the only UI surface that produced or consumed that format was removed in the same change, so there was nothing non-trivial left to parse.
6. **Six-digit code field removed**, along with its number-pad/submit/focus handling (`InviteSomeoneCard`'s `typedCode`/`pastedAcceptance` state is gone).
7. **UX fixes from the parent's simulator screenshot check:**
   - **Incoming invite.** `handleIncomingCompanionLink` now sets `@Published var incomingInvite: Invitation?` (replacing `prefillInviteLink`) for a decodable, not-yet-expired link; `PeopleView` shows a new `IncomingInviteCard` — "You've been invited to be a trusted person", **Accept** / **Not now** — as the first conditionally-shown card, directly under the page header, so it is on screen without scrolling (verified in the UI test via `XCUIElement.isHittable`, not merely `exists`).
   - **Invite link display.** `InviteSomeoneCard` now shows "Invite link ready" as the visible label; the full `invitation.shareLink` is carried in the accessibility *value* under the same `inviteSomeone.inviteLinkText` identifier (`.accessibilityValue`, not `.accessibilityLabel`), so `PhoneLockboxUITests` can still read it exactly.
   - **Copy.** `IntroCard` and `InviteSomeoneCard` no longer mention a six-digit code or "that approval isn't connected to your lock yet in this build"; replaced with short copy describing one-tap confirm.
   - **Expired invites.** `handleIncomingCompanionLink` now validates `Date() < invitation.payload.expiresAt` and sets a new, distinct `CompanionCoordinator.expiredInviteLinkMessage` ("This invite has expired; ask for a new one.") instead of queuing the prompt. Its doc comment was rewritten, and — per the fix item — a **valid** link no longer clears `lastError` at all (previously it unconditionally set `lastError = nil` on success); only the two failure branches (invalid / expired) set it.
   - **Layout.** `PeopleView` adds a 24pt `Color.clear` spacer after the error card, inside the same `#if canImport(CompanionKit)` block, so the last actionable card's buttons are never flush against the tab bar. (`LockboxScrollView`/`LockboxDesignSystem.swift` — shared across tabs — was deliberately left unmodified; this was scoped entirely inside `PeopleView.swift`, which is owned by this slice.)
8. **UI tests** (`PhoneLockboxUITests`, simulator `D7081409-96E5-4F3A-9F33-47288449EC3D`, local relay): added `testOwnerConfirmsAPendingAcceptanceAndThePersonShowsAsPaired` and `testOwnerDismissesAPendingAcceptanceAsNotThem` (both: app creates an invite, a scripted in-process friend accepts over HTTP exactly as the pre-existing invite test does, pull-to-refresh, then drive the new card). `testOpeningScriptedInviteLinkRoutesToPeopleWithAcceptCardPrefilled` was renamed to `testOpeningScriptedInviteLinkShowsIncomingInvitePromptThenWaitingState` and rewritten for the new top-of-page prompt (asserting `isHittable`, not just `exists`) and the new waiting state, since the UI it exercised changed. `testCreateInviteCopyLinkAndFriendAcceptsOverRelay`'s link-reading was updated from `.label` to `.value` to match item 7's truncated display. `testPeopleTabStaysSelectedAcrossBackgroundForeground` is unchanged. All five attach `XCTAttachment` screenshots (`.keepAlways`).

**A real bug found and fixed along the way (not in the plan, found via the UI tests):** `.accessibilityIdentifier(...)` applied to the *outer* `LockboxCard` of `IncomingInviteCard`/`PendingAcceptanceCard` was overwriting every descendant's own identifier (observed directly in an exported accessibility-hierarchy dump: the Accept/Not now buttons' hit-tested elements all reported identifier `"incomingInvite.card"` instead of their own `"incomingInvite.acceptButton"`/`"incomingInvite.notNowButton"`). Fixed by removing the card-level identifier from both views — nothing needed it, only the individual controls do.

**New unit tests** (`PhoneLockboxTests/CompanionPairingV2Tests.swift`, 11 tests, no relay needed — builds `Invitation`/`SignedAcceptance` fixtures offline by signing directly with `DeviceSigner`, mirroring what `CompanionClient.createInvite`/`.accept` sign internally): `verifyPendingAcceptances` accepts a matching stored invite and returns the self-derived code; drops an acceptance with no matching local invite, for a different owner identity, with a tampered signature, or for an expired invite; and correctly filters a mixed batch. `handleIncomingCompanionLink` ignores a foreign scheme, rejects an undecodable payload and a decodable-but-expired invite with their respective distinct messages, accepts a valid one, and — the UX-fix-item-7 case — never clears a pre-existing unrelated `lastError`.

**Files changed:** `PhoneLockbox/Companion/CompanionCoordinator.swift`, `PhoneLockbox/Views/PeopleView.swift`, `PhoneLockboxTests/CompanionPairingV2Tests.swift` (new), `PhoneLockboxUITests/CompanionPairingUITests.swift`, `docs/companion-security.md`, `docs/r5-pairing-v2-plan.md`, `docs/r5-relay-plan.md`. No changes outside the owned files — `ContentView.swift`, `ScreenTimeCoordinator.swift`, `Shared/**`, `CompanionKit/**`, and `relay/**` were not touched, and no one-line hook was needed anywhere in them.

**Validation (exact results):**
- `xcodegen generate`: no diff in `PhoneLockbox.xcodeproj` (folder-based sources; the new test file was picked up automatically once regenerated).
- `xcodebuild -scheme PhoneLockbox test` (simulator `D7081409-96E5-4F3A-9F33-47288449EC3D`): **88 passed** (was 77; +11 new `CompanionPairingV2Tests`), 1 skipped (pre-existing, `NSFileProtection` on the simulator), 0 failures.
- `xcodebuild -scheme PhoneLockboxUITests test` (same simulator, local relay on 8002, Docker Postgres on 56330): **5/5 passed** in a clean full run (screenshots below are from that run). Across several validation runs during this session, one run separately hit a transient `CompanionTransportError.unavailable` ("Couldn't reach the relay. Check your connection and try again.") against the local `npm run dev` relay — confirmed via an exported accessibility-hierarchy dump showing that exact error banner, not a hang or a UI-gesture failure — under repeated back-to-back full-suite relaunches. This reads as local relay/simulator-networking flakiness under this session's unusually heavy sequential load (many consecutive `xcodebuild test` invocations debugging the identifier bug above), not a defect in the P2b code; it is called out here rather than hidden. `pullToRefresh()` was also hardened from a single `swipeDown()` (empirically unreliable at crossing SwiftUI `.refreshable`'s activation threshold) to a held press-drag gesture with a bounded repeat-on-miss helper.
- `swift test --package-path CompanionKit`: 155 passed (unchanged — not touched).
- Root `swift test`: 177 passed (unchanged).
- `relay-smoke` and a production relay deploy were not run for this slice (no relay/protocol change in P2b); left to the parent's integration validation per the plan's review-gate split.

**Screenshots** (`/private/tmp/claude-501/-Users-nishantroy-code-phone-lockbox/479f2e3e-0207-4463-b139-0ffa021544c0/scratchpad/ui-shots-p2b/`, from the clean 5/5 run): `01-invite-created-copy-link-visible.png`, `02-incoming-invite-prompt-visible-without-scrolling.png`, `03-friend-side-waiting-for-confirmation.png`, `03-people-tab-stays-selected-after-foreground.png`, `04-pending-acceptance-card-visible.png`, `05-person-confirmed-as-paired.png`, `06-pending-acceptance-before-not-them.png`, `07-pending-acceptance-dismissed.png`.

**Known gaps / deviations:**
- No independent review yet (see "Delegation actually used" above) — the plan's P2b review gate (Opus, medium) is still outstanding.
- `relay-smoke`/production smoke were not re-run (no protocol change); the plan assigns that to the parent's integration pass together with a phone build.
- The intermittent local-relay-reachability flake noted above was observed once during this session's validation; it was not root-caused further (it did not recur in the final clean run used for the attached evidence), and is worth the parent/a future session keeping an eye on if `PhoneLockboxUITests` becomes flaky in CI-like repeated runs. (See the follow-up below: it recurred during re-validation and was root-caused to the long-lived `xcodebuild test` simulator session itself, not the relay or the app's own networking.)

## Follow-up fixes: parent's screenshot review (2026-10-02)

Two fixes requested after the parent reviewed the P2b screenshots, in one follow-up commit (no separate review round for these specific fixes yet — same as P2a's own P2-1..P2-5 follow-up).

1. **Placement.** `PendingAcceptanceCard` was being rendered *after* `InviteSomeoneCard`, so `04-pending-acceptance-card-visible.png` only actually showed the invite card, with the pending-acceptance card below the fold — contradicting the UX-fix-item-7 intent it otherwise satisfied. Moved the `ForEach(companion.pendingOwnerAcceptances)` up to sit directly under `PrototypeLabelCard`, at the same priority as `IncomingInviteCard` (`PhoneLockbox/Views/PeopleView.swift`). Both UI tests that reach this card (`testOwnerConfirmsAPendingAcceptanceAndThePersonShowsAsPaired`, `testOwnerDismissesAPendingAcceptanceAsNotThem`) now assert `confirmButton.isHittable`/`notThemButton.isHittable`, not merely `exists` — the same bar `testOpeningScriptedInviteLinkShowsIncomingInvitePromptThenWaitingState` already held the incoming-invite prompt to.
2. **Consent at confirm.** Confirming previously left the person "Not enabled" — the owner still had to separately flip both person-row toggles afterward. `PendingAcceptanceCard` now has a "Let them approve ending my locks early" `Toggle`, **on by default**
   (`pendingAcceptance.grantEarlyEndToggle`). `CompanionCoordinator.confirmPendingAcceptance` gained a required `grantEarlyEndTrust: Bool` parameter; when true, a new private `grantOwnerTrustAfterConfirm(pairingID:)` grants both `approveEarlyEnd` and `receiveRequests` on the owner side in one round trip, immediately after `confirm` succeeds — the same grant the person row's own toggles perform. A failed grant never un-confirms the pairing: only `lastError` is set (via the same `fail(error)` path every other action uses), and the person row's own toggles remain the fallback, exactly as before this change. The friend side is untouched — `ApproverPersonRow`/`setApproverAccept` still require the friend to accept separately on their own device, so `isFullyTrustedForEarlyEnd` (which requires the scope on **both** sides) is never reached by this grant alone; consent stays bilateral. `OwnerPersonRow.statusDetail` now reads "Waiting for ‹nickname› to agree before they can approve early ends." once the owner side is granted but the friend hasn't accepted yet — reusing the pre-existing `hasGrantedApproveEarlyEnd`/`isFullyTrustedForEarlyEnd` state, not a new tracking mechanism. The owner-confirms UI test now also asserts the toggle defaults on and that this exact status text appears after Confirm, proving the owner-side grant actually took effect.

**A root cause found for the "local-relay-reachability flake" noted above.** While re-validating these two fixes, the same `CompanionTransportError.unavailable` ("Couldn't reach the relay…") symptom recurred — twice, on different tests each time, always on the app process's own HTTP call (never the UI test process's scripted friend/owner client, which uses a separate `URLSession` in a separate process and never failed). Running only the two owner-side tests in isolation (`-only-testing` for just those two) passed cleanly in the same simulator session that had just failed them as part of the full 5-test suite — isolating the cause to **simulator state accumulated across a single long-lived `xcodebuild test` invocation** (this session ran many consecutive full-suite invocations back to back while debugging the accessibility-identifier bug above), not the relay (`curl` against it from the host succeeded throughout every failure) and not the P2b code. A `xcrun simctl shutdown`/`boot` of the simulator, followed by waiting for the resulting load-average spike (reboot itself briefly pushed 1-minute load to ~33) to settle back under 10, cleared it — the subsequent full-suite run passed 5/5 cleanly. Documented here in case `PhoneLockboxUITests` becomes flaky again after many repeated runs in one session: a simulator reboot is the fix, not a product or test-code change.

**Re-validation (exact results, after both fixes):**
- `xcodebuild -scheme PhoneLockbox test`: **88 passed**, 1 pre-existing skip, 0 failures (unchanged from before this follow-up — no unit-test changes were needed, since the two fixes are UI/consent-flow behavior that needs the relay to exercise meaningfully).
- `xcodebuild -scheme PhoneLockboxUITests test`: **5/5 passed** in a clean full run (after the simulator reboot above), including the new placement (`isHittable`) and grant-at-confirm assertions. Screenshots re-exported to the same directory, overwriting the originals.

## Follow-up fixes: Opus review of 70c7d27 (2026-10-02)

An Opus review of commit `70c7d27` (the placement/grant-at-confirm follow-up above) returned **"approve with one P1."** Fixed in one further commit, same trailer.

**P1-1: a confirm/refresh race could resurrect a dismissed card, or let the owner confirm it.** `refreshInbox()` computed `pendingOwnerAcceptances` against a snapshot of `storedInvites` taken before a second `await` later in the same method (the approver-identity fetch); a concurrent "Not them"/confirm during that await could be undone when the stale list was assigned wholesale afterward. Separately, `confirmPendingAcceptance` never re-checked `storedInvites` at all before confirming, so a `VerifiedPendingAcceptance` the view was handed earlier could in principle still be confirmed after its invite was discarded elsewhere. Both fixed:
- `refreshInbox()`'s final assignment now goes through a new `reverifyPendingOwnerAcceptancesAtAssignmentTime(_:ownerIdentity:now:)` — the exact `OwnerAcceptanceCheck`/`storedInvites` re-verification, factored out so it is independently unit-testable without a network round trip, run immediately before publishing the list.
- `confirmPendingAcceptance` now guards `storedInvites[item.acceptance.inviteID] != nil` **and** re-runs `OwnerAcceptanceCheck.verify` against it before ever contacting the relay; if either fails, the card is dropped locally and nothing is confirmed.
- Two new unit tests cover this directly: `testConfirmPendingAcceptanceIsRefusedAfterTheUnderlyingInviteIsDiscarded` (the plan's explicit "confirm is refused after discard") and `testReverifyAtAssignmentTimeDropsAnEntryWhoseInviteWasDiscardedMidRefresh` (the explicit "one for the assignment filter"), plus a companion `testReverifyAtAssignmentTimeKeepsAnEntryWhoseInviteIsStillStored` for the non-racing path.

**P2s** (all in `PhoneLockbox/Companion/CompanionCoordinator.swift` and `PhoneLockbox/Views/PeopleView.swift` unless noted):
1. `InviteSomeoneCard`'s copy said the pending-acceptance card appears "below" — stale since the placement fix above. Now: "a card at the top of this page lets you confirm them."
2. The grant-at-confirm toggle is relabeled "Let them get and approve my early-end requests" (naming both `receiveRequests` and `approveEarlyEnd`), with an accessibility hint doing the same explicitly.
4. `IncomingInviteCard`'s Accept now clears `incomingInvite` only when `acceptInvite` actually succeeded (`companion.lastError == nil` afterward); on failure the prompt stays up with the error shown, so the owner can simply retry rather than having to reopen the link.
5. The friend side's "Waiting for the person who invited you to confirm" label now reads a new `hasPendingApproverAcceptance` computed property (`!pendingAcceptances.isEmpty`, the already-persisted plural list) instead of the transient `@Published var pendingAcceptance: PairingAcceptance?`, which is removed outright (it had no other reader left). This survives a relaunch and clears itself exactly when `applyInboxSnapshot`'s `.add` case consumes the matching record — not merely until the app restarts.
7. `storedInvites` is now capped at 20 (`maxStoredInvites`), dropping the oldest (by `issuedAt`) on overflow in `createInvite()`/the new `insertStoredInviteForTesting` test seam — a defensive bound against unbounded growth over a long device lifetime.
8. `testOwnerDismissesAPendingAcceptanceAsNotThem` is strengthened: a single pull-to-refresh plus a fixed timeout could pass even if that one gesture never actually completed a round trip. Now waits for a concrete "a refresh is in flight" signal to clear (`InboxCard`'s `ProgressView` gained `accessibilityIdentifier("inboxCard.refreshingIndicator")`) and then repeats the pull/assert-absent cycle three more times.
9. Nine new unit tests in `PhoneLockboxTests/CompanionPairingV2Tests.swift` (11 → 20): `storedInvites` persistence-and-expiry-pruning and capping across a coordinator re-init (two tests, using new DEBUG-only test seams `storedInvitesForTesting`/`insertStoredInviteForTesting`/`ensureOwnerIdentityForTesting`); `dismissPendingAcceptance` discarding the stored invite; the P1-1 pair above; and three grant-sequencing tests (`confirmPendingAcceptanceOverride`/`grantOwnerTrustAfterConfirmOverride`, new test-only override seams mirroring R5 Slice B2c's `useApprovalOverride`) covering the grant running only after a successful confirm and only when requested, a grant failure leaving the pairing confirmed with the failure surfaced, and the P2-10 pairing-ID-conflict case below.
10. `upsertConfirmedPairing` now returns `Bool` (`@discardableResult`). `confirmPendingAcceptance` only clears `lastError` and attempts the grant when it returns `true`; on a pairing-ID conflict (`false`), the specific conflict message `upsertConfirmedPairing` set is left in place, and the grant is skipped entirely — previously it would have landed on whatever *other* person happened to share the conflicting pairing ID, and the conflict warning would have been silently overwritten with `nil`. Covered by `testPairingIDConflictSkipsTheGrantAndKeepsTheConflictError`, using a new `testOnlySeedConfirmedPairing` test seam.

**Owner decision, recorded (P2-2/P2-9 docs ask):** the grant-at-confirm toggle is **on by default**. This is deliberately specific to **R5's two existing scopes** (`approveEarlyEnd`, `receiveRequests`) on a pairing the owner just confirmed with their own one-tap action — not a general precedent. **This pattern must not be reused for R6 status sharing**: R6 shares status (notices/summaries) with trusted people, sending it to the wrong person is a privacy harm in a way granting early-end trust to a just-confirmed pairing is not, and the original pairing v2 "Owner decision" above already requires R6 to add an explicit, informed confirmation before any status sharing is enabled (and to reconsider a matching-word check). A default-on toggle at confirm time would not satisfy that bar for R6.

**Mixed-version behaviour, recorded:** both the owner's and the friend's phones must be on this pairing-v2 build (or later) for pairing to work at all. A **new-build friend cannot pair with a build ≤20 owner**: build ≤20's "Accept invite" flow ends with the friend sharing an acceptance code back to the owner via the now-removed `PLBX-ACCEPT:` link format (`acceptanceShareText`/`decodeAcceptance`, deleted in the original P2b commit), and a new-build friend has no UI left to produce or share that link at all — the friend-side screen now only shows "Waiting for the person who invited you to confirm." The owner's build ≤20 has no inbox-delivered-acceptance UI to receive the new flow's relay-delivered `SignedAcceptance` either. In short: this is a hard compatibility break between build ≤20 and the pairing-v2 build, in both directions, not merely a degraded experience. Both people need to be on the new build before testing pairing together.

**On the "local-relay-reachability flake" root cause: unproven, walked back from the stronger claim above.** `CompanionTransportError.unavailable` and `.timedOut` both map to the identical user-facing banner ("Couldn't reach the relay. Check your connection and try again.") in `CompanionCoordinator.describe(_:)`, so the accessibility-hierarchy evidence gathered during this session's debugging — which only ever showed that shared banner text — cannot actually distinguish "could not connect at all" from "timed out," and high simulator/host load (observed up to ~33 1-minute load average after the simulator reboot) makes a plain timeout a plausible alternative explanation to the "simulator network state corruption" theory above, which was never independently confirmed beyond "a reboot made it stop happening once." Both remain consistent with the evidence. Added `#if DEBUG` logging in `CompanionCoordinator.fail(_:)` that prints which of the two transport-error cases actually occurred, so a future recurrence can be diagnosed precisely instead of inferred from indirect timing evidence.

**Re-validation (exact results):**
- `xcodebuild -scheme PhoneLockbox test`: **97 passed** (was 88; +9 new), 1 pre-existing skip, 0 failures.
- `xcodebuild -scheme PhoneLockboxUITests test`: **5/5 passed**, first attempt, no retry needed (load average ~3.3 beforehand). Screenshots re-exported, overwriting the previous set.
- `swift test --package-path CompanionKit` and root `swift test` were not re-run for this follow-up (nothing in `CompanionKit/**` or outside `PhoneLockbox`/`PhoneLockboxTests`/`PhoneLockboxUITests` changed).

**Files changed:** `PhoneLockbox/Companion/CompanionCoordinator.swift`, `PhoneLockbox/Views/PeopleView.swift`, `PhoneLockboxTests/CompanionPairingV2Tests.swift`, `PhoneLockboxUITests/CompanionPairingUITests.swift`, `docs/r5-pairing-v2-plan.md`.
