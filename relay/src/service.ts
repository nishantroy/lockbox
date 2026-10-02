// Port of `DurableRelayService.submit` (CompanionRelayService/Sources/CompanionRelayService/DurableRelay.swift):
// resolve+lock the owner partition, replay an idempotent operationID from its
// committed receipt, otherwise authorize, check `expectedRevision` (when the
// client supplied one), run the reducer, and commit the new state and a
// durable per-operation receipt in one transaction. Fails closed: any error
// after the transaction begins rolls the whole mutation back.
//
// Wire format: `operation.body` is the raw per-kind payload (no
// DurableOperationEnvelope wrapper) and `operation.expectedRevision` is used
// directly -- see protocol.ts's "Wire format note" for why.

import type pg from "pg";
import {
  decodeSignedOperation,
  verifySignedOperationSignature,
  decodeInboxQuery,
  type SignedOperation,
  type RelayResult,
  type RelayResponse,
  type InboxResponse,
  type TrustedRequest,
  type Pairing,
  type RelationshipConsent,
  type Approval,
  encodeRelayResult,
  decodeInvitation,
  decodeRelationshipConsent,
  decodePairingAcceptance,
  decodePairing,
  decodeActiveSession,
  decodeTrustedRequest,
  decodeApproval,
  decodeApprovalVerification,
  MAX_RAW_BODY_BYTES
} from "./protocol.js";
import { relayError, RelayError } from "./errors.js";
import { emptyLedger, type Ledger } from "./ledger.js";
import { authorize, reduce, chargeRateLimit } from "./reducer.js";
import {
  getPool,
  lockOwnerRow,
  saveOwnerRow,
  findOperation,
  insertOperation,
  resolveOwnerForPairing,
  recordApproverPairing,
  ownersForApprover,
  readOwnerLedger,
  withTransaction,
  upsertRetentionMarkers,
  chargeGlobalRateLimits,
  GLOBAL_RATE_LIMIT_WINDOW_SECONDS,
  GLOBAL_RATE_LIMIT_MAX,
  AmbiguousOwnerError,
  OwnerRowConflictError,
  PairingRoutingConflictError,
  type StoredOperation
} from "./db.js";
import { canonicalFramed, digest, COMPANION_VERSION } from "./canonical.js";

/** 5-minute freshness window for an inbox query that supplies `issuedAt` (see `decodeInboxQuery`). */
const INBOX_FRESHNESS_WINDOW_SECONDS = 5 * 60;

/** Builds the global rate-limit subjects for one request: always the signer identity, plus the client IP when the HTTP layer resolved one (see handlers.ts). */
function rateLimitSubjects(signerIdentityID: string, clientIP: string | null): string[] {
  const subjects = [`signer:${signerIdentityID}`];
  if (clientIP) subjects.push(`ip:${clientIP}`);
  return subjects;
}

/**
 * Canonical root of *one owner's* ledger state only (never the whole
 * database -- see PostgreSQLDurableStoreContract's
 * `canonicalStateRoot()` in CompanionRelayService/DurableStore.swift for the
 * anti-pattern this deliberately avoids: hashing every owner partition would
 * make one owner's write change every other owner's reported root, and a
 * client would see false "conflicting root" rejections on its own,
 * unrelated, unchanged ledger). This TS-internal root does not need to match
 * that Swift function's byte layout (see canonical.ts's header comment); it
 * only needs to be a deterministic, collision-resistant function of exactly
 * this owner's ledger + revision, so THAT owner's client can anchor
 * `(revision, stateRoot)` and detect a fork/rollback of THEIR OWN history.
 */
export function computeStateRoot(ledger: Ledger, revision: number): Buffer {
  const text = JSON.stringify(ledger, (_key, value) => (Buffer.isBuffer(value) ? value.toString("base64") : value));
  return digest(canonicalFramed(`${COMPANION_VERSION}.owner-state-root.v1`, [Buffer.from(String(revision)), Buffer.from(text, "utf8")]));
}

