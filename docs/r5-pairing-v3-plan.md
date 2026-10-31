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
