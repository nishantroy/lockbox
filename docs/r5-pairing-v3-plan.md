# R5 pairing v3: invite → accept → done

Status: **planned 2026-10-31.** Supersedes the confirm step and the per-scope consent switches of [pairing v2](r5-pairing-v2-plan.md). Builders: Claude Sonnet subagents in isolated worktrees. Reviews: Claude Opus subagents that did not write the code, including a dedicated UX/design-polish review (see `AGENTS.md`).

## Owner decision (2026-10-31)

Found during phone + simulator QA of build 21 (owner iPhone 15 Pro on iOS 27.2 + iPhone 17 simulator on iOS 26.5 as the friend, production relay):

> "We should literally just send the invite, then they accept, and that's it."

Build 21 took six actions to make a friend askable: create invite → friend accepts → owner refreshes and confirms → friend flips two consent switches → owner refreshes. v3 makes it two:

1. **Owner sends a link.** Creating the invite *is* the owner's grant of `approveEarlyEnd` + `receiveRequests`; the grant is signed into the invite.
2. **Friend taps Accept.** Accepting *is* the friend's consent to both scopes. The relay activates the pairing and both-sided consent atomically. The owner sees a non-blocking **"‹Name› joined"** notice; there is nothing to approve.

**Accepted risk:** anyone holding an unexpired, unused link becomes a trusted person without owner approval. Acceptable because an approver can only approve ending a session the owner explicitly asks *them* about; they can never start, extend or observe a lock; invites are single-use, short-lived and unguessable; the owner sees every person in People (plus the joined notice) and can remove them. Record this in `docs/companion-security.md`.

## Problems from build-21 QA this plan must fix

1. **Long link** (~620 chars of base64 JSON). Target ≈50 chars.
2. **No auto-refresh.** People only refreshes on first appearance and pull-to-refresh, so the owner never saw the acceptance while sitting on the tab.
3. **Pull-to-refresh always shows a relay error** on the owner phone (the owner sees a relay-connection error banner; the exact string is to be captured). Vercel logs show every `/v1/inbox` call in the session returned HTTP 200, so the failure is **client-side handling of a 200 response** (decode, integrity/anchor check, or similar), not transport.
4. **Ask now never reached the friend.** Relay ledger after the attempt: pairing `active`, consent `ownerScopes`/`approverScopes` both `[approveEarlyEnd, receiveRequests]` and `active`, session published and current (`kind: session`, accepted, revision 13), **`requests` empty**. Two further `POST /v1/operations` returned 200 (02:41:27 and 02:43:48 PDT) but left no `companion_operation` row; consistent with an idempotent replay of the session publish, with `requestUnlock` either never sent or failing client-side after `publishSession`. Root-cause and fix; do not guess.
5. **Toggles used for choosing who to ask.** Selection should be a list with checkmarks; if exactly one trusted person exists, preselect them.
6. **Friend sees "Person you're helping"** instead of who the owner is (`CompanionCoordinator.swift:1597`, `PeopleView.swift:410`). Carry the owner's display name in the invite.
7. **Disabled Ask button with no explanation** when a lock is active but nobody is fully trusted (branch order in `AskToEndEarlyCard`).
8. Friend side also needs to see incoming requests without manual refresh.

## Slices

### P3-0 — diagnose and fix problems 3 and 4 on the current protocol · Sonnet (high)

Runs **in parallel with P3a.** Owns `PhoneLockbox/Companion/**`, `PhoneLockboxTests/**`, `PhoneLockboxUITests/**`. If the root cause is in `CompanionKit/**` or `relay/**`, write it up precisely for the parent instead of editing (P3a owns those).

1. Reproduce against the local relay (`cd relay && npm run db:start && npm run dev`, port 8002) and, read-only, against production evidence above. Add a UI or integration test covering: pair → both consents → owner publishes session → owner `requestEarlyEnd` → friend inbox contains the request. It must fail before the fix.
2. Find why a 200 inbox response surfaces as a relay error on refresh. Make the banner name the real cause in DEBUG logs (never log keys/signatures).
3. Fix, with tests. Report the exact root cause(s) and the exact user-facing banner text that was shown.

### P3a — relay + protocol v3 · Sonnet (high)

Owns `relay/**`, `CompanionKit/**`, `CompanionRelayService/**`, `tools/relay-smoke/**`, protocol vectors.

1. **Invite token.** The relay stores the owner-signed invite keyed by a random **128-bit token** (22 chars base64url), which is both lookup key and bearer secret. New unauthenticated-but-rate-limited `GET`/`POST /v1/invite/lookup {token}` returns the signed invite while it is unexpired and unused; constant-time comparison; no enumeration signal beyond found/not-found.
2. **Invite payload v3** adds `ownerDisplayName` (≤40 chars, owner-chosen, optional) and `grantedScopes: [approveEarlyEnd, receiveRequests]`, all covered by the owner signature.
3. **Accept v3** = friend-signed acceptance including `approverDisplayName` and `acceptedScopes`. The reducer, in one transaction: verifies both signatures and token; consumes the invite; creates the active pairing; writes the relationship consent with both sides active. No `confirm` or `consent` operation is needed for the initial pairing. Later revocation/opt-out keeps working through the existing consent ops.
4. **Joined notice:** owner inbox exposes newly created pairings since the owner's last acknowledged revision (or a `joinedAt` on the pairing) so the app can show "‹Name› joined" once.
5. **Compatibility:** v2 invites/acceptances may simply stop being accepted (prototype; owner will re-pair). Document it. Keep retention purging tokens with their invite.
6. Parity in `InMemoryCompanionRelay` + regenerated vectors; tests for token lookup, single use, expiry, rate limit, cross-owner isolation, atomic pairing+consent, signature coverage of display names and scopes. Extend `tools/relay-smoke` for the v3 flow.

### P3b — app v3 + UX fixes · Sonnet (high), after P3-0 and P3a merge

Owns `PhoneLockbox/Companion/**`, `PhoneLockbox/Views/PeopleView.swift`, `PhoneLockbox/Views/SettingsView.swift` (only if a display-name field lives there), tests and UI tests.

