// Port of `DurableProtocolReducer.apply` and its authorization helpers
// (CompanionRelayService/Sources/CompanionRelayService/DurableReducer.swift),
// combined with the closed-allowlist policy from
// `DurableAuthorizationPolicy` (DurableRelay.swift). This is a pure function:
// `(ledger, operation, now) -> { result, ledger }`. All I/O (locking,
// idempotency, persistence) lives in service.ts/db.ts.

import {
  type DeviceIdentity,
  type RelayResult,
  decodeInvitation,
  verifyInvitationSignature,
  decodeSignedAcceptance,
  verifySignedAcceptanceSignature,
  decodeSignedConfirmation,
  verifySignedConfirmationSignature,
  decodeConsentMutation,
  decodeActiveSession,
  decodeTrustedRequest,
  decodeApproval,
  verifyApprovalSignature,
  decodeApprovalUse,
  decodeRequestReference,
  decodeNaturalEnd,
  decodePairingReference,
  decodePairingReplacement,
  verifyPairingReplacementSignature,
  identitiesEqual,
  consentAuthorizes,
  sessionIsActive,
  requestBinding,
  approvalsEqual,
  isValidIdentifier
} from "./protocol.js";
import type { SignedOperation } from "./protocol.js";
import { canonicalBytes, digest, base64url, COMPANION_VERSION, pairingVerificationCode } from "./canonical.js";
import { normalizePendingAcceptance, type Ledger } from "./ledger.js";
import { relayError, type RelayErrorCode } from "./errors.js";

/**
 * Thrown for a *terminal command rejection* that still commits a state
 * transition (the request is expired in the same transaction). Mirrors
 * `DurableProtocolTransitionError.requestExpired`: the caller must persist
 * the ledger mutation this throw leaves behind, then surface `expired`.
 */
export class RequestExpiredTransition extends Error {
  constructor() {
    super("request_expired_transition");
  }
}

const R5_SCOPE_APPROVE_EARLY_END = "approveEarlyEnd" as const;
const R5_SCOPE_RECEIVE_REQUESTS = "receiveRequests" as const;

/** Kinds an owner may sign; mirrors DurableStore.swift's `ownerSignedKinds`. */
export const OWNER_ONLY_KINDS = new Set([
  "ack",
  "invite",
  "confirm",
  "consent",
  "session",
  "request",
  "use",
  "cancel",
  "natural_end",
  "revoke",
  "replace_pairing"
]);

/** Kinds a trusted approver may sign; mirrors DurableStore.swift's `approverSignedKinds`. */
export const APPROVER_ONLY_KINDS = new Set(["accept", "approval"]);

/** `consent` may be signed by either side depending on the mutation's action. */
export const EITHER_SIGNER_KINDS = new Set(["consent"]);

export const MODELED_KINDS = new Set([...OWNER_ONLY_KINDS, ...APPROVER_ONLY_KINDS, ...EITHER_SIGNER_KINDS]);

function fail(code: RelayErrorCode): never {
  throw relayError(code);
}

/**
 * Port of `checkedIncrement`/`checkedPairingEpoch`
 * (CompanionKit/Sources/CompanionKit/CompanionKit.swift,
 * CompanionRelayService/Sources/CompanionRelayService/DurableOperation.swift):
 * every durable epoch/generation/revision counter is incremented through a
 * checked helper rather than a raw `+ 1`, so an exhausted counter fails
 * closed (`revision_overflow`) instead of silently wrapping or, in
 * JavaScript's case, silently losing precision past `Number.MAX_SAFE_INTEGER`.
 */
export function checkedIncrement(value: number): number {
  if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) fail("revision_overflow");
  return value + 1;
}

/** Consent mutations have no independent expiry field, unlike invites/sessions/requests, so a captured old signed mutation must be rejected purely by age -- see the "consent" case below and docs in retention.ts. */
export const CONSENT_MAX_AGE_SECONDS = 24 * 60 * 60;

