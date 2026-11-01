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
  decodePushTokenRegistration,
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
  type Invitation,
  type SignedAcceptance,
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
  globalRateLimitMax,
  rateLimitMax,
  AmbiguousOwnerError,
  InviteTokenConflictError,
  recordInviteToken,
  consumeInviteToken,
  findInviteToken,
  OwnerRowConflictError,
  PairingRoutingConflictError,
  type StoredOperation
} from "./db.js";
import { dispatchPush, type PushNotification } from "./apns.js";
import { upsertPushToken, deletePushTokensForEnvironment } from "./push-store.js";
import { canonicalFramed, digest, COMPANION_VERSION, isWellFormedLookupKey, fromBase64url } from "./canonical.js";
import { timingSafeEqual } from "node:crypto";

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
  /** Wake-up banners to send after commit; empty for replays, failures and rejected-expired outcomes. */
  notifications: PushNotification[];
}

const REQUEST_FALLBACK_TITLE = "Someone you help";
const ANSWER_FALLBACK_TITLE = "Your trusted person";

function pushTitle(name: string | undefined, fallback: string): string {
  return name !== undefined && name.trim() !== "" ? name : fallback;
}

/**
 * Recipients and banner text for a *freshly committed* operation, computed from
 * the committed ledger (docs/r5-apns-plan.md):
 * - owner "request" -> every approver the request is addressed to (title: the
 *   owner name signed into that approver's pairing)
 * - approver "approval" approved/declined -> the owner only (title: the
 *   approver name signed into the pairing the approval is bound to)
 * - approver "accept" -> the owner only (title: the approver's signed name)
 * Everything else (revocations, expiries, natural end, ...) sends nothing.
 */