1. **Link:** `phone-lockbox-companion://i/<token>` (keep parsing the long scheme only if trivial). On open: look up the invite, verify the owner signature, then show "**‹Owner name›** invited you to be a trusted person" with **Accept** / **Not now**. Expired/used → clear message.
2. **Accept** → paired immediately: friend sees "You're a trusted person for ‹Owner name›". No waiting state, no switches.
3. **Owner** sees a one-time "‹Name› joined" notice (dismissable, non-blocking) and the person immediately under trusted people. Remove Confirm/Not them, the pending-acceptance card and the consent switches from the default flow (removal from People stays).
4. **Display names:** owner's own name (one field, asked once when creating the first invite, editable later); friend's name entered on Accept, prefilled if previously set. Replace "Person you're helping"/"Trusted person" placeholders with names everywhere.
5. **Auto-refresh:** while People is visible, poll the inbox every ~5 s while an invite is outstanding or a request is pending, otherwise every ~30 s; also refresh on scene becoming active. Stop when not visible. Keep pull-to-refresh.
6. **Ask to end early:** checkmark list (not toggles); preselect when exactly one; button label "Ask ‹Name›" / "Ask 2 people"; when nobody is trusted, show the explanatory hint instead of a disabled button. Friend sees incoming requests promptly with the owner's name.
7. **UI tests** (simulator, local relay): owner creates invite → scripted friend accepts over HTTP → joined notice and person appear without manual refresh → owner asks → scripted friend sees the request. Friend-side test: open token link → Accept → paired state shows owner name. Attach screenshots for the UX review.

## Review gates

- **P3-0:** Opus (medium) — root cause proven by a failing-then-passing test.
- **P3a:** Opus (high) — security: token entropy/lookup, signature coverage, atomicity, isolation, retention.
- **P3b:** Opus (medium) code review **and** a separate Opus **UX/design-polish review** of the UI-test screenshots against `docs/layout-v1-contract.md`, `docs/design-polish.md` and `docs/interaction-design.md` (copy clarity, names instead of role placeholders, number of steps, control choice, empty/disabled states, accessibility labels, Dynamic Type, tab-bar overlap).
- **Parent:** all suites, UI tests with screenshots, production relay deploy + `tools/relay-smoke`, then build 22 on the phone and simulator for owner QA.

## Docs

Update `docs/companion-security.md` (accepted risk, token model), the R5 relay contract table, the roadmap and `docs/development.md` (build 22).

## P3-0 build results

Builder: Claude Sonnet (isolated worktree, branch `p3-0-fix` from `7669928`). Not yet independently reviewed.

### Root cause 4 — "Ask now never reached the friend" (proven)

`CompanionCoordinator.requestEarlyEnd` computed `validFor = min(max(60, end - Date()), 24h)` from one `Date()` and then called `AsyncCompanionClient.requestUnlock`, which stamps `createdAt = now()` from a **later** `Date()`. `TrustedRequest.init` (`CompanionKit/.../ProtocolModels.swift`, `expiresAt <= session.endsAt`) therefore threw `CompanionError.malformed("invalid trusted request")` **locally, before any network call**, for every lock with under 24 h left (always). `publishSession` had already succeeded (hence revision 13, `currentSessionID` set, empty `requests`); retries replayed the identical, deterministic-ID session operation (200, no new row). Banner shown: **"The relay rejected that action (malformed)."** (misleading: nothing was rejected by the relay). Fix: derive the lifetime and the client clock from one captured instant (`requestTime`), no 60 s floor (a floor can never be valid past the session end), and a calm message if the lock already ended.

### Root cause 3 — pull-to-refresh error (mechanism proven; on-device trigger inferred)

I could **not** reproduce a refresh error by any server-state or anchor path: against the real local relay, owner refresh was clean after pairing, after consents, after a session publish with no request, after an idempotent session replay, and after a request (all in `CompanionLocalRelayFlowTests`). What does exactly match "HTTP 200 on every `/v1/inbox`, yet an error banner" is **task cancellation**: `refreshInbox` ran its `URLSession` calls inside the `.refreshable`/`.task` structured task; when SwiftUI cancels that task, `session.data(for:)` throws `URLError.cancelled`, `HTTPCompanionTransport.performRequest` maps *every* `URLError` except `.timedOut` to `.unavailable`, and `describe` shows **"Couldn't reach the relay. Check your connection and try again."** The relay has already answered 200. Test `testCancelledRefreshDoesNotRaiseRelayErrorAndStillLoadsInbox` fails before the fix with exactly that banner. Caveat: I did not observe SwiftUI cancelling the task on the physical phone; if the owner still sees a banner on build 22, the new DEBUG `fail:` log line names the real underlying error. Fix: refresh now runs in one unstructured single-flight task (a cancelled or overlapping caller neither aborts the fetch nor raises a banner), and `fail` ignores cancellation.

### Found in files I do not own (suggested for P3a)

`CompanionKit/Sources/CompanionKit/HTTPTransport.swift` `performRequest`: `URLError.cancelled` should rethrow as `CancellationError` (or a distinct case) instead of `.unavailable`; `.unavailable` also hides DNS/TLS/ATS causes, so a `.notConnectedToInternet`/`.cannotConnectToHost` split would help. `TrustedRequest.init` / `AsyncCompanionClient.requestUnlock` could take an explicit `createdAt`/clamp `expiresAt` to `session.endsAt` so callers cannot hit the trap.

### Files changed

`PhoneLockbox/Companion/CompanionCoordinator.swift` (request lifetime fix, single-flight uncancellable refresh, cancellation-aware `fail`, DEBUG `fail:` diagnostic naming the underlying error, `makeClient(now:)`), `PhoneLockboxTests/CompanionLocalRelayFlowTests.swift` (new; needs a local relay on 127.0.0.1:8002, otherwise `XCTSkip`), regenerated `PhoneLockbox.xcodeproj/project.pbxproj`.

### Validation

