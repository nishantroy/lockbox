# R5 pairing v2: relay-delivered acceptance and one-tap confirm

Status: **planned 2026-10-02; not started.** It follows the pairing-links slice: the `phone-lockbox-companion` URL scheme, invite-link routing, Copy link and the `PhoneLockboxUITests` target.

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