function resultKind(result: RelayResult): string {
  return result.kind;
}

/** Determines which owner partition a *decoded* operation targets, before any transaction begins. */
async function resolveOwner(op: SignedOperation): Promise<{ ownerID: string } | null> {
  if (op.signer.role === "owner") return { ownerID: op.signer.identityID };
  // Approver-signed kinds embed the owner directly except "approval", which
  // must be resolved via the pairing it targets (see migrations/001_init.sql).
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(op.body.toString("utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
  switch (op.kind) {
    case "accept": {
      const acceptance = parsed.acceptance as { owner?: { identityID?: unknown } } | undefined;
      const ownerID = acceptance?.owner?.identityID;
      return typeof ownerID === "string" ? { ownerID } : null;
    }
    case "consent": {
      const ownerID = (parsed.owner as { identityID?: unknown } | undefined)?.identityID;
      return typeof ownerID === "string" ? { ownerID } : null;
    }
    case "approval": {
      const pairingID = parsed.pairingID;
      if (typeof pairingID !== "string") return null;
      const ownerID = await resolveOwnerForPairing(getPool(), pairingID);
      return ownerID ? { ownerID } : null;
    }
    default:
      return null;
  }
}

interface TransactionOutcome {
  response: RelayResponse;
  /** True when the committed disposition is `rejectedExpiredRequest`: the
   * state change (terminal expiry) and receipt were committed, but the
   * caller must still see a terminal `expired` error, not a success. */
  surfaceExpired: boolean;
}

export async function submitOperation(rawBody: Buffer, now: number = nowSeconds(), clientIP: string | null = null): Promise<RelayResponse> {
  if (rawBody.length > MAX_RAW_BODY_BYTES) throw relayError("malformed");
  let operation: SignedOperation;
  try {
    const parsedBody = safeJSONParse(rawBody);
    operation = decodeSignedOperation(parsedBody);
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (!verifySignedOperationSignature(operation)) throw relayError("invalid_signature");

  const pool = getPool();
  // Global, DB-backed rate limit charged *before* any owner partition is
  // resolved or locked (P2: "count failed attempts and inbox fetches, and
  // bound approver-signed ops aimed at arbitrary owners"), keyed by both the
  // signer identity and (when the HTTP layer resolved one) the client IP --
  // every listed subject is charged unconditionally and the request is
  // allowed only if all of them are still within budget, so flooding from
  // many identities behind one IP still bounds that IP, and vice versa.
  // Unlike src/reducer.ts's `chargeRateLimit` (scoped to one already-open
  // owner transaction), this also bounds e.g. a flood of `ack`s from fresh
  // random identities, each of which would otherwise unconditionally create
  // a new `companion_owner` row before any per-owner limiter ever runs.
  const allowed = await chargeGlobalRateLimits(pool, rateLimitSubjects(operation.signer.identityID, clientIP), now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);
  if (!allowed) throw relayError("rate_limited");

  const resolved = await resolveOwner(operation);
  if (!resolved) throw relayError("unauthorized");

  const bodyDigest = digest(operation.body);

  const outcome = await withTransaction(pool, async (client): Promise<TransactionOutcome> => {
    const ownerIdentity = operation.signer.role === "owner" ? operation.signer : await ownerIdentityFor(client, resolved.ownerID);
    if (!ownerIdentity) throw relayError("unknown_owner");

    let ownerRow;
    try {
      ownerRow = await lockOwnerRow(client, ownerIdentity, emptyLedger, computeStateRoot);
    } catch (error) {
      if (error instanceof AmbiguousOwnerError) throw relayError("unauthorized");
      throw error;
    }
    // Fail closed if the stored root doesn't verify against the loaded state
    // (docs/r5-relay-plan.md: "Fail closed if the stored root doesn't
    // verify"), e.g. after any out-of-band edit to the `state`/`revision`
    // columns. This indicates the durable record may itself be corrupt, not
    // that the caller's request was malformed, so it is a 500-class error.
    if (!computeStateRoot(ownerRow.ledger, ownerRow.revision).equals(ownerRow.storedStateRoot)) {
      throw relayError("integrity_error");
    }

    const prior = await findOperation(client, ownerRow.ownerID, operation.operationID);
    if (prior) {
      if (
        prior.signerIdentityID !== operation.signer.identityID ||
        prior.kind !== operation.kind ||
        !prior.bodyDigest.equals(bodyDigest) ||
        prior.expectedRevision !== operation.expectedRevision
      ) {
        throw relayError("idempotency_conflict");
      }
      const result = prior.disposition === "rejectedExpiredRequest" ? ({ kind: "acknowledgement" } as const) : decodeStoredResult(prior.responseKind, prior.responseBody);
      return {
        response: {
          operationID: prior.operationID,
          revision: prior.committedRevision,
          result,
          ownerIdentityID: ownerRow.ownerID,
          stateRoot: prior.stateRootAfter
        },
        surfaceExpired: prior.disposition === "rejectedExpiredRequest"
      };
    }

    authorize(operation, ownerRow.ledger.owner, ownerRow.ledger);
    // `expectedRevision` is optional on the wire (both the sync and async
    // Swift clients often send `null`, meaning "no optimistic check"); when
    // present it must still match the currently locked revision exactly.
    if (operation.expectedRevision !== null && operation.expectedRevision !== ownerRow.revision) {
      throw relayError("stale_revision");
    }
    chargeRateLimit(ownerRow.ledger, operation.signer.identityID, now);

    let reduced;
    try {
      reduced = reduce(operation.kind, operation.body, operation.signer, ownerRow.ledger.owner, ownerRow.ledger, now);
    } catch (error) {
      // A malformed/unparseable/null/non-object payload for this kind must
      // surface as 400 malformed, never leak out as an uncaught exception
      // that the HTTP layer would otherwise turn into a 500.
      throw error instanceof RelayError ? error : relayError("malformed");
    }
    if (ownerRow.revision >= Number.MAX_SAFE_INTEGER) throw relayError("revision_overflow");
    const committedRevision = ownerRow.revision + 1;

    if (reduced.result.kind === "pairing") {
      try {
        await recordApproverPairing(client, ownerRow.ownerID, reduced.result.value.pairingID, reduced.result.value.approver.identityID);
      } catch (error) {
        if (error instanceof PairingRoutingConflictError) throw relayError("pairing_conflict");
        throw error;
      }
    }
    if (reduced.result.kind === "verification") {
      // Patch in the committed revision the reducer could not know yet.
      const useID = reduced.result.value.useID;
      const record = ownerRow.ledger.approvalUses[useID];
      if (record) record.committedRevision = committedRevision;
    }

    const newStateRoot = computeStateRoot(ownerRow.ledger, committedRevision);
    await saveOwnerRowOrConflict(client, ownerRow.ownerID, ownerRow.revision, committedRevision, ownerRow.ledger, newStateRoot);

    const encodedResult = encodeRelayResult(reduced.result);
    const responseBody = Buffer.from(JSON.stringify(encodedResult), "utf8");
    const stored: StoredOperation = {
      operationID: operation.operationID,
      ownerID: ownerRow.ownerID,
      kind: operation.kind,
      signerIdentityID: operation.signer.identityID,
      signerRole: operation.signer.role,
      signerPublicKey: operation.signer.publicKey,
      expectedRevision: operation.expectedRevision,
      bodyDigest,
      signedOperation: Buffer.from(JSON.stringify(encodeOperationForStorage(operation)), "utf8"),
      responseKind: resultKind(reduced.result),
      responseBody,
      responseDigest: digest(responseBody),
      disposition: reduced.rejectedExpired ? "rejectedExpiredRequest" : "accepted",
      stateRootAfter: newStateRoot,
      committedRevision,
      committedAt: now
    };
    await insertOperation(client, stored);
    await recordTerminalMarkers(client, ownerRow.ownerID, ownerRow.ledger, now);

    return {
      response: {
        operationID: operation.operationID,
        revision: committedRevision,
        result: reduced.result,
        ownerIdentityID: ownerRow.ownerID,
        stateRoot: newStateRoot
      },
      surfaceExpired: reduced.rejectedExpired
    };
  });

  // The transaction above has already committed by this point (withTransaction
  // issues COMMIT before returning); only now do we surface a terminal
  // "expired" error for a rejectedExpiredRequest disposition, exactly
  // mirroring `DurableRelayService.submit`'s
  // `if committed.1 == .rejectedExpiredRequest { throw CompanionError.expired }`.
  if (outcome.surfaceExpired) throw relayError("expired");
  return outcome.response;
}

export async function fetchInboxOperation(rawBody: Buffer, now: number = nowSeconds(), clientIP: string | null = null): Promise<InboxResponse> {
  if (rawBody.length > MAX_RAW_BODY_BYTES) throw relayError("malformed");
  let operation: SignedOperation;
  try {
    operation = decodeSignedOperation(safeJSONParse(rawBody));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (operation.kind !== "inbox") throw relayError("malformed");
  if (!verifySignedOperationSignature(operation)) throw relayError("invalid_signature");

  const pool = getPool();
  const allowed = await chargeGlobalRateLimits(pool, rateLimitSubjects(operation.signer.identityID, clientIP), now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);
  if (!allowed) throw relayError("rate_limited");

  let query;
  try {
    query = decodeInboxQuery(safeJSONParse(operation.body));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (query.identityID !== operation.signer.identityID) throw relayError("unauthorized");
  // Inbox fetch otherwise has no freshness/replay protection at all (no
  // expiry, no nonce -- it is a read, not a state mutation). When the caller
  // supplies a signed `issuedAt`, enforce the same pattern every other
  // `issuedAt` field in this protocol uses: up to 60s of future clock skew,
  // and (per this fetch's own 5-minute freshness contract) no more than 5
  // minutes stale. `REQUIRE_FRESH_INBOX` defaults to *requiring* `issuedAt`
  // (both Swift clients always send it now) and rejects the legacy
  // `{"identityID":...}` form (key omitted, not null); set it to the exact
  // string `"false"` to explicitly allow the legacy form during a
  // transition/rollback.
  if (query.issuedAt !== undefined) {
    if (query.issuedAt > now + 60 || query.issuedAt < now - INBOX_FRESHNESS_WINDOW_SECONDS) throw relayError("expired");
  } else if (process.env.REQUIRE_FRESH_INBOX !== "false") {
    throw relayError("malformed");
  }

  const identityID = operation.signer.identityID;
  const requests: TrustedRequest[] = [];
  const pairings: Pairing[] = [];
  const consents: RelationshipConsent[] = [];
  // R5 Slice B2a (contract v1.2): populated only on an owner fetch of their
  // own ledger -- `undefined` (omitted from the wire body) for a helper/
  // approver fetch, same presence rule as `ownerAnchor` below. Unlike
  // `ownerAnchor`, an owner fetch always gets a (possibly empty) array, even
  // before any ledger row exists for them yet.
  let approvals: Approval[] | undefined;
  let maxRevision = 0;
  let ownerAnchor: { ownerIdentityID: string; stateRoot: Buffer } | undefined;

  if (operation.signer.role === "owner") {
    approvals = [];
    const row = await readOwnerLedger(pool, identityID);
    if (row) {
      maxRevision = row.revision;
      // Anchoring only makes sense for an owner reading their own single
      // ledger (contract item 4: "set ownerIdentityID and stateRoot only
      // when the signer is an owner fetching their own ledger"). Verified
      // against the stored column, fail-closed, the same way the mutation
      // path (`submitOperation`) verifies it, rather than only trusting a
      // fresh recomputation of the ledger just read.
      const freshRoot = computeStateRoot(row.ledger, row.revision);
      if (!freshRoot.equals(row.storedStateRoot)) throw relayError("integrity_error");
      ownerAnchor = { ownerIdentityID: row.ownerID, stateRoot: freshRoot };
      for (const record of Object.values(row.ledger.requests)) {
        const effective = applyExpiry(record.request, row.ledger, now);
        requests.push(effective);
        // The relay-stored accepted approval for this request, included
        // only while the request still reads as approved, or once it has a
        // recorded use (natural end can later flip an already-used
        // request's status away from "approved" -- the approval must still
        // be deliverable so a client mid-replay or showing "used" history
        // can see it; see `use` in reducer.ts and the B2a plan's item 1).
        const accepted = findAcceptedApproval(row.ledger, record.request.requestID);
        if (accepted) {
          const hasRecordedUse = Object.values(row.ledger.approvalUses).some((u) => u.requestID === record.request.requestID);
          if (effective.status === "approved" || hasRecordedUse) approvals.push(accepted);
        }
      }
      for (const record of Object.values(row.ledger.pairings)) pairings.push(record.pairing);
      for (const consent of Object.values(row.ledger.relationshipConsents)) consents.push(consent);
    }
  } else {
    // A pure helper/approver inbox spans every owner they are paired with;
    // there is no single owner to anchor on, so ownerAnchor stays undefined
    // and both `ownerIdentityID`/`stateRoot` are omitted from the response.
    const ownerIDs = await ownersForApprover(pool, identityID);
    for (const ownerID of ownerIDs) {
      const row = await readOwnerLedger(pool, ownerID);
      if (!row) continue;
      maxRevision = Math.max(maxRevision, row.revision);
      for (const record of Object.values(row.ledger.requests)) {
        if (record.request.targetedApproverIDs.includes(identityID)) requests.push(applyExpiry(record.request, row.ledger, now));
      }
      for (const record of Object.values(row.ledger.pairings)) {
        if (record.pairing.approver.identityID === identityID) pairings.push(record.pairing);
      }
      for (const consent of Object.values(row.ledger.relationshipConsents)) {
        if (consent.approver.identityID === identityID) consents.push(consent);
      }
    }
  }

  requests.sort((a, b) => a.createdAt - b.createdAt);
  pairings.sort((a, b) => (a.pairingID < b.pairingID ? -1 : a.pairingID > b.pairingID ? 1 : 0));
  consents.sort((a, b) => (a.relationshipID < b.relationshipID ? -1 : a.relationshipID > b.relationshipID ? 1 : 0));
  approvals?.sort((a, b) => (a.approvalID < b.approvalID ? -1 : a.approvalID > b.approvalID ? 1 : 0));
  return {
    ownerIdentityID: ownerAnchor?.ownerIdentityID,
    stateRoot: ownerAnchor?.stateRoot,
    revision: maxRevision,
    requests,
    pairings,
    consents,
    approvals
  };
}

/**
 * The relay-stored approval that caused `requestID` to become approved, if
 * any (R5 Slice B2a). At most one approval can ever carry
 * `decision === "approved"` for a given request: the `"approval"` reducer
 * case only accepts a submission while the request's status is still
 * `"pending"`, and the first accepted approval flips status to `"approved"`,
 * which blocks every later approval for that request (approve or decline) --
 * see reducer.ts's `"approval"` case. Mirrors
 * `InMemoryCompanionRelay.acceptedApproval(forRequestID:)`.
 */
function findAcceptedApproval(ledger: Ledger, requestID: string): Approval | undefined {
  for (const record of Object.values(ledger.approvals)) {
    if (record.approval.requestID === requestID && record.approval.decision === "approved") return record.approval;
  }
  return undefined;
}

function applyExpiry(request: TrustedRequest, ledger: Ledger, now: number): TrustedRequest {
  if (request.status === "cancelled" || request.status === "declined" || request.status === "expired") return request;
  const session = ledger.sessions[request.sessionID]?.session;
  const sessionEnded = session ? now >= session.endsAt : false;
  if (now >= request.expiresAt || sessionEnded) return { ...request, status: "expired" };
  return request;
}

async function ownerIdentityFor(client: pg.PoolClient, ownerID: string) {
  const row = await readOwnerLedger(client, ownerID);
  return row?.ledger.owner ?? null;
}

async function saveOwnerRowOrConflict(client: pg.PoolClient, ownerID: string, previousRevision: number, newRevision: number, ledger: Ledger, stateRoot: Buffer) {
  try {
    await saveOwnerRow(client, ownerID, previousRevision, newRevision, ledger, stateRoot);
  } catch (error) {
    if (error instanceof OwnerRowConflictError) throw relayError("stale_revision");
    throw error;
  }
}

function decodeStoredResult(kind: string, body: Buffer): RelayResult {
  const parsed = JSON.parse(body.toString("utf8"));
  // The stored response body is exactly `encodeRelayResult(...)`'s output
  // (`{ "<kind>": { "_0": <value> } }`, or `{ "acknowledgement": {} }`).
  // Re-decode the inner value through the same typed decoder used for a
  // freshly-submitted operation, so a replayed idempotent response has
  // identical Buffer/Date-shaped fields to a fresh one (not raw
  // base64/number wire values), and so it is independently validated rather
  // than blindly trusted.
  switch (kind) {
    case "acknowledgement":
      return { kind: "acknowledgement" };
    case "invitation":
      return { kind: "invitation", value: decodeInvitation(parsed.invitation._0) };
    case "consent":
      return { kind: "consent", value: decodeRelationshipConsent(parsed.consent._0) };
    case "acceptance":
      return { kind: "acceptance", value: decodePairingAcceptance(parsed.acceptance._0) };
    case "pairing":
      return { kind: "pairing", value: decodePairing(parsed.pairing._0) };
    case "session":
      return { kind: "session", value: decodeActiveSession(parsed.session._0) };
    case "request":
      return { kind: "request", value: decodeTrustedRequest(parsed.request._0) };
    case "approval":
      return { kind: "approval", value: decodeApproval(parsed.approval._0) };
    case "verification":
      return { kind: "verification", value: decodeApprovalVerification(parsed.verification._0) };
    default:
      throw relayError("malformed");
  }
}

function encodeOperationForStorage(op: SignedOperation): object {
  return {
    operationID: op.operationID,
    expectedRevision: op.expectedRevision,
    kind: op.kind,
    signer: { identityID: op.signer.identityID, role: op.signer.role, publicKey: op.signer.publicKey.toString("base64") },
    body: op.body.toString("base64"),
    signature: op.signature.toString("base64")
  };
}

async function recordTerminalMarkers(client: pg.PoolClient, ownerID: string, ledger: Ledger, now: number): Promise<void> {
  const markers: Array<{ recordKind: string; recordID: string; terminalAt: number }> = [];
  for (const [requestID, record] of Object.entries(ledger.requests)) {
    const terminalAt = record.cancelledAt ?? record.expiredAt ?? (record.request.status === "declined" ? now : null);
    if (terminalAt !== null) markers.push({ recordKind: "request", recordID: requestID, terminalAt });
  }
  for (const [pairingID, record] of Object.entries(ledger.pairings)) {
    if (record.revokedAt !== null) markers.push({ recordKind: "pairing", recordID: pairingID, terminalAt: record.revokedAt });
  }
  if (markers.length > 0) await upsertRetentionMarkers(client, ownerID, markers);
}

function nowSeconds(): number {
  return Date.now() / 1000;
}

/**
 * `JSON.parse` throws a raw `SyntaxError` for unparseable input, which the
 * various decode functions (protocol.ts) never see because they always
 * receive an already-parsed value; without this wrapper, unparseable, empty,
 * or otherwise not-even-JSON bodies would escape as an uncaught exception
 * and surface as a 500 rather than a 400 `malformed`. Every call site here
 * re-wraps a non-`RelayError` catch into `malformed`, so this exists mainly
 * to give unparseable JSON the same treatment before decoding even starts.
 */
function safeJSONParse(data: Buffer): unknown {
  try {
    return JSON.parse(data.toString("utf8"));
  } catch {
    throw relayError("malformed");
  }
}