Local relay: `cd relay && npm ci && npm run db:migrate && npm run dev` (port 8002, Postgres 56330). Simulator iPhone Air `83C2D731-9185-4288-A535-E3D51197FA4B`, `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'platform=iOS Simulator,id=83C2D731-9185-4288-A535-E3D51197FA4B' -derivedDataPath DerivedData-p30 CODE_SIGNING_ALLOWED=NO test -only-testing:PhoneLockboxTests[/...]`.

- Before Ask fix: `testAskNowReachesFriendAndOwnerRefreshStaysClean` and `testSecondAskForSameSessionStillCreatesRequest` failed (6 assertion failures, `fail: malformed("invalid trusted request")`).
- After Ask fix: `CompanionLocalRelayFlowTests` 3 tests, 0 failures.
- Before refresh fix (Ask fix kept): `testCancelledRefreshDoesNotRaiseRelayErrorAndStillLoadsInbox` failed (2 failures, "Couldn't reach the relay…", inbox empty).
- Final: `-only-testing:PhoneLockboxTests` on the iPhone Air simulator, local relay running: **101 tests, 1 skipped (pre-existing), 0 failures**, `** TEST SUCCEEDED **`; `CompanionLocalRelayFlowTests` 4 tests, 0 failures. UI tests not run (no UI/view code touched).

### P3-0 follow-up (Opus review of d71876d)

- P1-a: `refreshInbox` is now a looping single flight. A call arriving mid-flight sets `refreshNeedsAnotherPass`; the flight runs another pass before completing and callers await the final pass. The flight clears `refreshFlight` itself with no suspension after the loop check, so nobody joins a finished flight. Test `testRefreshAfterMutationIsNotSatisfiedByStaleInFlightFetch`.
- P1-b: regenerated `project.pbxproj` committed.
- P1-c: **deferred** coordinator-level Ask test without a relay. `makeSession` only allows a `URLProtocol` stub, which would need a hand-written relay; the relay-backed tests skip (not fail) without port 8002. P3a's always-running CompanionKit clamp test covers the logic.
- P2-a: `fail()` ignores only `CancellationError` (relies on P3a rethrowing `URLError.cancelled` as `CancellationError`; until that merges, the unstructured refresh task already prevents the cancel from reaching URLSession). `replayPendingFriendRelease` moved out of the `.refreshable` closure into its own `Task`.
- P2-b/c: lead time checked before publishing; fewer than 30 s left shows "This lock is about to end.", already ended shows the earlier message.
- P2-d: `refreshFlight` moved beside the other state properties.
- Build output moved to `/Users/nishantroy/code/.build-cache/phone-lockbox/agent-a4b3153e8b357a36c/`.
- Follow-up validation: full `-only-testing:PhoneLockboxTests` on iPhone Air with local relay: **102 tests, 1 skipped, 0 failures, TEST SUCCEEDED** (`CompanionLocalRelayFlowTests` 5 tests; each spaces 22 s because the local relay allows 60 requests/minute per IP; one earlier run tripped `rate_limited` without that spacing). I did not separately prove the stale-fetch test fails against the pre-follow-up coordinator.

### P3-0 follow-up 2 (stale-fetch test made deterministic)

DEBUG-only hooks on `CompanionCoordinator`: `inboxFetchGateForTesting` (awaited inside every refresh pass after the relay responses arrive and before they are applied) and `refreshCallCountForTesting`. `testRefreshAfterMutationIsNotSatisfiedByStaleInFlightFetch` starts a refresh, and its gate holds pass 1 (response already fetched, so it predates the request) until a second `refreshInbox()` call has arrived; the only such call is the one `requestEarlyEnd` makes after `requestUnlock` returns. Why it fails on the d71876d logic: there the second caller merely `await`s the flight and returns, and the flight applies the held pass-1 response (zero requests) with no further pass, so `owner.inboxItems.count == 0`, not 1. With the looping flight, the joiner sets `refreshNeedsAnotherPass`, a second pass fetches after the request exists, and the count is 1. Residual non-determinism: pass 1's fetch is assumed to reach the relay before `requestEarlyEnd`'s two round trips finish (it is issued first; the gate cannot enforce that). The test still needs the relay (skips without it); the 22 s sleep in `requireRelay` is a **stopgap** until the relay slice adds a dev-only rate-limit override.

**Not run (owner rule change: no simulator test runs):** the fail-before/pass-after execution and the full `PhoneLockboxTests` suite. Only `xcodebuild build-for-testing -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator'` was run: TEST BUILD SUCCEEDED. The parent runs the suites before merge.

## P3a build results (2026-10-31)

Built by a Claude **Sonnet** subagent (model `claude-sonnet-5-5`) in an isolated worktree. Not yet independently reviewed (Opus high security review is the next gate).