/**
 * Closed default-deny authorization gate, ported from
 * `DurableAuthorizationPolicy.authorize` / `.ownerAndActivePairing`. Runs
 * before the reducer mutates any state. An unmodeled kind, or a signer that
 * is neither the owner nor an actively-paired trusted approver, is rejected
 * regardless of any caller-supplied allowlist.
 */
export function authorize(operation: SignedOperation, owner: DeviceIdentity, ledger: Ledger): void {
  if (!MODELED_KINDS.has(operation.kind)) fail("unsupported_operation");
  if (operation.kind === "ack") {
    if (!identitiesEqual(operation.signer, owner)) {
      fail(operation.signer.role === "trustedApprover" ? "unsupported_operation" : "unauthorized");
    }
    return;
  }
  const isOwner = identitiesEqual(operation.signer, owner);
  if (isOwner) {
    if (!OWNER_ONLY_KINDS.has(operation.kind)) fail("unauthorized");
    return;
  }
  if (!(APPROVER_ONLY_KINDS.has(operation.kind) || EITHER_SIGNER_KINDS.has(operation.kind))) fail("unauthorized");
  if (operation.signer.role !== "trustedApprover") fail("unauthorized");
  // Deliberately does *not* also require an already-active pairing here:
  // "accept" is signed by a trusted approver *before* any pairing exists
  // (confirm is what creates it), matching
  // `InMemoryCompanionRelay.apply`'s "accept" case, which checks only
  // `operation.signer == signed.acceptance.approver`. Kinds that do require
  // an active pairing/consent (approval, consent, use, ...) enforce that
  // precisely and contextually inside their own reducer case below (e.g. the
  // "approval" case's `pairing.state !== 'active'` check), so a second,
  // coarser pairing check here would be redundant and, for "accept", wrong.
}

// Port of `InMemoryCompanionRelay.charge(_:)` / `CompanionLimits`
// (CompanionKit/Sources/CompanionKit/{InMemoryRelay,CompanionKit}.swift): a
// sliding-window per-signer rate limit, charged once per accepted-for-processing
// operation before the reducer runs. A rate-limited attempt is not recorded
// (no operation row, no revision advance), matching the Swift reference.
export const RATE_LIMIT_MAX_OPERATIONS = 30;
export const RATE_LIMIT_WINDOW_SECONDS = 60;

export function chargeRateLimit(ledger: Ledger, identityID: string, now: number): void {
  const cutoff = now - RATE_LIMIT_WINDOW_SECONDS;
  const events = (ledger.rateLimits[identityID] ?? []).filter((t) => t > cutoff);
  if (events.length >= RATE_LIMIT_MAX_OPERATIONS) fail("rate_limited");
  events.push(now);
  ledger.rateLimits[identityID] = events;
}

export interface ReduceOutcome {
  result: RelayResult;
  /** True when this outcome is a terminal-expiry rejection (see RequestExpiredTransition). */
  rejectedExpired: boolean;
}

/**
 * Applies one decoded protocol command to `ledger` in place and returns its
 * result. `ledger` must already belong to `owner` (the caller resolves and
 * locks the owner partition before calling this). Mirrors
 * `DurableProtocolReducer.apply`.
 */
export function reduce(kind: string, envelopePayload: Buffer, signer: DeviceIdentity, owner: DeviceIdentity, ledger: Ledger, now: number): ReduceOutcome {
  try {
    const result = applyKind(kind, envelopePayload, signer, owner, ledger, now);
    return { result, rejectedExpired: false };
  } catch (error) {
    if (error instanceof RequestExpiredTransition) {
      return { result: { kind: "acknowledgement" }, rejectedExpired: true };
    }
    throw error;
  }
}

