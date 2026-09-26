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
  type SignedOperation,
  type RelayResult,
  type RelayResponse,
  type InboxResponse,
  type TrustedRequest,
  type Pairing,
  type RelationshipConsent,
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
  AmbiguousOwnerError,
  OwnerRowConflictError,
  type StoredOperation
} from "./db.js";
import { canonicalFramed, digest, COMPANION_VERSION } from "./canonical.js";

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

export async function submitOperation(rawBody: Buffer): Promise<RelayResponse> {
  if (rawBody.length > MAX_RAW_BODY_BYTES) throw relayError("malformed");
  let operation: SignedOperation;
  try {
    operation = decodeSignedOperation(JSON.parse(rawBody.toString("utf8")));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (!verifySignedOperationSignature(operation)) throw relayError("invalid_signature");

  const resolved = await resolveOwner(operation);
  if (!resolved) throw relayError("unauthorized");

  const pool = getPool();
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
    // columns.
    if (!computeStateRoot(ownerRow.ledger, ownerRow.revision).equals(ownerRow.storedStateRoot)) {
      throw relayError("malformed");
    }

    const prior = await findOperation(client, ownerRow.ownerID, operation.operationID);
    if (prior) {
      if (prior.signerIdentityID !== operation.signer.identityID || prior.kind !== operation.kind || !prior.bodyDigest.equals(bodyDigest)) {
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
    const now = nowSeconds();
    chargeRateLimit(ownerRow.ledger, operation.signer.identityID, now);

    const reduced = reduce(operation.kind, operation.body, operation.signer, ownerRow.ledger.owner, ownerRow.ledger, now);
    const committedRevision = ownerRow.revision + 1;

    if (reduced.result.kind === "pairing") {
      await recordApproverPairing(client, ownerRow.ownerID, reduced.result.value.pairingID, reduced.result.value.approver.identityID);
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

export async function fetchInboxOperation(rawBody: Buffer): Promise<InboxResponse> {
  if (rawBody.length > MAX_RAW_BODY_BYTES) throw relayError("malformed");
  let operation: SignedOperation;
  try {
    operation = decodeSignedOperation(JSON.parse(rawBody.toString("utf8")));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (operation.kind !== "inbox") throw relayError("malformed");
  if (!verifySignedOperationSignature(operation)) throw relayError("invalid_signature");
  const query = JSON.parse(operation.body.toString("utf8")) as { identityID?: unknown };
  if (query.identityID !== operation.signer.identityID) throw relayError("unauthorized");

  const pool = getPool();
  const identityID = operation.signer.identityID;
  const requests: TrustedRequest[] = [];
  const pairings: Pairing[] = [];
  const consents: RelationshipConsent[] = [];
  let maxRevision = 0;
  const now = nowSeconds();
  let ownerAnchor: { ownerIdentityID: string; stateRoot: Buffer } | undefined;

  if (operation.signer.role === "owner") {
    const row = await readOwnerLedger(pool, identityID);
    if (row) {
      maxRevision = row.revision;
      // Anchoring only makes sense for an owner reading their own single
      // ledger (contract item 4: "set ownerIdentityID and stateRoot only
      // when the signer is an owner fetching their own ledger").
      ownerAnchor = { ownerIdentityID: row.ownerID, stateRoot: computeStateRoot(row.ledger, row.revision) };
      for (const record of Object.values(row.ledger.requests)) requests.push(applyExpiry(record.request, row.ledger, now));
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
  return {
    ownerIdentityID: ownerAnchor?.ownerIdentityID,
    stateRoot: ownerAnchor?.stateRoot,
    revision: maxRevision,
    requests,
    pairings,
    consents
  };
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