### Design choices
- (Superseded by the review follow-up below: the token now never reaches the relay; only a lookup key and token-derived proofs do.) **Token origin: owner-generated, signature-covered.** The owner device makes 16 random bytes (22 base64url chars). The invite payload signs `tokenHash` = SHA-256(`PhoneLockbox.Companion.v1.invite-token` framed + token), never the token. The relay therefore cannot swap invites, and neither the ledger nor `companion_invite_token` holds a usable secret. The plaintext token reaches the relay only in the lookup request and the friend's accept body; the owner's `createInvite` returns it once (`IssuedInvite.token`, `.shareLink` = `phone-lockbox-companion://i/<token>`).
- **Storage.** Signed invite stays in the owner ledger. New table `companion_invite_token(token_hash PK, owner_id, invite_id, expires_at)` (migration `004_invite_token.sql`) routes a lookup to the owner. Written in the invite's transaction, deleted in the accept's transaction, swept at expiry by retention (`purgedInviteTokens`), cascade-deleted with the owner. A hash already registered is refused (`replay`).
- **Lookup.** `POST /v1/invite/lookup {token}`; per-IP limit 20/min via the existing global limiter; found vs `not_found` only; `timingSafeEqual` on the hash in the service and reducer.
- **Accept** (single reducer call = one transaction): verifies approver key/signature, owner, token hash, expiry, `issuedAt` window, `acceptedScopes == grantedScopes`; consumes the invite; creates the pairing (epoch 1, names from invite/acceptance) and the relationship consent (**generation 2**, both sides active: equivalent to the v2 grant + accept, so downstream generation bindings are unchanged). Wrong/unknown token or bad signature is one `unauthorized`; after the token is proven: `replay` (used), `expired`, `consent_required`.
- **Joined notice.** `Pairing.createdAt` is the join time (no separate `joinedAt`); `Pairing` gains `ownerDisplayName`/`approverDisplayName`. The app shows "‹Name› joined" once by remembering seen pairing IDs locally (on first run after upgrade mark existing ones seen). To replace the removed confirm step, the owner inbox also returns `acceptances` (the friend-signed acceptance per v3 pairing, owner-only) and CompanionKit's new pure `JoinedAcceptanceCheck` proves a relay-reported pairing came from the holder of a token for an invite this device created. P3b should show "joined" only for pairings that verify.
- **Same friend, second invite** creates a second pairing (existing same-identity semantics kept; an `already_paired` rule was tried and removed because an existing test deliberately covers same-identity pairings). P3b may want to dedupe in the UI.
- **Compatibility.** v2 invites/acceptances are rejected (`malformed`); `confirm` is `unsupported_operation`; stored v2 invites are inert (no token hash) and expire; legacy `pendingAcceptances` ledger keys are left untouched (state-root integrity) and purged by retention. Wire is not backward compatible: both phones must run the P3b build.
- **Absorbed from parent message:** (1) `HTTPCompanionTransport.performRequest` now rethrows `URLError.cancelled` (and `CancellationError`) as `CancellationError`; other URL errors still map to `unavailable`/`timedOut` (test `testCancelledURLRequestIsCancellationNotUnavailable`). (2) `requestUnlock` (sync and async, both overloads) clamps `expiresAt` to `min(createdAt + validFor, session.endsAt)`; constructor and `makeClient(signer:now:)`-style API untouched (test `testRequestExpiryIsClampedToTheSessionEnd`). A session that has already ended still fails at `TrustedRequest.init` (`malformed`).

### Files changed
`relay/`: `src/{canonical,protocol,ledger,reducer,service,db,handlers,retention}.ts`, `scripts/dev-server.ts`, `api/v1/invite/lookup.ts` (new), `migrations/004_invite_token.sql` (new), `README.md`, `test/{setup,lifecycle,security-fixes,owner-approval-delivery,retention,vectors}.test.ts`, `test/pairing-v3.test.ts` (new; replaces deleted `pairing-v2-inbox.test.ts`), `test/fixtures/vectors.json` (regenerated).
`CompanionKit/`: `ProtocolModels.swift`, `InMemoryRelay.swift`, `HTTPTransport.swift`, `DurableSemantics.swift`, `JoinedAcceptanceCheck.swift` (new, replaces deleted `OwnerAcceptanceCheck.swift`), `CompanionVectorGen/main.swift`; tests: `CompanionKitTests`, `HTTPTransportTests`, `OwnerApprovalCheckTests`, new `JoinedAcceptanceCheckTests`, new `PairingV3TestSupport.swift`; deleted `OwnerAcceptanceCheckTests`, `PendingAcceptanceInboxTests`.
`CompanionRelayService/`: `DurableReducer.swift`, `DurableRelay.swift`, `DurableStore.swift`, `DurableRelayServiceTests.swift` (+1 test). `tools/relay-smoke/Sources/relay-smoke/main.swift` (v3 flow). Docs: `r5-relay-plan.md` (contract v1.4, endpoint), `companion-security.md` (token model, accepted risk).

### Migration notes
Apply `004_invite_token.sql` (additive, `IF NOT EXISTS`) before deploying the new relay. Existing owner rows are unchanged and keep verifying their state root. Rolling back the relay after v3 pairings exist is not safe (old reducer cannot read `acceptance` on pairing rows or v3 invites). Swift snapshot schema bumped 4 to 5 (developer-harness only).

### Validation (exact)
- Database: Docker Postgres container `relay-postgres-1` (port 56330, started because Docker was down), isolated database `p3a_test` created for this slice; the shared `companion_relay` database was not touched. No server bound to 8002; no deploys.
- `cd relay && DATABASE_URL=postgres://relay:relay@127.0.0.1:56330/p3a_test npm test`: 10 files, **170 passed** (was 150; new `pairing-v3.test.ts` has 28). `npm run typecheck`: clean.
- `swift test --package-path CompanionKit`: **154 passed**. `swift test --package-path CompanionRelayService`: **19 passed**. Root `swift test`: **177 passed**. `swift build --package-path tools/relay-smoke`: builds.
- Cross-language parity: regenerated `vectors.json` with `CompanionVectorGen`; TS verifies the Swift-signed v3 invite and acceptance and re-encodes the Swift inbox/pairing/lookup samples identically.
- **Not run:** `tools/relay-smoke` against a live relay (needs a server on 8002; left for the parent).

### P3b must change (app no longer compiles against CompanionKit)
Removed: `Invitation.shareLink`/`fromShareLink`, `AsyncCompanionClient.accept`/`confirm`, `PairingAcceptance.verificationCode`/`.code`, `PairingConfirmation`, `SignedConfirmation`, `OwnerAcceptanceCheck`, `InboxResponse.pendingAcceptances`. Replacements: `createInvite(...) -> IssuedInvite {invitation, token, shareLink}` (new params `ownerDisplayName`, `grantedScopes`; keep `token`, which is not recoverable from the invitation), `lookupInvite(token:)`, `acceptInvite(_:token:approverDisplayName:acceptanceID:now:) -> Pairing`, `InviteToken` (`generate`, `isWellFormed`, `shareLink(token:)`, `token(fromShareLink:)`), `InboxResponse.acceptances`, `JoinedAcceptanceCheck.verify`/`verifiedPairings`, `Pairing.ownerDisplayName/approverDisplayName`. Affected app files known from grep: `CompanionCoordinator.swift` (pending-acceptance store, `verifyPendingAcceptances`, `confirmViaRelay`, `createInvite`, accept), `PeopleView.swift` (shareLink, pending card), `CompanionPrototype.swift` (developer flow: use `createInvite`/`lookupInvite`/`acceptInvite`), `CompanionPendingAcceptance`/`CompanionTrustMerge` (owner path "never materializes a pairing from the inbox" must now allow a verified joined pairing; friend path should store the `Pairing` returned by `acceptInvite` directly), and the app tests. The owner device must persist the `Invitation` (and token while the link is live) per invite so `JoinedAcceptanceCheck` has the invite to verify against. Friend must tolerate `not_found` (used/expired) and `rate_limited` from lookup, and `HTTPCompanionTransport` now maps HTTP 404.

