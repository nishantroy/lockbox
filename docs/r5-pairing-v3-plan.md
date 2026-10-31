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
