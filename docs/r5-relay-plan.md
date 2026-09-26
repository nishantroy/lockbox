# R5 relay build plan — local-first, Vercel-ready

Status: **approved by owner 2026-09-26; in progress.** This is an implementation plan, not evidence. Nothing here is deployed.

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