### Open risks
- (Resolved in the review follow-up: the plaintext token is never sent to or stored by the relay.)
- A relay observing the token can race the friend (accepted risk, documented).
- Lookup limiter is per-IP with an `unknown` shared bucket if `x-forwarded-for` is missing (Vercel always sets it).
- The durable `CompanionRelayService` reference does not retain acceptances or serve inbox/lookup (it has no inbox).
- `tools/relay-smoke` v3 flow is compiled but unrun.

### P3a review follow-up (Opus high review of d4b0ea3; fixes 2026-10-31, same Sonnet builder)

**P1**
1. **Lone surrogates.** `decodeDisplayName` rejects non-well-formed strings (`/\p{Surrogate}/u`) at every decode path (invite, acceptance, pairing, stored-result decode), so a name that signs as replacement bytes and later breaks Swift's JSON decode of the owner inbox can no longer be stored. Tests in `relay/test/pairing-v3.test.ts`.
2. **Relay can no longer swap invites or fabricate a trusted person (link stays 22 characters).** The token now never leaves the devices. `lookupKey = H(invite-lookup, token)` is what the relay stores and what lookup sends; the invite signs `tokenHash = H(invite-token, token, ownerPublicKey, inviteID)` (friend checks it from the token in the link) and `lookupKey`; the acceptance carries `lookupKey` and `tokenProof = H(accept-proof, token, approverPublicKey, acceptanceID)`, which the **owner** verifies (`JoinedAcceptanceCheck.verify(signedAcceptance:pairing:issued:ownerIdentity:)`, `issued` = `IssuedInvite` with the persisted token). Wire changes: lookup body `{"lookupKey": base64url}`; invite payload `+lookupKey`; acceptance `-token +lookupKey +tokenProof`; sign fields updated; `Invitation.validate(at:matchingToken:)` now uses `InviteToken.matches(_:payload:)`. Transport protocols take `lookupInvite(lookupKey:)`. Migration `005_invite_lookup_key.sql` (renames the column, discards unusable 004 rows, adds `consumed_at`). Tests: relay-signed invitation reusing the lookup key is rejected by the friend; a relay-fabricated acceptance is accepted by the relay but rejected by the owner check; request bodies contain no token. `docs/companion-security.md` rewritten so each claim holds (accepted risk remains link holders).
3. **Duplicate acceptances.** `verifiedPairings` now returns `Result { verified, integrityWarnings }`, rejects every pairing of an invite reported with more than one acceptance and warns, and drops non-active pairings.

**P2**
1. Skew: dropped the acceptance `issuedAt < invite.issuedAt - 60` and `>= expiresAt` checks and the friend-side `issuedAt - 60` bound; invite-from-future tolerance is 300 s (`CompanionLimits.pairingClockSkew`); an acceptance more than 300 s ahead of the relay is `malformed`, never `expired`.
2. Names: identical explicit rules on both sides (U+FEFF counts as blank; bidi U+202A-202E, U+2066-2069, U+061C and U+200B/200E/200F rejected; U+200D allowed). Swift-signed vectors (`displayNameInvites`: NFD, astral, emoji ZWJ, 40 scalars) verify and re-encode in TS.
3. `verifiedPairings` filters non-active pairings (see P1.3).
4. Docs now say where derived token material lives and that expired rows go with the daily cron.
5. Accept retried under a new operation ID returns the same approver's existing pairing (TS, in-memory, durable).
6. The token row is kept as a consumed tombstone until expiry (`consumed_at`).
7. HTTP 404 maps to `not_found` only for the relay's JSON error body; a bare 404 is `unavailable`.
8. Documented for P3b: pre-v3 and `replace_pairing` pairings have no acceptance and are never returned by `verifiedPairings`.
9. Documented the forward-only deploy order: migrations 004 and 005, then relay, then app; no rollback.

**Extra (parent request):** `RELAY_RATE_LIMIT_MAX` / `RELAY_LOOKUP_RATE_LIMIT_MAX` override the global and lookup limiters for local testing only (ignored, with one warning, when `VERCEL_ENV=production`, `NODE_ENV=production`, any `VERCEL` marker is set, or the value is invalid); `npm run dev:test` starts the dev server on 8002 with both set to 100000. Test: `relay/test/rate-limit-override.test.ts`. Documented in `relay/README.md`.

**P3b API changes from this round:** `IssuedInvite` (invitation + token) must be persisted per live invite and passed to `JoinedAcceptanceCheck`; `verifiedPairings(in:invites:ownerIdentity:)` takes `[String: IssuedInvite]` and returns a `Result`; show `integrityWarnings` somewhere visible; `AsyncCompanionTransport.lookupInvite(lookupKey:)` replaces `lookupInvite(token:)` for custom transports.

**Validation (build output under `/Users/nishantroy/code/.build-cache/phone-lockbox/agent-a444bb184a546cde2/`; relay run against isolated database `p3a_test` on the existing 56330 container, so migration 005 was exercised on top of 004; no server on 8002):**
- `cd relay && npm test`: 11 files, **182 passed**; `npm run typecheck` clean.
- `swift test --package-path CompanionKit`: **160 passed**. `swift test --package-path CompanionRelayService`: **19 passed**. Root `swift test`: **177 passed**. `tools/relay-smoke` builds (not run: needs a live relay).

### P3a review follow-up 2 (Opus high re-review of 84c9fb4; fixes 2026-10-31)

