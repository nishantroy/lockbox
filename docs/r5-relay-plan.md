# R5 relay build plan — local-first, Vercel-ready

Status: **Slices A and B1 integrated on `r5-relay` (2026-09-26); B2 and deployment not started.** Nothing here is deployed. See [integration results](#integration-results-2026-09-26).

## Owner decisions (2026-09-26)

- **Start R5 now.** Owner-reported build-15 R4 QA is recorded in [status and QA](status-and-qa.md). Accessibility review (R4.2) is deferred as lower priority, and the reachable manual/scheduled overlap case is not yet run. R5 proceeds by owner decision; these remain open R4 items and are not reclassified as passes.
- **Hosting:** prototype locally first. The eventual target is the **Vercel free (Hobby) tier** with Vercel Marketplace Postgres (Neon). Vercel has no Swift runtime, so the relay is written in **TypeScript** as Vercel-compatible functions; the existing Swift `CompanionRelayService` is the reference implementation for the port.
- **Retention:** finished records (terminal requests, approvals, revoked pairings/consent) are deleted **30 days** after they become terminal. Active pairings/consent persist until revoked. Replay markers are kept at least as long as the operation they protect remains valid.
- **Delegation:** Sonnet subagents build in isolated worktrees; Opus subagents review; the parent integrates (see `AGENTS.md`).

## Starting point (merged on `r5-relay`)

- `CompanionKit` (36 tests): Curve25519/Ed25519 device identities in Keychain, signed one-use invitations with six-digit verification, framed canonical signing (`CompanionCanonical.version = "PhoneLockbox.Companion.v1"`), bilateral per-pairing-epoch consent (`approveEarlyEnd`, `receiveRequests`; `mutualPact` and R6 scopes reserved/denied), exact-session one-of-N one-use approvals, `InMemoryCompanionRelay` authorization semantics, and the synchronous `CompanionTransport` (`submit`, `fetchInbox`) in `ProtocolModels.swift`.
- `CompanionRelayService` (18 tests): durable envelope (`operationID`, `expectedRevision`, payload), per-owner revisions, idempotent receipts, closed default-deny command allowlist, natural-end transitions and checkpoint/state-root semantics (`docs/companion-security.md`).
- Neither package is linked into the app. `PhoneLockbox/Companion/CompanionPrototype.swift` is a developer harness.

## Architecture

```
iPhone (owner)  ─┐   HTTPS JSON (signed operations)     ┌─ relay/api/v1/operations.ts
iPhone (friend) ─┴──────────────────────────────────────▶├─ relay/api/v1/inbox.ts
   CompanionKit + HTTPCompanionTransport                 └─ relay/api/v1/health.ts
                                                              │ reducer (TS port) + pg
                                                              ▼
                                                   Postgres (local Docker 56330 → Neon)
```

- **Server authority.** Postgres is the authoritative store. Each mutation runs in one transaction: lock the owner's ledger row (`SELECT … FOR UPDATE`), check `expectedRevision`, verify the signature and authorization, apply the reducer, append the signed operation record, advance the revision and store the new canonical state root. Fail closed if the stored root doesn't verify.
- **Independent monotonic anchor.** The owner's device is the independent checkpoint: after every accepted response it stores `(ownerRevision, stateRoot)` in the App Group and rejects any later response with a lower revision or a conflicting root for the same revision. This gives rollback/fork detection against the server without a second backend. A malicious server can still withhold service; that is an accepted limitation, since recovery and emergency access never depend on the relay.
- **Push is not state.** No APNs in this phase. Foreground inbox fetch is authoritative.

### HTTP API (v1)

All bodies are JSON as encoded by Swift `JSONEncoder` with `.sortedKeys`; binary fields are base64 (the Swift `Data` default). Maximum body size = `DurableRelayLimits.maxPayloadBytes` plus envelope overhead; larger bodies → 413.

| Endpoint | Body | Success | Errors |
| --- | --- | --- | --- |
| `POST /v1/operations` | one `SignedOperation` | `200` `RelayResponse` incl. new owner revision and state root | `400` invalid, `401` bad signature/unknown key, `403` unauthorized, `409` stale revision or idempotency conflict, `413`, `429` rate limited |
| `POST /v1/inbox` | a signed fetch `SignedOperation` (as `CompanionTransport.fetchInbox` expects) | `200` `InboxResponse` for the signer only | same as above |
| `GET /v1/health` | — | `200 {"ok":true}` with no data | — |

- Re-sending the same `operationID` with an identical body returns the stored response. The same ID with a different body returns `409`.
- On an idempotent replay signed by the **owner**, `revision`/`stateRoot` in the returned `RelayResponse` are the owner's ledger-locked **current** pair at the time of the replay, not the pair from when the operation first committed (R5 Slice B2a review fix, P1-1: this keeps a client's rollback anchor from rejecting a later, perfectly valid replay as a regression after the owner's revision has since advanced for an unrelated reason). On a replay signed by a **non-owner** (a helper/approver re-sending their own old operation), `revision`/`stateRoot` stay the historical commit-time pair instead, so a non-owner signer cannot read the owner's current activity off an otherwise-inert resend (review fix N1).
- Error bodies are `{ "error": "<code>" }` with codes mirroring `DurableRelayError`/relay errors. No echo of input, no stack traces.
- Never log request bodies, public keys or identifiers beyond an opaque request ID. There are no analytics.

## Slices and ownership

### Slice A — TypeScript relay (`relay/`) · Sonnet writer

Owns `relay/**` and a vector generator in `CompanionKit` (a new test or executable target only; no changes to existing CompanionKit sources).

1. **Scaffold:**
   - Node 20+, TypeScript strict, `vitest`, `pg`, Node `crypto` Ed25519 (no third-party crypto).
   - `relay/api/v1/*.ts` are Vercel Node functions using the Web `Request → Response` signature. `relay/src/**` holds the pure reducer, crypto, canonical encoding and the DB adapter.
   - `relay/scripts/dev-server.ts` serves the same handlers on **127.0.0.1:8002**, so local dev needs no Vercel CLI login.
   - `relay/docker-compose.yml` runs Postgres 16 on **127.0.0.1:56330**.
   - Scripts: `dev`, `db:start`, `db:stop`, `db:migrate`, `test`, `typecheck`, `retention:purge`.
   - Includes `.env.example` and a `vercel.json` with a daily retention cron (Hobby allows daily).
2. **Canonical parity:**
   - Port `CompanionCanonical` framing, domain separation and signed-field sets exactly.
   - Generate golden vectors from Swift into `relay/test/fixtures/` (keys, fields, canonical bytes, signatures, full `SignedOperation` JSON for every operation kind).
   - TS tests must verify every vector byte-for-byte and reject tampered, cross-domain and wrong-key variants.
3. **Reducer port:**
   - Port the authorization semantics of `InMemoryCompanionRelay` combined with the durability semantics of `CompanionRelayService`. This covers invitations, acceptance and confirmation, consent grant/accept/revoke with generations, requests with exact session/active-set/pairing bindings, one-of-N approval, decline, cancel, use, natural end, rate limits and the closed allowlist.
   - Every Swift test scenario in `CompanionKitTests` and `DurableRelayServiceTests` gets a vitest counterpart against real Postgres.
4. **Postgres:**
   - SQL migrations; per-owner ledger with a revision and state root; append-only signed operation log; replay/idempotency markers.
   - Add a concurrency test in which two parallel transactions race on one owner, and exactly one wins.
5. **Retention:**
   - The purge job deletes records 30 days after they become terminal and bounds replay markers.
   - Tests cover the boundary.

### Slice B1 — iOS transport and People tab · Sonnet writer

Owns `CompanionKit/Sources/CompanionKit/HTTPTransport.swift` (new), additive async transport API in CompanionKit, `PhoneLockbox/Companion/**`, `PhoneLockbox/Views/PeopleView.swift`, and `project.yml` (package link and `NSAllowsLocalNetworking` only).

1. **Transport:**
   - `HTTPCompanionTransport` implements the API above with `URLSession` async. Keep the synchronous protocol for the in-memory relay, or add an async sibling; do not break existing tests.
   - The base URL comes from a Developer setting, defaulting to `http://127.0.0.1:8002`; on a device it is set to the Mac's LAN address.
2. **Rollback anchor:** a per-owner `(revision, stateRoot)` store in the App Group that rejects regressions (see Architecture).
3. **People tab:**
   - Create and share an invite, accept one, and confirm the approver with the six-digit code.
   - Grant and accept `approveEarlyEnd` and `receiveRequests` per person; revoke.
   - Owner: request an early end for the **current exact session**.
   - Friend: inbox with approve and decline.
   - Foreground fetch on appear and on pull-to-refresh.
   - Label everything "Prototype — local relay". Companion-only use must not require Screen Time authorization.
4. **Tests:** transport encoding against Slice A's fixtures, anchor regression rejection, and a stub-server `URLProtocol` test for each status code.

B1 does **not** release any lock. An approved request is displayed as approved but unused.

### Slice B2 — approval consumption into the lock lifecycle · later, separate plan

After A and B1 are integrated and reviewed:

1. The owner device calls `use` on the approved request and receives the verified record.
2. It persists the exact-session terminal event before clearing policy, then releases only that session through the existing R3 release path.
3. Natural end wins races. Stale or late approvals are no-ops.

This touches the R2/R3 safety core and gets its own plan and an Opus high review.

## Review gates for this phase

- **Opus reviewer for Slice A:**
  - crypto and canonical parity
  - authorization/allowlist equivalence with Swift
  - transaction and race safety
  - privacy of logs and errors
  - retention
- **Opus reviewer for Slice B1:**
  - transport error handling
  - anchor correctness
  - People-tab consent UX and accessibility basics
  - no enforcement side effects
- **Parent integration:**
  - `swift test` for both packages
  - `npm test` and `npm run typecheck` in `relay/` against Docker Postgres
  - iOS simulator build
  - an end-to-end smoke run: two simulated identities pair, consent, request, approve and fetch over HTTP on port 8002

## Out of scope for this phase

Vercel deployment (needs the owner's account; the target is Hobby plus Neon), APNs, R6 notices and summaries, mutual pact, quorum beyond one-of-N, the independent key authority beyond the owner-device anchor, and B2 lifecycle release.

## Integration results (2026-09-26)

**Delegation actually used:**
- Slice A (relay) and Slice B1 (iOS) were built by Claude **Sonnet** subagents in isolated worktrees.
- Each slice was independently reviewed by a separate Claude **Opus** subagent. No Luna/Terra models were used.
  - B1 went through three fix rounds and was approved.
  - A went through two fix rounds and was approved with minor fixes. The final P2 round was applied, then verified by the parent's tests; it was not re-reviewed.

**Contract v1.3** (R5 pairing v2, `docs/r5-pairing-v2-plan.md`'s "Slice P2a", 2026-10-02; supersedes v1.1/v1.2 below where they differ): `/v1/inbox` additionally returns `pendingAcceptances` — every `ledger.pendingAcceptances` entry (as a verifiable `SignedAcceptance`, not the bare acceptance) whose invite exists, is unconsumed and has not expired. Same presence rule as `approvals`/`ownerIdentityID`: populated only on an owner fetch of their own ledger, omitted entirely on a helper/approver fetch. This replaces the owner typing a six-digit code read aloud by the friend (see the pairing v2 plan's "Owner decision"); `OwnerAcceptanceCheck` (CompanionKit) verifies an entry locally and derives the expected code before `confirm`. The wire contract itself did not change again for Slice P2b (2026-10-02): P2b is the app-side consumer (`CompanionCoordinator`/`PeopleView`) that actually removed the typed-code UI, the acceptance share-back, and now shows/confirms `pendingAcceptances` with one tap — see the pairing v2 plan's "Build results: P2a" and "Build results: P2b" for what shipped.

**Contract v1.2** added by Slice B2a (2026-10-02): `/v1/inbox` also returns `approvals` (owner-fetch only) — the relay-stored accepted `Approval` for each request in `requests` whose status is `approved`, or that has a recorded use. See `docs/r5-b2-plan.md`.

**Contract v1.1**, which supersedes the API table above where they differ:
- `/v1/inbox` also returns `pairings` and `consents` for pairings the signer is part of.
- `stateRoot` is per owner.
- `ownerIdentityID` on `/v1/operations` is the owner of the ledger that was mutated.
- An inbox response is anchored only when an owner fetches their own ledger.
- Raw `SignedOperation` with `expectedRevision: null` is accepted.
- Error codes are snake_case (`relay/test/fixtures/error-codes.json`).
- The inbox query signs `issuedAt` (seconds since 2001-01-01) inside a 5-minute window. It is required by default (`REQUIRE_FRESH_INBOX`).
- Consent mutations expire 24h after `issuedAt`.
- Retention purges advance the owner revision.

**Security properties added during review:**
- The client never trusts relay pairing or consent data blindly. Identities are field-locked, epochs and generations only move forward, and helper pairings are bound to a specific accepted invite.
- The confirm response must name the verified approver.
- Rollback anchors are keyed by normalized relay URL and owner, and enforced once established.
- `activeSetID` is derived from session IDs only.
- The relay rejects pairing-ID collisions across owners.
- Rate limits are DB-backed per signer and per IP.
- Maps use null prototypes and base64 decoding is strict.
- The stored root is verified on the mutation, inbox and purge paths.
- `CRON_SECRET` is compared in constant time.

**Parent validation on the merged branch:**
- `swift test --package-path CompanionKit`: 95 passed.
- `swift test --package-path CompanionRelayService`: 18 passed.
- Root `swift test`: 150 passed.
- Relay `npm run typecheck`, and `npm test` against Docker Postgres 16: 127 passed. The inbox vector is now captured from the real `CompanionClient`. CryptoKit Ed25519 signatures are randomized, so regenerated vectors differ only in signatures.
- `xcodegen generate` produced no diff, and the iOS simulator build succeeded.
- End-to-end smoke run: two fresh Swift identities using `AsyncCompanionClient` over HTTP to `127.0.0.1:8002`, with anchors enabled. The flow covered:
  1. health check
  2. invite, then accept
  3. confirm with a wrong code (rejected), then with the correct code
  4. the helper learns the pairing from an unanchored inbox
  5. consent from both sides, visible in the owner's anchored inbox
  6. the owner publishes an exact session and requests an early end
  7. the helper receives the request and approves; a duplicate approval is rejected
  8. the owner sees the request as approved
  9. the owner revokes, and the helper sees the pairing as revoked

  **All steps passed.** The script was a throwaway in the parent's scratch directory and is not committed.
- No physical-device run has happened. Vercel/Neon: see [Deployment](#deployment-2026-10-02).

**Known gaps:**
- Learning of `replace_pairing` (device replacement) is deferred to B2.
- The relay could fabricate one unconfirmed helper pairing per pending acceptance for up to 7 days, affecting the UI only. The fix is for the relay to return an owner-signed `PairingConfirmation`.
- The sync `CompanionClient.fetchInbox` still requires `ownerIdentityID`, so it fails against the relay for a pure helper inbox. It is used only with the in-memory relay; the app uses the async client.
- A consent that stays queued offline for more than 24h returns `expired` and must be re-signed. The UI should present this as "try again".
- `CompanionCoordinator` has no unit tests of its own; its merge and anchor logic is tested in CompanionKit.
- `vercel dev` has not been used; the deployed runtime (named exports, `/v1` rewrites, cron registration) was checked on the real deployment instead (see below). The cron has not yet fired.
- Postgres is pinned to `16.9-alpine`.

## Deployment (2026-10-02)

**Hosting:** a serverless host (a Vercel Hobby project).
- **Production URL:** `https://relay.example.com`. Per-deployment URLs sit behind Vercel Authentication by default.
- **Deploys:** CLI only (`cd relay && vercel deploy --prod`). The GitHub integration that `vercel link` connected automatically was disconnected, so pushes never deploy.
- **Uploads:** `relay/.vercelignore` excludes `.env*` files and tests.

**Database:** a managed Postgres (Neon, via the Vercel Marketplace).
- `DATABASE_URL` is the pooled (`-pooler`) host.
- The owner ran migrations 001–003 manually over `DATABASE_URL_UNPOOLED`.

**Production environment:**
- `PGPOOL_MAX=2`, `PGPOOL_IDLE_TIMEOUT_MS=5000`, `RETENTION_DAYS=30`.
- `CRON_SECRET`: a random 32-byte hex value, marked sensitive in Vercel and not recorded anywhere else.

**Deployed revision:** `r5-relay` at `74dbfca` (Slices A and B1, contract v1.1). B2a's owner-approval inbox change is **not** deployed yet.

**Parent checks against production:**
- `GET /v1/health` returns `200 {"ok":true}`.
- `vercel crons ls` lists `/api/cron/retention-purge` at `0 9 * * *`.
- The cron endpoint returns `401` with no bearer token or a wrong one.
- An empty `POST /v1/operations` returns `400 {"error":"malformed"}`.
- `tools/relay-smoke` (two throwaway in-memory identities, owner anchors enabled) passed all 17 steps: health, invite/accept, wrong then correct confirm, helper learns the pairing, bilateral consent in the anchored inbox, exact session plus early-end request, helper approval, duplicate approval rejected, owner sees the request approved, revoke seen by the helper.
  - The Sonnet builder ran it once locally and once against production.
  - The parent re-ran it against production.

**Still open:** a two-phone device run, the first natural cron execution, and redeploying after B2a/B2c.