function applyKind(kind: string, payload: Buffer, signer: DeviceIdentity, owner: DeviceIdentity, ledger: Ledger, now: number): RelayResult {
  switch (kind) {
    case "ack": {
      if (!identitiesEqual(signer, owner) || payload.toString("utf8") !== "{}") fail("malformed");
      return { kind: "acknowledgement" };
    }

    case "invite": {
      const invitation = decodeInvitation(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, owner) || !identitiesEqual(invitation.payload.owner, owner)) fail("unauthorized");
      if (now >= invitation.payload.expiresAt) fail("expired");
      if (now < invitation.payload.issuedAt - 60) fail("malformed");
      if (!verifyInvitationSignature(invitation)) fail("invalid_signature");
      if (ledger.invitations[invitation.payload.inviteID]) fail("replay");
      ledger.invitations[invitation.payload.inviteID] = { invitation, consumedAt: null };
      return { kind: "invitation", value: invitation };
    }

    case "accept": {
      const signed = decodeSignedAcceptance(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, signed.acceptance.approver)) fail("unauthorized");
      if (!identitiesEqual(signed.acceptance.owner, owner)) fail("unauthorized");
      const inviteRecord = ledger.invitations[signed.acceptance.inviteID];
      if (
        !inviteRecord ||
        !identitiesEqual(inviteRecord.invitation.payload.owner, owner) ||
        inviteRecord.consumedAt !== null ||
        now >= inviteRecord.invitation.payload.expiresAt ||
        signed.acceptance.issuedAt > now + 60 ||
        !verifySignedAcceptanceSignature(signed)
      ) {
        fail("unauthorized");
      }
      if (ledger.pendingAcceptances[signed.acceptance.acceptanceID]) fail("replay");
      // R5 pairing v2 (docs/r5-pairing-v2-plan.md's "Slice P2a"): retain the
      // approver's signature alongside the acceptance, so the owner's inbox
      // can later deliver a verifiable `SignedAcceptance` (see
      // `fetchInboxOperation`) instead of a bare, unsigned payload.
      ledger.pendingAcceptances[signed.acceptance.acceptanceID] = { acceptance: signed.acceptance, signature: signed.signature };
      return { kind: "acceptance", value: signed.acceptance };
    }

    case "confirm": {
      const signed = decodeSignedConfirmation(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, owner) || !identitiesEqual(signed.confirmation.owner, owner)) fail("unauthorized");
      // `normalizePendingAcceptance` reads either shape: a row this reducer
      // wrote (the `{acceptance, signature}` wrapper) or a legacy row from
      // before this change (the bare acceptance). Confirm never needed the
      // approver's signature itself (only the owner's own confirmation
      // signature, checked below), so this is unaffected by which shape is
      // stored.
      const pendingRaw = ledger.pendingAcceptances[signed.confirmation.acceptanceID];
      const acceptance = pendingRaw ? normalizePendingAcceptance(pendingRaw).acceptance : undefined;
      const invite = acceptance ? ledger.invitations[acceptance.inviteID] : undefined;
      const expectedCode = acceptance
        ? pairingVerificationCode({
            inviteID: acceptance.inviteID,
            ownerIdentityID: owner.identityID,
            approverIdentityID: acceptance.approver.identityID,
            nonce: invite ? invite.invitation.payload.nonce : Buffer.alloc(0)
          })
        : null;
      if (
        !acceptance ||
        acceptance.inviteID !== signed.confirmation.inviteID ||
        acceptance.approver.identityID !== signed.confirmation.approverIdentityID ||
        !invite ||
        invite.consumedAt !== null ||
        now >= invite.invitation.payload.expiresAt ||
        signed.confirmation.issuedAt > now + 60 ||
        acceptance.verificationCode !== signed.confirmation.verificationCode ||
        expectedCode !== signed.confirmation.verificationCode ||
        !verifySignedConfirmationSignature(signed)
      ) {
        fail("wrong_verification_code");
      }
      invite.consumedAt = now;
      for (const id of Object.keys(ledger.pendingAcceptances)) {
        const entry = ledger.pendingAcceptances[id];
        if (entry && normalizePendingAcceptance(entry).acceptance.inviteID === acceptance.inviteID) delete ledger.pendingAcceptances[id];
      }
      const pairingID = derivedPairingID(acceptance.inviteID, acceptance.approver.identityID);
      if (ledger.pairings[pairingID]) fail("replay");
      const epoch = checkedIncrement(ledger.pairingEpochs[pairingID] ?? 0);
      const pairing = { pairingID, owner, approver: acceptance.approver, epoch, createdAt: now, state: "active" as const };
      ledger.pairings[pairingID] = { pairing, revokedAt: null };
      ledger.pairingEpochs[pairingID] = epoch;
      return { kind: "pairing", value: pairing };
    }

    case "consent": {
      const mutation = decodeConsentMutation(JSON.parse(payload.toString("utf8")));
      if (mutation.scopes.some((s) => s !== R5_SCOPE_APPROVE_EARLY_END && s !== R5_SCOPE_RECEIVE_REQUESTS)) fail("unsupported_scope");
      if (!identitiesEqual(mutation.owner, owner) || mutation.relationshipID !== mutation.pairingID) fail("wrong_target");
      const pairingRecord = ledger.pairings[mutation.pairingID];
      if (
        !pairingRecord ||
        !identitiesEqual(pairingRecord.pairing.owner, owner) ||
        !identitiesEqual(pairingRecord.pairing.approver, mutation.approver) ||
        pairingRecord.pairing.epoch !== mutation.pairEpoch ||
        pairingRecord.pairing.state !== "active" ||
        mutation.issuedAt > now + 60
      ) {
        fail("wrong_target");
      }
      // Consent has no independent expiry field to bound a captured old
      // signed mutation the way an invite/session/request does, and its
      // replay-nonce marker is eventually purged by retention -- so a
      // maximum age is the only thing standing between an attacker replaying
      // an old (since-superseded) grant/accept/revoke and the relay applying
      // it again after the marker is gone. See docs/r5-relay-plan.md fix and
      // src/retention.ts's header comment.
      if (mutation.issuedAt < now - CONSENT_MAX_AGE_SECONDS) fail("expired");
      const ownerAction = mutation.action === "ownerGrant" || mutation.action === "ownerRevoke";
      const signerIsOwner = identitiesEqual(signer, owner);
      const signerIsApprover = identitiesEqual(signer, pairingRecord.pairing.approver);
      if (ownerAction ? !signerIsOwner : !signerIsApprover) fail("unauthorized");
      const nonceKey = mutation.nonce.toString("base64");
      if (ledger.usedConsentNonces[nonceKey]) fail("replay");
      let consent = ledger.relationshipConsents[mutation.relationshipID];
      if (!consent) {
        consent = {
          schemaVersion: 2,
          relationshipID: mutation.relationshipID,
          pairingID: pairingRecord.pairing.pairingID,
          pairEpoch: pairingRecord.pairing.epoch,
          generation: 0,
          owner,
          approver: pairingRecord.pairing.approver,
          ownerScopes: [],
          approverScopes: [],
          ownerState: "revoked",
          approverState: "revoked",
          updatedAt: now
        };
      }
      const scopeSet = new Set(mutation.scopes);
      switch (mutation.action) {
        case "ownerGrant":
          consent.ownerScopes = [...mutation.scopes].sort();
          consent.approverScopes = consent.approverScopes.filter((s) => scopeSet.has(s));
          consent.ownerState = mutation.scopes.length === 0 ? "revoked" : "active";
          consent.approverState = consent.approverScopes.length === 0 ? "pending" : "active";
          break;
        case "approverAccept": {
          const ownerScopeSet = new Set(consent.ownerScopes);
          if (!mutation.scopes.every((s) => ownerScopeSet.has(s))) fail("consent_required");
          consent.approverScopes = [...mutation.scopes].sort();
          consent.approverState = mutation.scopes.length === 0 ? "revoked" : "active";
          break;
        }
        case "ownerRevoke":
          consent.ownerScopes = consent.ownerScopes.filter((s) => !scopeSet.has(s));
          consent.approverScopes = consent.approverScopes.filter((s) => !scopeSet.has(s));
          consent.ownerState = consent.ownerScopes.length === 0 ? "revoked" : "active";
          consent.approverState = consent.approverScopes.length === 0 ? "pending" : "active";
          break;
        case "approverRevoke":
          consent.approverScopes = consent.approverScopes.filter((s) => !scopeSet.has(s));
          consent.approverState = consent.approverScopes.length === 0 ? "revoked" : "active";
          break;
      }
      consent.generation = checkedIncrement(consent.generation);
      consent.updatedAt = now;
      ledger.usedConsentNonces[nonceKey] = { createdAt: now };
      ledger.relationshipConsents[mutation.relationshipID] = consent;
      invalidateOutstandingAuthority(ledger, pairingRecord.pairing.pairingID, now);
      return { kind: "consent", value: consent };
    }

    case "session": {
      const session = decodeActiveSession(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, owner) || !identitiesEqual(session.owner, owner)) fail("invalid_transition");
      if (session.startsAt > now + 60 || session.endsAt <= now) fail("invalid_transition");
      ledger.sessions[session.sessionID] = { session, publishedAt: now };
      ledger.currentSessionID = session.sessionID;
      for (const [requestID, record] of Object.entries(ledger.requests)) {
        if (record.request.sessionID !== session.sessionID || record.request.activeSetID !== session.activeSetID) {
          expireRequest(ledger, requestID, now);
        }
      }
      return { kind: "session", value: session };
    }

    case "request": {
      const request = decodeTrustedRequest(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, owner) || !identitiesEqual(request.owner, owner)) fail("expired");
      if (request.status !== "pending") fail("expired");
      const session = ledger.currentSessionID === request.sessionID ? ledger.sessions[request.sessionID]?.session : undefined;
      if (!session || session.activeSetID !== request.activeSetID || !sessionIsActive(session, now)) fail("expired");
      if (request.createdAt > now + 60 || now >= request.expiresAt) fail("expired");
      validateRequestAuthorization(ledger, request, session, owner);
      if (ledger.requests[request.requestID]) fail("replay");
      ledger.requests[request.requestID] = { request, cancelledAt: null, expiredAt: null, declinedAt: null };
      return { kind: "request", value: request };
    }

    case "approval": {
      const approval = decodeApproval(JSON.parse(payload.toString("utf8")));
      if (!identitiesEqual(signer, approval.approver) || approval.approver.role !== "trustedApprover") fail("unauthorized");
      if (!verifyApprovalSignature(approval)) fail("invalid_signature");
      expireIfDue(ledger, approval.requestID, now);
      const record = ledger.requests[approval.requestID];
      const session = record ? ledger.sessions[approval.sessionID]?.session : undefined;
      const binding = record ? requestBinding(record.request, approval.approver.identityID) : undefined;
      const pairing = ledger.pairings[approval.pairingID]?.pairing;
      const consent = ledger.relationshipConsents[approval.pairingID];
      if (
        approval.consentGeneration <= 0 ||
        approval.nonce.length < 16 ||
        ledger.approvals[approval.approvalID] ||
        ledger.usedApprovalIDs[approval.approvalID] ||
        ledger.usedApprovalNonces[approval.nonce.toString("base64")] ||
        !record ||
        record.request.status !== "pending" ||
        !session ||
        ledger.currentSessionID !== approval.sessionID ||
        session.activeSetID !== approval.activeSetID ||
        !sessionIsActive(session, now) ||
        approval.issuedAt > now + 60 ||
        !binding ||
        binding.pairingID !== approval.pairingID ||
        binding.pairEpoch !== approval.pairEpoch ||
        binding.consentGeneration !== approval.consentGeneration ||
        !pairing ||
        !identitiesEqual(pairing.owner, owner) ||
        !identitiesEqual(pairing.approver, approval.approver) ||
        pairing.epoch !== approval.pairEpoch ||
        pairing.state !== "active" ||
        !consent ||
        consent.generation !== approval.consentGeneration ||
        !consentAuthorizes(consent, R5_SCOPE_APPROVE_EARLY_END) ||
        !consentAuthorizes(consent, R5_SCOPE_RECEIVE_REQUESTS) ||
        record.request.decisions[approval.approver.identityID] !== "pending"
      ) {
        fail("wrong_target");
      }
      ledger.approvals[approval.approvalID] = { approval, acceptedAt: now };
      ledger.usedApprovalNonces[approval.nonce.toString("base64")] = { createdAt: now };
      const updated = { ...record.request, decisions: { ...record.request.decisions, [approval.approver.identityID]: approval.decision } };
      let declinedAt = record.declinedAt;
      if (approval.decision === "approved") updated.status = "approved";
      else if (Object.values(updated.decisions).every((d) => d === "declined")) {
        updated.status = "declined";
        declinedAt = now;
      }
      ledger.requests[approval.requestID] = { ...record, request: updated, declinedAt };
      return { kind: "approval", value: approval };
    }

    case "use": {
      const use = decodeApprovalUse(JSON.parse(payload.toString("utf8")));
      if (!isValidIdentifier(use.useID)) fail("malformed");
      const requestRecord = ledger.requests[use.requestID];
      if (!identitiesEqual(signer, owner) || !requestRecord || !identitiesEqual(requestRecord.request.owner, owner)) fail("unauthorized");
      expireIfDue(ledger, use.requestID, now);
      const current = ledger.requests[use.requestID]!;
      const accepted = ledger.approvals[use.approval.approvalID]?.approval;
      const session = ledger.sessions[current.request.sessionID]?.session;
      const binding = accepted ? requestBinding(current.request, accepted.approver.identityID) : undefined;
      const pairing = accepted ? ledger.pairings[accepted.pairingID]?.pairing : undefined;
      const consent = accepted ? ledger.relationshipConsents[accepted.pairingID] : undefined;
      if (
        !accepted ||
        !approvalsEqual(accepted, use.approval) ||
        use.requestID !== accepted.requestID ||
        use.consentGeneration <= 0 ||
        use.consentGeneration !== accepted.consentGeneration ||
        ledger.approvalUses[use.useID] ||
        ledger.usedApprovalIDs[use.useID] ||
        ledger.usedApprovalIDs[accepted.approvalID] ||
        current.request.status !== "approved" ||
        ledger.currentSessionID !== current.request.sessionID ||
        !session ||
        session.activeSetID !== current.request.activeSetID ||
        !sessionIsActive(session, now) ||
        accepted.requestID !== current.request.requestID ||
        accepted.sessionID !== current.request.sessionID ||
        accepted.activeSetID !== current.request.activeSetID ||
        current.request.decisions[accepted.approver.identityID] !== "approved" ||
        !binding ||
        binding.pairingID !== accepted.pairingID ||
        binding.pairEpoch !== accepted.pairEpoch ||
        binding.consentGeneration !== accepted.consentGeneration ||
        !pairing ||
        !identitiesEqual(pairing.owner, owner) ||
        !identitiesEqual(pairing.approver, accepted.approver) ||
        pairing.epoch !== accepted.pairEpoch ||
        pairing.state !== "active" ||
        !consent ||
        consent.generation !== accepted.consentGeneration ||
        !consentAuthorizes(consent, R5_SCOPE_APPROVE_EARLY_END) ||
        !consentAuthorizes(consent, R5_SCOPE_RECEIVE_REQUESTS)
      ) {
        fail("replay");
      }
      if (!verifyApprovalSignature(accepted)) fail("invalid_signature");
      ledger.usedApprovalIDs[accepted.approvalID] = { createdAt: now };
      ledger.usedApprovalIDs[use.useID] = { createdAt: now };
      // committedRevision is filled in by the caller (service.ts), which
      // knows the transaction's committed revision; the reducer only records
      // the use marker shape here and the caller patches it in.
      ledger.approvalUses[use.useID] = { useID: use.useID, approvalID: accepted.approvalID, requestID: use.requestID, usedAt: now, committedRevision: -1 };
      return { kind: "verification", value: { approval: accepted, verifiedAt: now, useID: use.useID } };
    }

    case "cancel": {
      const reference = decodeRequestReference(JSON.parse(payload.toString("utf8")));
      const record = ledger.requests[reference.requestID];
      if (!identitiesEqual(signer, owner) || !record || !identitiesEqual(record.request.owner, owner)) fail("unauthorized");
      expireIfDue(ledger, reference.requestID, now);
      const fresh = ledger.requests[reference.requestID];
      if (!fresh) fail("not_found");
      if (fresh.request.status !== "pending" && fresh.request.status !== "approved") fail("invalid_transition");
      const consumed = Object.values(ledger.approvalUses).some((u) => u.requestID === reference.requestID);
      if (consumed) fail("invalid_transition");
      ledger.requests[reference.requestID] = { ...fresh, request: { ...fresh.request, status: "cancelled" }, cancelledAt: now };
      return { kind: "acknowledgement" };
    }

    case "natural_end": {
      const reference = decodeNaturalEnd(JSON.parse(payload.toString("utf8")));
      const session = ledger.currentSessionID === reference.sessionID ? ledger.sessions[reference.sessionID]?.session : undefined;
      if (!identitiesEqual(signer, owner) || !session || !identitiesEqual(session.owner, owner) || session.activeSetID !== reference.activeSetID || now < session.endsAt) {
        fail("invalid_transition");
      }
      for (const requestID of Object.keys(ledger.requests)) expireRequest(ledger, requestID, now);
      return { kind: "acknowledgement" };
    }

    case "revoke": {
      const reference = decodePairingReference(JSON.parse(payload.toString("utf8")));
      const record = ledger.pairings[reference.pairingID];
      if (!identitiesEqual(signer, owner) || !record || !identitiesEqual(record.pairing.owner, owner) || record.pairing.epoch !== reference.epoch || record.pairing.state !== "active") {
        fail("revoked_pairing");
      }
      ledger.pairings[reference.pairingID] = { pairing: { ...record.pairing, state: "revoked" }, revokedAt: now };
      revokeConsent(ledger, reference.pairingID, now);
      invalidateOutstandingAuthority(ledger, reference.pairingID, now);
      return { kind: "acknowledgement" };
    }

    case "replace_pairing": {
      const proposal = decodePairingReplacement(JSON.parse(payload.toString("utf8")));
      const previous = ledger.pairings[proposal.previousPairingID]?.pairing;
      if (!identitiesEqual(signer, owner) || !identitiesEqual(proposal.owner, owner) || !previous || !identitiesEqual(previous.owner, owner) || previous.state !== "active") {
        fail("revoked_pairing");
      }
      if (!verifyPairingReplacementSignature(proposal)) fail("invalid_signature");
      // `decodePairingReplacement` already checked `replacementEpoch ===
      // previousEpoch + 1` against the client-supplied values; this
      // independently re-derives the expected next epoch from the ledger's
      // own current epoch through the checked helper, so an exhausted epoch
      // fails closed rather than the client's arithmetic silently agreeing
      // with a wrapped/imprecise value.
      if (checkedIncrement(previous.epoch) !== proposal.replacementEpoch) fail("malformed");
      if (ledger.pairings[proposal.replacementPairingID]) fail("replay");
      ledger.pairings[proposal.previousPairingID] = { pairing: { ...previous, state: "revoked" }, revokedAt: now };
      revokeConsent(ledger, previous.pairingID, now);
      invalidateOutstandingAuthority(ledger, previous.pairingID, now);
      const activated = {
        pairingID: proposal.replacementPairingID,
        owner,
        approver: proposal.replacement,
        epoch: proposal.replacementEpoch,
        createdAt: now,
        state: "active" as const
      };
      ledger.pairings[activated.pairingID] = { pairing: activated, revokedAt: null };
      ledger.pairingEpochs[activated.pairingID] = activated.epoch;
      return { kind: "pairing", value: activated };
    }

    default:
      fail("unsupported_operation");
  }
}