1. **Relay-verifiable proof of possession (P2-1c).** `possessionKey` (public half of an Ed25519 keypair seeded by `H("invite-possession", token)`) is signed into the invite; the acceptance carries `possessionSignature` over (acceptanceID, inviteID, owner, approver public key, lookup key), covered by the friend signature. The relay (TS, in-memory, durable) verifies it before consuming the invite, so a reader of the DB or logs holding only the lookup key cannot burn invites (test: garbage, foreign-token and replayed possession signatures are rejected and the invite stays usable). `tokenProof` and the owner-side check remain; the owner check also verifies the possession signature.
2. `verifiedPairings` adds an integrity warning when an acceptance matches a locally held invite but fails verification (unrelated invites stay silent).
3. Docs: owner must retain the `IssuedInvite` (incl. token) while the pairing exists and delete it on removal; `IssuedInvite` is now `Codable, Hashable` (store the token in the Keychain).
4. Rate-limit overrides now need `RELAY_LOCAL_DEV=1`, set only by `scripts/dev-server.ts`, plus no production markers.
5. `dev:test` pins `RELAY_HOST=127.0.0.1 RELAY_PORT=8002`.
6. My scratch database `p3a_test` is dropped. Migration 005 notes that databases which ran d4b0ea3 must be recreated.
7. Token rows (live, expired, consumed) are kept until the 30-day purge (`expires_at < now - 30d`), so an expired lookup key cannot be re-registered.
8. Owner check bounds `acceptance.issuedAt < invite.expiresAt + 300 s`. Names made only of invisible fillers (U+3164, U+2800, U+115F/1160, U+2060, U+00AD, U+200D, tag characters) are rejected on both sides.

**P3b note:** `InvitePayload`/`PairingAcceptance` gained `possessionKey`/`possessionSignature` (no app change beyond using `createInvite`/`acceptInvite`).

**Validation (build output under `/Users/nishantroy/code/.build-cache/phone-lockbox/agent-a444bb184a546cde2/`):** relay `npm test` 11 files, **185 passed**, `npm run typecheck` clean; CompanionKit **163 passed**; CompanionRelayService **19 passed**; root `swift test` **177 passed**; `tools/relay-smoke` builds (not run).

## P3b build results (2026-10-31)

Built by a Claude **Sonnet** subagent (model `claude-sonnet-5-5`), branch `p3b-app` from `r5-relay` at `1e3e508`. Reviewed by Claude Opus (code review, then re-review of `05fc378`: pass with P2s, now in P3c). The UX/design-polish review runs on the pre-push suite screenshots.

### Files changed
`PhoneLockbox/Companion/CompanionCoordinator.swift` (rewritten invite/accept/trust/refresh paths), `PhoneLockbox/Companion/IssuedInviteStore.swift` (new), `PhoneLockbox/Companion/CompanionPrototype.swift`, `PhoneLockbox/Views/PeopleView.swift`, `PhoneLockbox/ContentView.swift` (comment only), `PhoneLockboxTests/CompanionPairingV3Tests.swift` (new; replaces deleted `CompanionPairingV2Tests.swift`), `CompanionLocalRelayFlowTests.swift`, `FriendReleaseWiringTests.swift`, `PhoneLockboxUITests/CompanionPairingUITests.swift` (rewritten), regenerated `PhoneLockbox.xcodeproj/project.pbxproj`. `CompanionKit/**`, `relay/**` untouched; `project.yml` untouched (sources are directory globs).

### How each item was met
1. **Link.** `phone-lockbox-companion://i/<token>` via `InviteToken`; `lookUpInvite` -> `AsyncCompanionClient.lookupInvite(token:)` (which uses `lookupInvite(lookupKey:)`) plus an explicit `Invitation.validate(at:matchingToken:)`; prompt "‹Owner› invited you to be a trusted person" with Accept / Not now. not_found/used, expired, rate-limited, unreachable and invalid links each get a calm message. A pasted link is the manual fallback. Opening your own link is refused with a message.
2. **Accept.** `acceptIncomingInvite` -> `acceptInvite(..., approverDisplayName:)`; the returned `Pairing` is stored directly; the friend row reads "You're a trusted person for ‹Owner›". No waiting state, no switches. Transient failures keep the prompt for retry; final ones replace it with a message.
3. **Owner.** Each `IssuedInvite` is stored in the Keychain (`KeychainIssuedInviteStore`, one item, `AfterFirstUnlockThisDeviceOnly`; token never in UserDefaults or logs), kept while a person created by it exists (retention 30 days after expiry otherwise), and deleted when the person is removed. People are added only from `JoinedAcceptanceCheck.verifiedPairings`; consents are accepted only for verified people; requests target and approvals (`selectFriendRelease`) are accepted only from verified people. `integrityWarnings` -> calm `people.integrityNotice` card. One-time dismissable "‹Name› joined" notice (seen pairing IDs tracked in the App Group defaults). Duplicate accepts by the same friend are one row (dedupe by approver identity; Remove revokes all duplicates). Pre-v3 pairings decode as unverified: hidden, with a "send a new invite" hint. **`CompanionTrustMerge` itself is in CompanionKit (not mine), so it was not edited:** the app no longer uses its pending-acceptance machinery (passes `[]`) and handles the owner "add" path with the join check instead; stale `CompanionPendingAcceptance`/`pruneExpiredPendingAcceptances` in CompanionKit are now unused by the app.
4. **Names.** Owner name asked once in the invite card, editable ("Edit"), validated with `PairingFields.validateDisplayName` and signed into new invites; friend name entered on Accept and prefilled afterwards. Placeholders replaced by pairing display names (fallbacks "Unnamed person"/"Someone" only for nameless pre-v3 pairings).
5. **Auto-refresh.** `PeopleView` `.task(id: scenePhase)` runs `runAutoRefreshLoop`: immediately, then every 5 s while an invite is outstanding or a request pending, else 30 s; cancelled when People is not visible or the scene is not active; pull-to-refresh kept. `refreshInbox` flight capped at `maxRefreshPasses = 3`.
6. **Ask to end early.** Checkmark rows (`isSelected` trait), preselected and non-interactive when exactly one person; "Ask ‹Name›" / "Ask 2 people"; hint instead of a disabled button when nobody is trusted. Friend inbox rows use the owner's real name.
7. **Tests.** See below. The 22 s sleep in `requireRelay()` is removed; tests expect `cd relay && npm run dev:test`.