function pushPlan(operation: SignedOperation, result: RelayResult, ledger: Ledger, ownerID: string, priorStatuses: Record<string, string> = {}): PushNotification[] {
  if (operation.kind === "request" && result.kind === "request") {
    const request = result.value;
    if (request.status !== "pending") return [];
    return request.targetedApproverIDs.map((approverID) => {
      const binding = request.targetBindings.find((b) => b.approverIdentityID === approverID);
      const pairing = binding ? ledger.pairings[binding.pairingID]?.pairing : undefined;
      return { identityID: approverID, message: { title: pushTitle(pairing?.ownerDisplayName, REQUEST_FALLBACK_TITLE), body: "Asks to end their lock early.", kind: "request" as const } };
    });
  }
  if (operation.kind === "approval" && result.kind === "approval") {
    const approval = result.value;
    const name = pushTitle(ledger.pairings[approval.pairingID]?.pairing.approverDisplayName, ANSWER_FALLBACK_TITLE);
    // Already answered "approved" before this operation: nothing new to say.
    if (priorStatuses[approval.requestID] === "approved") return [];
    const status = ledger.requests[approval.requestID]?.request.status;
    if (approval.decision === "approved") return [{ identityID: ownerID, message: { title: name, body: "Approved ending your lock early.", kind: "answer" } }];
    if (approval.decision === "declined") {
      // Only the committed status says whether the owner is truly declined.
      if (status === "pending") return [{ identityID: ownerID, message: { title: name, body: "Declined. Others you asked can still answer.", kind: "answer" } }];
      if (status === "declined") return [{ identityID: ownerID, message: { title: name, body: "Declined your request.", kind: "answer" } }];
    }
    return [];
  }
  if (operation.kind === "accept" && result.kind === "pairing") {
    return [{ identityID: ownerID, message: { title: pushTitle(result.value.approverDisplayName, ANSWER_FALLBACK_TITLE), body: "Joined as your trusted person.", kind: "joined" } }];
  }
  return [];
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
  const allowed = await chargeGlobalRateLimits(pool, rateLimitSubjects(operation.signer.identityID, clientIP), now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, globalRateLimitMax());
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
      // R5 Slice B2a review fix (P1-1): return the owner's row-locked,
      // just-verified CURRENT (revision, stateRoot) here, not
      // `prior.committedRevision`/`prior.stateRootAfter` (the values at the
      // time this operation first committed). Between that first commit and
      // a later replay, the owner's revision can advance for unrelated
      // reasons (another mutation, a retention purge), so the historical
      // pair can be strictly behind an anchor this device already accepted
      // from an intervening response -- `RollbackAnchor.accept` would then
      // reject this *correct, idempotent* replay as a regression
      // (`staleRevision`), which a B2c crash-recovery retry of "use" could
      // never clear. `RelayResponse.stateRoot` is documented as "the
      // canonical root *for `revision`*", not "the root this specific
      // operation produced", so substituting the current verified pair for
      // an unchanged `result` is within contract, not a special case.
      //
      // R5 Slice B2a review fix (N1, privacy): only an OWNER-signed replay
      // gets this substitution. The replay path above intentionally never
      // calls `authorize()` (a lost acknowledgement must return its
      // original result even after e.g. a consent revoke would now reject
      // the same operation), so a non-owner (approver/helper) signer who
      // simply re-sends one of their own old operations (e.g. "approval")
      // must not be able to read the owner's CURRENT revision/state root
      // off that replay -- that would leak the owner's current activity
      // timing (including after this exact approver's own pairing has
      // since been revoked) through a request that looks, and is
      // authorized as, entirely inert. A non-owner signer's replay keeps
      // the historical `prior.committedRevision`/`prior.stateRootAfter`
      // pair -- exactly what they already received the first time.
      const isOwnerSigned = operation.signer.role === "owner";
      return {
        response: {
          operationID: prior.operationID,
          revision: isOwnerSigned ? ownerRow.revision : prior.committedRevision,
          result,
          ownerIdentityID: ownerRow.ownerID,
          stateRoot: isOwnerSigned ? ownerRow.storedStateRoot : prior.stateRootAfter
        },
        surfaceExpired: prior.disposition === "rejectedExpiredRequest",
        notifications: []
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

    // Request statuses before this operation, so a push can tell "already
    // approved" from a fresh answer (a second approver may still answer).
    const priorStatuses: Record<string, string> = {};
    if (operation.kind === "approval") {
      for (const [id, record] of Object.entries(ownerRow.ledger.requests)) priorStatuses[id] = record.request.status;
    }

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
    if (operation.kind === "invite" && reduced.result.kind === "invitation") {
      // Pairing v3: index the invite by its token hash in the same transaction.
      const payload = reduced.result.value.payload;
      try {
        await recordInviteToken(client, payload.lookupKey, ownerRow.ownerID, payload.inviteID, payload.expiresAt);
      } catch (error) {
        if (error instanceof InviteTokenConflictError) throw relayError("replay");
        throw error;
      }
    }
    if (operation.kind === "accept" && reduced.result.kind === "pairing") {
      // Pairing v3: the invite is consumed; its lookup key must stop resolving
      // but stays as a tombstone until it expires (no re-registration).
      const consumedInviteID = (JSON.parse(operation.body.toString("utf8")) as { acceptance: { inviteID: string } }).acceptance.inviteID;
      await consumeInviteToken(client, ownerRow.ownerID, consumedInviteID, now);
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
      surfaceExpired: reduced.rejectedExpired,
      notifications: reduced.rejectedExpired ? [] : pushPlan(operation, reduced.result, ownerRow.ledger, ownerRow.ownerID, priorStatuses)
    };
  });

  // Wake-up push, strictly after COMMIT: never inside the transaction, never
  // able to change the result (dispatchPush swallows every error and enforces
  // a 3 s total budget). Awaited because the host may freeze the function once
  // the response is sent.
  await dispatchPush(pool, outcome.notifications);

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
  const allowed = await chargeGlobalRateLimits(pool, rateLimitSubjects(operation.signer.identityID, clientIP), now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, globalRateLimitMax());
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
  // Pairing v3 (contract v1.4): same presence rule as `approvals`.
  let acceptances: SignedAcceptance[] | undefined;
  let maxRevision = 0;
  let ownerAnchor: { ownerIdentityID: string; stateRoot: Buffer } | undefined;

  if (operation.signer.role === "owner") {
    approvals = [];
    acceptances = [];
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
      for (const record of Object.values(row.ledger.pairings)) {
        pairings.push(record.pairing);
        if (record.acceptance) acceptances.push(record.acceptance);
      }
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
  acceptances?.sort((a, b) => (a.acceptance.acceptanceID < b.acceptance.acceptanceID ? -1 : a.acceptance.acceptanceID > b.acceptance.acceptanceID ? 1 : 0));
  approvals?.sort((a, b) => (a.approvalID < b.approvalID ? -1 : a.approvalID > b.approvalID ? 1 : 0));
  return {
    ownerIdentityID: ownerAnchor?.ownerIdentityID,
    stateRoot: ownerAnchor?.stateRoot,
    revision: maxRevision,
    requests,
    pairings,
    consents,
    approvals,
    acceptances
  };
}