// ---------------------------------------------------------------------------
// helpers (ported from DurableProtocolReducer's private helpers)
// ---------------------------------------------------------------------------

function validateRequestAuthorization(ledger: Ledger, request: ReturnType<typeof decodeTrustedRequest>, session: ReturnType<typeof decodeActiveSession>, owner: DeviceIdentity): void {
  if (request.expiresAt > session.endsAt) fail("revoked_pairing");
  const primary = ledger.pairings[request.pairingID]?.pairing;
  if (!primary || !identitiesEqual(primary.owner, owner) || primary.state !== "active" || primary.approver.identityID !== request.targetedApproverIDs[0] || primary.epoch !== request.pairEpoch) {
    fail("revoked_pairing");
  }
  for (const binding of request.targetBindings) {
    const pairing = ledger.pairings[binding.pairingID]?.pairing;
    const consent = ledger.relationshipConsents[binding.pairingID];
    if (
      binding.consentGeneration <= 0 ||
      !pairing ||
      !identitiesEqual(pairing.owner, owner) ||
      pairing.state !== "active" ||
      pairing.approver.identityID !== binding.approverIdentityID ||
      pairing.epoch !== binding.pairEpoch ||
      !consent ||
      consent.pairEpoch !== binding.pairEpoch ||
      consent.generation !== binding.consentGeneration ||
      !consentAuthorizes(consent, R5_SCOPE_RECEIVE_REQUESTS) ||
      !consentAuthorizes(consent, R5_SCOPE_APPROVE_EARLY_END)
    ) {
      fail("consent_required");
    }
  }
}