### Removed UI
Pending-acceptance card (Confirm / Not them / name field / grant switch), consent switches on both person rows, "Waiting for the person who invited you to confirm", all six-digit/code copy, the legacy long-link handling, `confirmPendingAcceptance`, `setOwnerGrant`, stored `Invitation`/pending-acceptance defaults (legacy keys are deleted at launch). Added: friend-side "Stop being a trusted person" (opt-out) since the switches that allowed it are gone.

### Validation (compile-only, exact)
- `xcodegen generate`; `xcodebuild build -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -derivedDataPath /Users/nishantroy/code/.build-cache/phone-lockbox/agent-a8417ae781fc1e795/DerivedData CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED** (before tests were rewritten).
- Same command with `build-for-testing`: **TEST BUILD SUCCEEDED** (app, unit tests and UI tests compile).

### NOT run
No simulator was booted; `xcodebuild test`, the new unit tests (`CompanionPairingV3Tests`, 24 tests incl. fixtures built offline from CompanionKit's in-memory relay), the relay-backed `CompanionLocalRelayFlowTests`, and all `PhoneLockboxUITests` have not been executed. `swift test` for packages was not run (no package changes). No relay was started.

### Notes
- The UI test cannot start a real lock, so "owner asks" is covered in `CompanionLocalRelayFlowTests`; the UI test has a scripted owner send the request to the app-as-friend and asserts "‹Owner› is asking for help". The friend polls at the 30 s idle cadence, so that wait is up to ~30 s.
- Model: Claude Sonnet.

### P3a polish (final Opus review findings; Sonnet 5.5 builder, 2026-10-31)

1. `IssuedInvite` now conforms to `CustomStringConvertible`, `CustomDebugStringConvertible` and `CustomReflectable`; the token and share link render as `<redacted>` in `print`, `dump`, `Mirror` and string interpolation. `Codable` is kept (the app persists it, in the Keychain). No other type stores the plaintext token.
2. Invisible-filler names: the explicit blank set (both `relay/src/protocol.ts` and `PairingFields.isBlankScalar`) gained U+FFA0, U+200C, U+034F, U+180E, U+2061-2064, U+FE00-FE0F and U+1D173-1D17A. An explicit set was kept over a general-category rule because several fillers (U+3164, U+FFA0, U+115F/1160) are category Lo, so a category test cannot exclude them. ZWJ, ZWNJ and VS16 remain legal inside names with a visible scalar; Swift-signed vectors `zwnj-persian` and `emoji-vs16` added to `vectors.json`.
3. Retention: the ledger purge for invites keys on `max(consumedAt, expiresAt) + 30d` (a consumed invite's token tombstone previously went at `consumedAt + 30d`, before expiry + 30d). The Swift in-memory/durable references have no retention purge, so nothing to mirror. Test added.
4. Comment at `reducer.ts` accept-path rewritten; `JoinedAcceptanceCheck.verifiedPairings` no longer holds a `()?` value (warning gone).

### P3b review follow-up (Opus review of a17b438; same Sonnet builder)

After merging `r5-relay` (only conflict: this doc, both sections kept):
1. **Keychain robustness.** `IssuedInviteStore.load()` returns `found` / `notFound` / `failed` (any status other than success or item-not-found, and decode failure, is `failed`); `save` returns `Bool`. While a read has failed the coordinator never writes to the store, never prunes, and does not recompute `joinVerified` (previously verified people stay verified); the next refresh retries the read and shows "Couldn't read this device's saved invites just now. Your trusted people are unchanged; try again after unlocking your phone." `createInvite` refuses while unreadable and, if the save fails, does not show the link ("Couldn't save the invite securely on this device, so it wasn't shown. Try again."). Tests use an injected failing `InMemoryIssuedInviteStore`.
2. **Stop being a trusted person.** One `revokeScopes` call with both scopes per active approver pairing for that owner identity (test with two pairings, asserts 2 calls, both scopes).
3. **Friend `upsertAcceptedPairing`** goes through `CompanionTrustMerge.decide` (advance-only); a conflicting or older response is ignored with the existing "conflicts with one already stored" message and Accept reports failure (test).
4. **Token exposure.** The link is the accessibility value only in DEBUG builds ("Ready to share" in release). Copy uses `UIPasteboard.setItems` with `.localOnly` and a one-hour expiry.
5. **Refresh cap.** When the flight ends still flagged (a caller joined during the last allowed pass), exactly one follow-up flight runs; it never chains (test).
6. **`selectFriendRelease` without `approvalID`** returns the first approval that verifies; with none, the first failure (test).

Nits: lookup uses an ephemeral in-memory signer so no friend identity is minted before Accept; the hint when people joined but none is fully trusted reads "Nobody can be asked right now. Check Your trusted people below."; after relaunch the newest unexpired unused invite becomes `pendingInvite` again (link shown, fast polling matches what is visible); stored invites are purged at launch when no owner identity exists; ContentView mention fixed. New tests: verified person demoted when the acceptance disappears; friend-side stop; read-error handling; save-failure handling; relaunch restore; purge.

Validation (compile-only): `xcodegen generate` then `xcodebuild build-for-testing -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -derivedDataPath /Users/nishantroy/code/.build-cache/phone-lockbox/agent-a8417ae781fc1e795/DerivedData CODE_SIGNING_ALLOWED=NO` gave **TEST BUILD SUCCEEDED**. Not run: any simulator test, unit or UI.

## Build-22 owner QA (2026-10-31)

Owner's iPhone 15 Pro (owner role) plus the iPhone 17 Pro Max simulator (friend role), both on the production relay running v3. **Passed:** invite, open link, friend Accept with no owner confirm, a lock added, Ask sent, friend approve and decline. **Install issue, not a code defect:** the first simulator install was the compile-only build without an App Group, so Accept failed locally and was shown as "couldn't reach the relay". Reinstalled a signed simulator build; `docs/development.md` now gives the command.

Follow-ups from this QA (UX/bug batch, not yet built):
1. **Copy link** sets `.localOnly`, so Universal Clipboard never gets the link (owner pastes on the Mac). Drop `.localOnly`, keep the 1-hour expiry, and add visible "Copied" feedback plus a haptic (owner feedback: the button gave too little visible feedback).
2. Local failures (App Group/identity storage) are shown as "couldn't reach the relay". Map them to an accurate message.
3. Opening an invite link scrolls to partway down the Accept card, cutting off its heading. Scroll to the top of the card.
4. The owner's phone kept offering an expired invite's link. Show it as expired, with a one-tap new invite.
5. On a fresh install, the friend first sees owner-setup copy, and "Got an invite link?" is near the bottom.

## Slice P3c: build-22 QA follow-ups (plan, 2026-10-31)

Two Sonnet builders in parallel, in isolated worktrees from `r5-relay` at the commit that adds this section. File ownership does not overlap. Neither boots a simulator or runs `xcodebuild test`.

### P3c-app (builder A)
Owns `PhoneLockbox/**`, `PhoneLockboxTests/**`, `PhoneLockboxUITests/**`, `CompanionKit/Sources/CompanionKit/TrustMerge.swift` and its tests.
1. **Copy link.** Drop `.localOnly` (keep the one-hour expiry) so Universal Clipboard works. After a tap, the button shows "Copied" with a checkmark for about 2 s, plus a light haptic and an accessibility announcement.
2. **Accurate errors.** Local failures (App Group unavailable, identity or Keychain storage) must not show "Couldn't reach the relay". Use a calm message that says what happened and what to do. Only transport errors say the relay is unreachable.
3. **Opening an invite** scrolls People so the incoming-invite card's heading is visible at the top.
4. **An expired pending invite** is shown as expired ("This link expired. Create a new one."), with the create action available. It stops fast polling and is no longer offered for share or copy.
5. **Friend first-run.** When there is an incoming invite, or no owner setup has happened, "Got an invite link?" is easy to find, not below all the owner-setup copy. Keep it to the smallest change, such as moving the card above the owner invite card when nobody has been invited yet.
6. **P3b re-review P2s:**
   - P2-1: tell a Keychain decode failure apart from a locked device (`errSecInteractionNotAllowed`). A corrupt item gets a recovery route (clear the invite store and say that pending links stop working), with accurate copy.
   - P2-2: removing a person while the store is unreadable must not leave their token behind. Queue the deletion, or block removal with a message. Also, `restorePendingInvite` must not restore a consumed invite.
   - P2-3: call `restorePendingInvite()` when a read succeeds again mid-session.
   - P2-4: Stop must not clear a consent warning that it set itself.
   - P2-5: clear or recompute `integrityNotice` while the store is unreadable.
7. **P3-0 leftovers:** an app-level Ask test that always runs (not only with the local relay), plus tests for the "about to end" and "already ended" messages.
8. **Remove the confirm step.** Remove `CompanionPendingAcceptance`, `pruneExpiredPendingAcceptances` and the `pendingAcceptances:` parameter of `CompanionTrustMerge.decide`, update its callers, and fix stale `confirm()` comments. Keep the `legacyDefaultsKeys` cleanup, which deletes old data.

### P3c-protocol (builder B)
Owns `relay/**`, `CompanionKit/Sources/CompanionKit/ProtocolModels.swift` (name rules only), the CompanionKit vector generator, and name/vector tests. Wire format unchanged; no migration.
1. Fix the stale comment at `relay/src/retention.ts` ~271–272: tombstone, purged at `max(consumedAt, expiresAt) + 30d`.
2. The per-owner `deleteInviteToken` purge counts toward `summary.purgedInviteTokens`. Test it.
3. Add blank scalars to both sides at once, with tests and a Swift-signed vector:
   - U+E0100–E01EF;
   - U+180B–180D and U+180F;
   - U+17B4–17B5;
   - U+206A–206F;
   - U+1BCA0–1BCA3;
   - U+FFF9–FFFB.
4. Fix the stale "confirm" comments in `relay/src/db.ts` and `protocol.ts`. Leave `ledger.ts` `pendingAcceptances?` alone: it reads old ledgers.

Gates: an Opus code review of each, then the pre-push app suites, then the UX review on their screenshots.

### P3c-protocol build results (Claude Sonnet, `claude-sonnet-5-5`, branch `p3c-protocol` from `4da3126`)

Changes (wire format unchanged, no migration):
1. `retention.ts`: stale comment at the per-owner `deleteInviteToken` call rewritten (token rows are tombstones until the ledger purge at `max(consumedAt, expiresAt) + 30d`; the global sweep only catches orphans).
2. `deleteInviteToken` now returns the deleted row count and the per-owner purge adds it to `summary.purgedInviteTokens`. The existing retention tests assert `purgedInviteTokens` of 2 and 1 after the ledger purge.
3. Blank scalars added to both `relay/src/protocol.ts` `isBlankScalar` and `PairingFields.isBlankScalar` (identical sets): U+E0100-E01EF, U+180B-180D, U+180F, U+17B4-17B5, U+206A-206F, U+1BCA0-1BCA3, U+FFF9-FFFB. Rejection tests on both sides. Swift-signed vectors `ideographic-vs` (U+8FBB U+E0100) and `mongolian-fvs` (U+1820 U+180B U+1821) prove these stay legal beside visible scalars; `vectors.json` regenerated (other entries' bytes also changed on regeneration; the TS suite verifies them).
4. Stale "confirm" comments fixed in `db.ts`. The `protocol.ts` and `retention.ts` mentions of "confirm" describe the removed step accurately and were left. `ledger.ts` untouched. `companion-security.md` does not list the scalars, so unchanged.

Ran: `npm ci` in `relay/` (node_modules was missing); scratch database `p3c_proto` on 127.0.0.1:56330 (dropped afterwards); `DATABASE_URL=... npm test` gave 190/190 passed (11 files); `npm run typecheck` exit 0; `swift test --package-path CompanionKit` 164 tests, 0 failures; root `swift test` 177 tests, 0 failures. Not run: simulators, `xcodebuild`.