/**
 * `POST /v1/push-token` (docs/r5-apns-plan.md "Wire contract"): a signed
 * `push_token` operation registers (or, with `token: null`, unregisters) an
 * APNs device token for the signing identity. Same decode -> signature ->
 * rate limit -> body decode -> identity check -> freshness order as the inbox.
 */
export async function registerPushToken(rawBody: Buffer, now: number = nowSeconds(), clientIP: string | null = null): Promise<void> {
  if (rawBody.length > MAX_RAW_BODY_BYTES) throw relayError("malformed");
  let operation: SignedOperation;
  try {
    operation = decodeSignedOperation(safeJSONParse(rawBody));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (operation.kind !== "push_token" || operation.expectedRevision !== null) throw relayError("malformed");
  if (!verifySignedOperationSignature(operation)) throw relayError("invalid_signature");

  const pool = getPool();
  const allowed = await chargeGlobalRateLimits(pool, rateLimitSubjects(operation.signer.identityID, clientIP), now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, globalRateLimitMax());
  if (!allowed) throw relayError("rate_limited");

  let registration;
  try {
    registration = decodePushTokenRegistration(safeJSONParse(operation.body));
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (registration.identityID !== operation.signer.identityID) throw relayError("unauthorized");
  if (registration.issuedAt > now + 60 || registration.issuedAt < now - INBOX_FRESHNESS_WINDOW_SECONDS) throw relayError("expired");

  if (registration.token === null) await deletePushTokensForEnvironment(pool, registration.identityID, registration.environment);
  else await upsertPushToken(pool, registration.identityID, registration.token, registration.environment, now);
}

/** Lookups are unauthenticated, so they get their own, tighter budget per client IP than signed operations (GLOBAL_RATE_LIMIT_MAX). */
export const LOOKUP_RATE_LIMIT_MAX = 20;
export const LOOKUP_RATE_LIMIT_WINDOW_SECONDS = 60;
const MAX_LOOKUP_BODY_BYTES = 1_024;

/**
 * Pairing v3: `POST /v1/invite/lookup {"lookupKey": "<43 base64url chars>"}`.
 * The lookup key is `H("invite-lookup", token)`; the token itself never
 * reaches the relay. Unauthenticated (the friend has no identity yet) but rate
 * limited per client IP. Returns the owner-signed invitation while it is
 * unexpired and unused, and nothing else: an unknown key, an expired invite
 * and a consumed invite are one indistinguishable `not_found`. The key found
 * is compared again in constant time against the one signed inside the
 * owner's invitation.
 */
export async function lookupInvite(rawBody: Buffer, now: number = nowSeconds(), clientIP: string | null = null): Promise<Invitation> {
  if (rawBody.length > MAX_LOOKUP_BODY_BYTES) throw relayError("malformed");
  const pool = getPool();
  // Charged before parsing so malformed/guessing traffic is bounded too. With
  // no resolvable client IP (not expected behind Vercel) all callers share one bucket.
  const allowed = await chargeGlobalRateLimits(pool, [`lookup-ip:${clientIP ?? "unknown"}`], now, LOOKUP_RATE_LIMIT_WINDOW_SECONDS, rateLimitMax(LOOKUP_RATE_LIMIT_MAX, "RELAY_LOOKUP_RATE_LIMIT_MAX"));
  if (!allowed) throw relayError("rate_limited");
  let encodedKey: unknown;
  try {
    encodedKey = (safeJSONParse(rawBody) as { lookupKey?: unknown } | null)?.lookupKey;
  } catch (error) {
    throw error instanceof RelayError ? error : relayError("malformed");
  }
  if (!isWellFormedLookupKey(encodedKey)) throw relayError("malformed");
  const lookupKey = fromBase64url(encodedKey);
  if (lookupKey.length !== 32) throw relayError("malformed");
  const row = await findInviteToken(pool, lookupKey);
  if (!row || row.consumed || row.expiresAt <= now || row.lookupKey.length !== lookupKey.length || !timingSafeEqual(row.lookupKey, lookupKey)) throw relayError("not_found");
  const ownerRow = await readOwnerLedger(pool, row.ownerID);
  const record = ownerRow?.ledger.invitations[row.inviteID];
  if (!record || record.consumedAt !== null || now >= record.invitation.payload.expiresAt) throw relayError("not_found");
  const signedKey = record.invitation.payload.lookupKey;
  if (!Buffer.isBuffer(signedKey) || signedKey.length !== lookupKey.length || !timingSafeEqual(signedKey, lookupKey)) throw relayError("not_found");
  return record.invitation;
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