function expireRequest(ledger: Ledger, requestID: string, now: number): void {
  const record = ledger.requests[requestID];
  if (!record) return;
  if (record.request.status === "cancelled" || record.request.status === "declined" || record.request.status === "expired") return;
  ledger.requests[requestID] = { ...record, request: { ...record.request, status: "expired" }, expiredAt: now };
}

/** Mirrors `expireIfDue`: expires a due request and throws the terminal-rejection marker. */
function expireIfDue(ledger: Ledger, requestID: string, now: number): void {
  const record = ledger.requests[requestID];
  if (!record) return;
  if (record.request.status === "cancelled" || record.request.status === "declined" || record.request.status === "expired") return;
  const session = ledger.sessions[record.request.sessionID]?.session;
  const sessionEnded = session ? session.endsAt <= now : false;
  if (now < record.request.expiresAt && !sessionEnded) return;
  expireRequest(ledger, requestID, now);
  throw new RequestExpiredTransition();
}

function invalidateOutstandingAuthority(ledger: Ledger, pairingID: string, now: number): void {
  for (const [requestID, record] of Object.entries(ledger.requests)) {
    if (record.request.targetBindings.some((b) => b.pairingID === pairingID)) expireRequest(ledger, requestID, now);
  }
}

function revokeConsent(ledger: Ledger, pairingID: string, now: number): void {
  const consent = ledger.relationshipConsents[pairingID];
  if (!consent) return;
  consent.ownerScopes = [];
  consent.approverScopes = [];
  consent.ownerState = "revoked";
  consent.approverState = "revoked";
  consent.generation = checkedIncrement(consent.generation);
  consent.updatedAt = now;
}

function derivedPairingID(inviteID: string, approverIdentityID: string): string {
  // Port of the `confirm` case's pairing ID derivation:
  // base64url(sha256(bytes(domain: ".pairing", fields: [inviteID, approverID]))).prefix(32)
  return base64url(digest(canonicalBytes(`${COMPANION_VERSION}.pairing`, [inviteID, approverIdentityID]))).slice(0, 32);
}
