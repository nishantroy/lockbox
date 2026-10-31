// Port of the wire-level protocol types from
// CompanionKit/Sources/CompanionKit/{CompanionKit,ProtocolModels,Permissions,DurableSemantics}.swift
// and CompanionRelayService/Sources/CompanionRelayService/{DurableOperation,DurableStore}.swift.
//
// JSON key order does not matter for interop (JSON objects are unordered);
// Swift's `.sortedKeys` only makes *Swift's own* encoding deterministic. What
// must match byte-for-byte is: (a) the canonical *signing field* framing --
// ported in canonical.ts and verified against Swift-generated fixtures in
// test/vectors.test.ts -- and (b) the wire representation of `Date` (seconds
// since the 2001-01-01 reference date, Foundation's default `Codable`
// behavior) and `Data` (standard base64, not base64url). Decoding here does
// not need to reproduce Swift's exact JSON text, only its exact *values*.

import { relayError } from "./errors.js";
import {
  secondsToSwiftDate,
  swiftDateToSeconds,
  base64url,
  deviceIdentityID,
  canonicalBytes,
  digest,
  COMPANION_VERSION,
  millisecondsString as msString
} from "./canonical.js";
import { verify as ed25519Verify } from "./crypto.js";

export const MAX_IDENTIFIER_LENGTH = 128;
export const MAX_TARGETS = 16;
export const MAX_OPERATION_BODY_BYTES = 32_768;
/** Ceiling for the raw HTTP request body (SignedOperation JSON + base64 overhead); larger requests get 413. */
export const MAX_RAW_BODY_BYTES = 40_960;
export const MAX_INVITE_LIFETIME_SECONDS = 7 * 24 * 60 * 60;
export const MAX_REQUEST_LIFETIME_SECONDS = 24 * 60 * 60;
export const MAX_SESSION_LIFETIME_SECONDS = 7 * 24 * 60 * 60;

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

export function isValidIdentifier(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    Buffer.byteLength(value, "utf8") <= MAX_IDENTIFIER_LENGTH &&
    !/\s/.test(value)
  );
}

export function requireIdentifier(value: unknown, name: string): string {
  if (!isValidIdentifier(value)) throw relayError("malformed");
  return value;
}

const MIN_VALID_UNIX_SECONDS = 0;
const MAX_VALID_UNIX_SECONDS = 4_102_444_800; // matches CompanionKit's requireTimestamp upper bound

export function requireTimestampSeconds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw relayError("malformed");
  const seconds = swiftDateToSeconds(value);
  if (seconds < MIN_VALID_UNIX_SECONDS || seconds > MAX_VALID_UNIX_SECONDS) throw relayError("malformed");
  return seconds;
}

export function encodeDate(unixSeconds: number): number {
  return secondsToSwiftDate(unixSeconds);
}

export function requireSafeUint(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || !Number.isSafeInteger(value)) {
    throw relayError("malformed");
  }
  return value;
}

export function decodeData(value: unknown): Buffer {
  if (typeof value !== "string") throw relayError("malformed");
  // Standard base64 only (Swift `Data(base64Encoded:)`'s default behavior):
  // correctly padded, no embedded whitespace. Node's `Buffer.from` silently
  // tolerates junk (missing padding, stray characters), so re-encoding the
  // decoded bytes and comparing byte-for-byte against the original string
  // (padding included) is what actually rejects non-canonical input.
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) throw relayError("malformed");
  const buffer = Buffer.from(value, "base64");
  if (buffer.toString("base64") !== value) throw relayError("malformed");
  return buffer;
}

export function encodeData(value: Buffer): string {
  return value.toString("base64");
}

// ---------------------------------------------------------------------------
// DeviceIdentity
// ---------------------------------------------------------------------------

export type CompanionRole = "owner" | "trustedApprover";

export interface DeviceIdentity {
  identityID: string;
  role: CompanionRole;
  publicKey: Buffer;
}

export function decodeDeviceIdentity(value: unknown): DeviceIdentity {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const identityID = requireIdentifier(v.identityID, "identityID");
  if (v.role !== "owner" && v.role !== "trustedApprover") throw relayError("malformed");
  const publicKey = decodeData(v.publicKey);
  if (publicKey.length !== 32) throw relayError("malformed");
  if (deviceIdentityID(publicKey) !== identityID) throw relayError("malformed");
  return { identityID, role: v.role, publicKey };
}

export function encodeDeviceIdentity(identity: DeviceIdentity): object {
  return { identityID: identity.identityID, role: identity.role, publicKey: encodeData(identity.publicKey) };
}

export function identitiesEqual(a: DeviceIdentity, b: DeviceIdentity): boolean {
  return a.identityID === b.identityID && a.role === b.role && a.publicKey.equals(b.publicKey);
}

// ---------------------------------------------------------------------------
// CompanionScope / RelationshipConsent
// ---------------------------------------------------------------------------

export const R5_SCOPES = ["approveEarlyEnd", "receiveRequests"] as const;
export const RESERVED_R6_SCOPES = ["mutualPact", "earlyEndNotices", "weeklySharedSummaries"] as const;
export type CompanionScope = (typeof R5_SCOPES)[number] | (typeof RESERVED_R6_SCOPES)[number];

export function isR5Scope(scope: string): scope is (typeof R5_SCOPES)[number] {
  return (R5_SCOPES as readonly string[]).includes(scope);
}

export function decodeScopeSet(value: unknown): CompanionScope[] {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const scopes = (value as Record<string, unknown>).scopes;
  if (!Array.isArray(scopes)) throw relayError("malformed");
  const all = [...R5_SCOPES, ...RESERVED_R6_SCOPES] as string[];
  const result: CompanionScope[] = [];
  const seen = new Set<string>();
  for (const s of scopes) {
    if (typeof s !== "string" || !all.includes(s)) throw relayError("malformed");
    if (seen.has(s)) throw relayError("malformed");
    seen.add(s);
    result.push(s as CompanionScope);
  }
  return result.sort();
}

export type ConsentSide = "pending" | "active" | "revoked";
export type ConsentMutationAction = "ownerGrant" | "approverAccept" | "ownerRevoke" | "approverRevoke";

export interface RelationshipConsentMutation {
  relationshipID: string;
  pairingID: string;
  pairEpoch: number;
  owner: DeviceIdentity;
  approver: DeviceIdentity;
  action: ConsentMutationAction;
  scopes: CompanionScope[];
  nonce: Buffer;
  issuedAt: number;
}

export function decodeConsentMutation(value: unknown): RelationshipConsentMutation {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const relationshipID = requireIdentifier(v.relationshipID, "relationshipID");
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const pairEpoch = requireSafeUint(v.pairEpoch);
  if (relationshipID !== pairingID || pairEpoch <= 0) throw relayError("malformed");
  const owner = decodeDeviceIdentity(v.owner);
  const approver = decodeDeviceIdentity(v.approver);
  if (owner.role !== "owner" || approver.role !== "trustedApprover") throw relayError("malformed");
  const actions: ConsentMutationAction[] = ["ownerGrant", "approverAccept", "ownerRevoke", "approverRevoke"];
  if (typeof v.action !== "string" || !actions.includes(v.action as ConsentMutationAction)) throw relayError("malformed");
  const scopes = decodeScopeSet(v.scopes);
  const nonce = decodeData(v.nonce);
  if (nonce.length < 16 || nonce.length > 64) throw relayError("malformed");
  const issuedAt = requireTimestampSeconds(v.issuedAt);
  return { relationshipID, pairingID, pairEpoch, owner, approver, action: v.action as ConsentMutationAction, scopes, nonce, issuedAt };
}

export interface RelationshipConsent {
  schemaVersion: 2;
  relationshipID: string;
  pairingID: string;
  pairEpoch: number;
  generation: number;
  owner: DeviceIdentity;
  approver: DeviceIdentity;
  ownerScopes: CompanionScope[];
  approverScopes: CompanionScope[];
  ownerState: ConsentSide;
  approverState: ConsentSide;
  updatedAt: number;
}

export function decodeRelationshipConsent(value: unknown): RelationshipConsent {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  if (v.schemaVersion !== 2) throw relayError("malformed");
  const relationshipID = requireIdentifier(v.relationshipID, "relationshipID");
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const pairEpoch = requireSafeUint(v.pairEpoch);
  const generation = requireSafeUint(v.generation);
  const owner = decodeDeviceIdentity(v.owner);
  const approver = decodeDeviceIdentity(v.approver);
  const ownerScopes = decodeScopeArray(v.ownerScopes);
  const approverScopes = decodeScopeArray(v.approverScopes);
  const sides: ConsentSide[] = ["pending", "active", "revoked"];
  if (typeof v.ownerState !== "string" || !sides.includes(v.ownerState as ConsentSide)) throw relayError("malformed");
  if (typeof v.approverState !== "string" || !sides.includes(v.approverState as ConsentSide)) throw relayError("malformed");
  const updatedAt = requireTimestampSeconds(v.updatedAt);
  return {
    schemaVersion: 2,
    relationshipID,
    pairingID,
    pairEpoch,
    generation,
    owner,
    approver,
    ownerScopes,
    approverScopes,
    ownerState: v.ownerState as ConsentSide,
    approverState: v.approverState as ConsentSide,
    updatedAt
  };
}

function decodeScopeArray(value: unknown): CompanionScope[] {
  if (!Array.isArray(value)) throw relayError("malformed");
  const all = [...R5_SCOPES, ...RESERVED_R6_SCOPES] as string[];
  for (const s of value) if (typeof s !== "string" || !all.includes(s)) throw relayError("malformed");
  return value as CompanionScope[];
}

export function encodeRelationshipConsent(c: RelationshipConsent): object {
  return {
    schemaVersion: c.schemaVersion,
    relationshipID: c.relationshipID,
    pairingID: c.pairingID,
    pairEpoch: c.pairEpoch,
    generation: c.generation,
    owner: encodeDeviceIdentity(c.owner),
    approver: encodeDeviceIdentity(c.approver),
    ownerScopes: c.ownerScopes,
    approverScopes: c.approverScopes,
    ownerState: c.ownerState,
    approverState: c.approverState,
    updatedAt: encodeDate(c.updatedAt)
  };
}

export function activeScopes(c: RelationshipConsent): Set<CompanionScope> {
  if (c.ownerState !== "active" || c.approverState !== "active") return new Set();
  const approverSet = new Set(c.approverScopes);
  return new Set(c.ownerScopes.filter((s) => approverSet.has(s) && isR5Scope(s)));
}

export function consentAuthorizes(c: RelationshipConsent, scope: CompanionScope): boolean {
  return isR5Scope(scope) && activeScopes(c).has(scope);
}

// ---------------------------------------------------------------------------
// Invitation / pairing
// ---------------------------------------------------------------------------

/** Maximum length of an owner/approver display name, in Unicode scalar values. */
export const MAX_DISPLAY_NAME_SCALARS = 40;

/** Whitespace-like scalars (Unicode White_Space plus U+FEFF), spelled out so TS and Swift agree exactly. */
function isBlankScalar(cp: number): boolean {
  return (
    (cp >= 0x09 && cp <= 0x0d) ||
    cp === 0x20 ||
    cp === 0x85 ||
    cp === 0xa0 ||
    cp === 0x1680 ||
    (cp >= 0x2000 && cp <= 0x200a) ||
    cp === 0x2028 ||
    cp === 0x2029 ||
    cp === 0x202f ||
    cp === 0x205f ||
    cp === 0x3000 ||
    cp === 0xfeff
  );
}

/** Scalars a display name may never contain: C0/C1 controls, bidi controls and invisible marks that enable spoofing. U+200D (ZWJ) stays legal for emoji sequences. */
function isForbiddenNameScalar(cp: number): boolean {
  return (
    cp <= 0x1f ||
    (cp >= 0x7f && cp <= 0x9f) ||
    cp === 0x061c ||
    cp === 0x200b ||
    cp === 0x200e ||
    cp === 0x200f ||
    (cp >= 0x202a && cp <= 0x202e) ||
    (cp >= 0x2066 && cp <= 0x2069)
  );
}

/**
 * Pairing v3: a display name is optional, 1...40 Unicode scalars, well-formed
 * Unicode (no lone UTF-16 surrogates: they would sign as replacement bytes and
 * later fail to decode in Swift), no forbidden scalars and not blank. Rules
 * are identical to `PairingFields.validateDisplayName` in CompanionKit.
 * `undefined` means "no name"; an empty string is rejected so "no name" has one
 * signed representation (the empty string in the signing fields).
 */
export function decodeDisplayName(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw relayError("malformed");
  if (/\p{Surrogate}/u.test(value)) throw relayError("malformed");
  const scalars = Array.from(value, (ch) => ch.codePointAt(0)!);
  if (scalars.length === 0 || scalars.length > MAX_DISPLAY_NAME_SCALARS) throw relayError("malformed");
  if (scalars.some(isForbiddenNameScalar)) throw relayError("malformed");
  if (scalars.every(isBlankScalar)) throw relayError("malformed");
  return value;
}

/** Pairing v3: the R5 scopes the owner grants / the friend accepts: non-empty, unique, R5-only, sorted. */
export function decodeGrantedScopes(value: unknown): Array<(typeof R5_SCOPES)[number]> {
  if (!Array.isArray(value) || value.length === 0) throw relayError("malformed");
  const seen = new Set<string>();
  for (const s of value) {
    if (typeof s !== "string" || !isR5Scope(s) || seen.has(s)) throw relayError("malformed");
    seen.add(s);
  }
  return ([...seen] as Array<(typeof R5_SCOPES)[number]>).sort();
}

export interface InvitePayload {
  inviteID: string;
  owner: DeviceIdentity;
  issuedAt: number;
  expiresAt: number;
  nonce: Buffer;
  /** `inviteTokenHash(token, ownerPublicKey, inviteID)`: only a token holder can recompute it. The token itself never reaches the relay. */
  tokenHash: Buffer;
  /** `inviteLookupKey(token)`: the relay's only handle on the invite. Signed so the relay cannot re-point a lookup. */
  lookupKey: Buffer;
  ownerDisplayName?: string;
  grantedScopes: Array<(typeof R5_SCOPES)[number]>;
}

export function invitePayloadSigningFields(p: InvitePayload): string[] {
  return [
    p.inviteID,
    p.owner.identityID,
    base64url(p.owner.publicKey),
    msString(p.issuedAt),
    msString(p.expiresAt),
    base64url(p.nonce),
    base64url(p.tokenHash),
    base64url(p.lookupKey),
    p.ownerDisplayName ?? "",
    [...p.grantedScopes].sort().join(",")
  ];
}

export interface Invitation {
  payload: InvitePayload;
  signature: Buffer;
}

export function decodeInvitation(value: unknown): Invitation {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const p = v.payload;
  if (typeof p !== "object" || p === null) throw relayError("malformed");
  const pv = p as Record<string, unknown>;
  const inviteID = requireIdentifier(pv.inviteID, "inviteID");
  const owner = decodeDeviceIdentity(pv.owner);
  if (owner.role !== "owner") throw relayError("malformed");
  const issuedAt = requireTimestampSeconds(pv.issuedAt);
  const expiresAt = requireTimestampSeconds(pv.expiresAt);
  const nonce = decodeData(pv.nonce);
  if (nonce.length < 16 || nonce.length > 64) throw relayError("malformed");
  if (expiresAt <= issuedAt || expiresAt - issuedAt > MAX_INVITE_LIFETIME_SECONDS) throw relayError("malformed");
  // Pairing v3: a v2 invite has no tokenHash/grantedScopes and is rejected here.
  const tokenHash = decodeData(pv.tokenHash);
  if (tokenHash.length !== 32) throw relayError("malformed");
  const lookupKey = decodeData(pv.lookupKey);
  if (lookupKey.length !== 32) throw relayError("malformed");
  const ownerDisplayName = decodeDisplayName(pv.ownerDisplayName);
  const grantedScopes = decodeGrantedScopes(pv.grantedScopes);
  const signature = decodeData(v.signature);
  if (signature.length !== 64) throw relayError("malformed");
  const payload: InvitePayload = { inviteID, owner, issuedAt, expiresAt, nonce, tokenHash, lookupKey, grantedScopes };
  if (ownerDisplayName !== undefined) payload.ownerDisplayName = ownerDisplayName;
  return { payload, signature };
}

export function encodeInvitation(inv: Invitation): object {
  const payload: Record<string, unknown> = {
    inviteID: inv.payload.inviteID,
    owner: encodeDeviceIdentity(inv.payload.owner),
    issuedAt: encodeDate(inv.payload.issuedAt),
    expiresAt: encodeDate(inv.payload.expiresAt),
    nonce: encodeData(inv.payload.nonce),
    tokenHash: encodeData(inv.payload.tokenHash),
    lookupKey: encodeData(inv.payload.lookupKey),
    grantedScopes: inv.payload.grantedScopes
  };
  if (inv.payload.ownerDisplayName !== undefined) payload.ownerDisplayName = inv.payload.ownerDisplayName;
  return { payload, signature: encodeData(inv.signature) };
}

export function verifyInvitationSignature(inv: Invitation): boolean {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.invite.v3`, invitePayloadSigningFields(inv.payload));
  return ed25519Verify(bytes, inv.signature, inv.payload.owner.publicKey);
}

/**
 * Pairing v3 acceptance: friend-signed, carries the invite's lookup key (what
 * the relay gates on), a token-derived `tokenProof` only the link holder can
 * compute (verified by the OWNER, never by the relay), the friend's optional
 * display name and the scopes the friend consents to. It replaces the v2 acceptance +
 * confirmation + consent handshake: the relay turns a valid one into an
 * active pairing and active both-sided consent in one transaction.
 */
export interface PairingAcceptance {
  acceptanceID: string;
  inviteID: string;
  owner: DeviceIdentity;
  approver: DeviceIdentity;
  issuedAt: number;
  lookupKey: Buffer;
  tokenProof: Buffer;
  approverDisplayName?: string;
  acceptedScopes: Array<(typeof R5_SCOPES)[number]>;
}

export function pairingAcceptanceSigningFields(a: PairingAcceptance): string[] {
  return [
    a.acceptanceID,
    a.inviteID,
    a.owner.identityID,
    a.approver.identityID,
    base64url(a.owner.publicKey),
    base64url(a.approver.publicKey),
    msString(a.issuedAt),
    base64url(a.lookupKey),
    base64url(a.tokenProof),
    a.approverDisplayName ?? "",
    [...a.acceptedScopes].sort().join(",")
  ];
}

export interface SignedAcceptance {
  acceptance: PairingAcceptance;
  signature: Buffer;
}

export function decodePairingAcceptance(v: Record<string, unknown>): PairingAcceptance {
  if (typeof v !== "object" || v === null) throw relayError("malformed");
  const acceptanceID = requireIdentifier(v.acceptanceID, "acceptanceID");
  const inviteID = requireIdentifier(v.inviteID, "inviteID");
  const owner = decodeDeviceIdentity(v.owner);
  const approver = decodeDeviceIdentity(v.approver);
  if (owner.role !== "owner" || approver.role !== "trustedApprover") throw relayError("malformed");
  const issuedAt = requireTimestampSeconds(v.issuedAt);
  const lookupKey = decodeData(v.lookupKey);
  const tokenProof = decodeData(v.tokenProof);
  if (lookupKey.length !== 32 || tokenProof.length !== 32) throw relayError("malformed");
  const approverDisplayName = decodeDisplayName(v.approverDisplayName);
  const acceptedScopes = decodeGrantedScopes(v.acceptedScopes);
  const acceptance: PairingAcceptance = { acceptanceID, inviteID, owner, approver, issuedAt, lookupKey, tokenProof, acceptedScopes };
  if (approverDisplayName !== undefined) acceptance.approverDisplayName = approverDisplayName;
  return acceptance;
}

export function decodeSignedAcceptance(value: unknown): SignedAcceptance {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  if (typeof v.acceptance !== "object" || v.acceptance === null) throw relayError("malformed");
  const acceptance = decodePairingAcceptance(v.acceptance as Record<string, unknown>);
  const signature = decodeData(v.signature);
  if (signature.length !== 64) throw relayError("malformed");
  return { acceptance, signature };
}

export function verifySignedAcceptanceSignature(signed: SignedAcceptance): boolean {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.acceptance.v3`, pairingAcceptanceSigningFields(signed.acceptance));
  return ed25519Verify(bytes, signed.signature, signed.acceptance.approver.publicKey);
}

export function encodePairingAcceptance(a: PairingAcceptance): object {
  const out: Record<string, unknown> = {
    acceptanceID: a.acceptanceID,
    inviteID: a.inviteID,
    owner: encodeDeviceIdentity(a.owner),
    approver: encodeDeviceIdentity(a.approver),
    issuedAt: encodeDate(a.issuedAt),
    lookupKey: encodeData(a.lookupKey),
    tokenProof: encodeData(a.tokenProof),
    acceptedScopes: a.acceptedScopes
  };
  if (a.approverDisplayName !== undefined) out.approverDisplayName = a.approverDisplayName;
  return out;
}

/** Wire shape of one `InboxResponse.acceptances` entry: Swift's `SignedAcceptance` (`{"acceptance": {...}, "signature": "<base64>"}`). */
export function encodeSignedAcceptance(s: SignedAcceptance): object {
  return { acceptance: encodePairingAcceptance(s.acceptance), signature: encodeData(s.signature) };
}

/** Wire shape of `POST /v1/invite/lookup`'s 200 response: the owner-signed invitation. */
export function encodeInviteLookupResponse(inv: Invitation): object {
  return { invitation: encodeInvitation(inv) };
}

export type PairingState = "active" | "revoked";

export interface Pairing {
  pairingID: string;
  owner: DeviceIdentity;
  approver: DeviceIdentity;
  epoch: number;
  /** When the pairing became active: for a v3 pairing, the moment the friend accepted ("joined"). */
  createdAt: number;
  state: PairingState;
  /** Pairing v3: names carried from the signed invite/acceptance so each side can show who the other is. */
  ownerDisplayName?: string;
  approverDisplayName?: string;
}

export function decodePairing(value: unknown): Pairing {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const owner = decodeDeviceIdentity(v.owner);
  const approver = decodeDeviceIdentity(v.approver);
  const epoch = requireSafeUint(v.epoch);
  const createdAt = requireTimestampSeconds(v.createdAt);
  const states: PairingState[] = ["active", "revoked"];
  if (typeof v.state !== "string" || !states.includes(v.state as PairingState)) throw relayError("malformed");
  if (owner.role !== "owner" || approver.role !== "trustedApprover" || epoch <= 0) throw relayError("malformed");
  const pairing: Pairing = { pairingID, owner, approver, epoch, createdAt, state: v.state as PairingState };
  const ownerDisplayName = decodeDisplayName(v.ownerDisplayName);
  const approverDisplayName = decodeDisplayName(v.approverDisplayName);
  if (ownerDisplayName !== undefined) pairing.ownerDisplayName = ownerDisplayName;
  if (approverDisplayName !== undefined) pairing.approverDisplayName = approverDisplayName;
  return pairing;
}

export function encodePairing(p: Pairing): object {
  const out: Record<string, unknown> = {
    pairingID: p.pairingID,
    owner: encodeDeviceIdentity(p.owner),
    approver: encodeDeviceIdentity(p.approver),
    epoch: p.epoch,
    createdAt: encodeDate(p.createdAt),
    state: p.state
  };
  if (p.ownerDisplayName !== undefined) out.ownerDisplayName = p.ownerDisplayName;
  if (p.approverDisplayName !== undefined) out.approverDisplayName = p.approverDisplayName;
  return out;
}

// ---------------------------------------------------------------------------
// Sessions, requests, approvals
// ---------------------------------------------------------------------------

export interface ActiveSession {
  owner: DeviceIdentity;
  sessionID: string;
  activeSetID: string;
  startsAt: number;
  endsAt: number;
}

export function decodeActiveSession(value: unknown): ActiveSession {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const owner = decodeDeviceIdentity(v.owner);
  if (owner.role !== "owner") throw relayError("malformed");
  const sessionID = requireIdentifier(v.sessionID, "sessionID");
  const activeSetID = requireIdentifier(v.activeSetID, "activeSetID");
  const startsAt = requireTimestampSeconds(v.startsAt);
  const endsAt = requireTimestampSeconds(v.endsAt);
  if (endsAt <= startsAt || endsAt - startsAt > MAX_SESSION_LIFETIME_SECONDS) throw relayError("malformed");
  return { owner, sessionID, activeSetID, startsAt, endsAt };
}

export function encodeActiveSession(s: ActiveSession): object {
  return {
    owner: encodeDeviceIdentity(s.owner),
    sessionID: s.sessionID,
    activeSetID: s.activeSetID,
    startsAt: encodeDate(s.startsAt),
    endsAt: encodeDate(s.endsAt)
  };
}

export function sessionIsActive(s: ActiveSession, atSeconds: number): boolean {
  return atSeconds >= s.startsAt && atSeconds < s.endsAt;
}

export interface RequestTargetBinding {
  approverIdentityID: string;
  pairingID: string;
  pairEpoch: number;
  consentGeneration: number;
}

export function decodeTargetBinding(value: unknown): RequestTargetBinding {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const approverIdentityID = requireIdentifier(v.approverIdentityID, "approverIdentityID");
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const pairEpoch = requireSafeUint(v.pairEpoch);
  const consentGeneration = v.consentGeneration === undefined ? 0 : requireSafeUint(v.consentGeneration);
  if (pairEpoch <= 0) throw relayError("malformed");
  return { approverIdentityID, pairingID, pairEpoch, consentGeneration };
}

export function encodeTargetBinding(b: RequestTargetBinding): object {
  return { approverIdentityID: b.approverIdentityID, pairingID: b.pairingID, pairEpoch: b.pairEpoch, consentGeneration: b.consentGeneration };
}

export type TrustedRequestStatus = "pending" | "approved" | "declined" | "cancelled" | "expired";
export type ApproverDecision = "pending" | "approved" | "declined";

export interface TrustedRequest {
  requestID: string;
  owner: DeviceIdentity;
  pairingID: string;
  pairEpoch: number;
  consentGeneration: number;
  sessionID: string;
  activeSetID: string;
  purpose: "approveEarlyEnd";
  targetedApproverIDs: string[];
  targetBindings: RequestTargetBinding[];
  message: null;
  createdAt: number;
  expiresAt: number;
  status: TrustedRequestStatus;
  decisions: Record<string, ApproverDecision>;
}

export function decodeTrustedRequest(value: unknown): TrustedRequest {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const requestID = requireIdentifier(v.requestID, "requestID");
  const owner = decodeDeviceIdentity(v.owner);
  if (owner.role !== "owner") throw relayError("malformed");
  const sessionID = requireIdentifier(v.sessionID, "sessionID");
  const activeSetID = requireIdentifier(v.activeSetID, "activeSetID");
  if (v.purpose !== "approveEarlyEnd") throw relayError("malformed");
  if (v.message !== null && v.message !== undefined) throw relayError("malformed");
  if (!Array.isArray(v.targetedApproverIDs) || !Array.isArray(v.targetBindings)) throw relayError("malformed");
  const targetedApproverIDs = v.targetedApproverIDs.map((id) => requireIdentifier(id, "approverID"));
  const targetBindings = v.targetBindings.map(decodeTargetBinding);
  if (
    targetedApproverIDs.length === 0 ||
    targetedApproverIDs.length > MAX_TARGETS ||
    new Set(targetedApproverIDs).size !== targetedApproverIDs.length ||
    targetBindings.length !== targetedApproverIDs.length ||
    targetBindings.map((b) => b.approverIdentityID).join("\u0000") !== targetedApproverIDs.join("\u0000")
  ) {
    throw relayError("malformed");
  }
  const first = targetBindings[0];
  if (!first) throw relayError("malformed");
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const pairEpoch = requireSafeUint(v.pairEpoch);
  const consentGeneration = requireSafeUint(v.consentGeneration);
  if (pairingID !== first.pairingID || pairEpoch !== first.pairEpoch || consentGeneration !== first.consentGeneration) {
    throw relayError("malformed");
  }
  const createdAt = requireTimestampSeconds(v.createdAt);
  const expiresAt = requireTimestampSeconds(v.expiresAt);
  if (expiresAt <= createdAt || expiresAt - createdAt > MAX_REQUEST_LIFETIME_SECONDS) throw relayError("malformed");
  const statuses: TrustedRequestStatus[] = ["pending", "approved", "declined", "cancelled", "expired"];
  if (typeof v.status !== "string" || !statuses.includes(v.status as TrustedRequestStatus)) throw relayError("malformed");
  if (typeof v.decisions !== "object" || v.decisions === null) throw relayError("malformed");
  // Null-prototype: `targetedApproverIDs` (and thus decision keys) are
  // free-form client-chosen identifiers, so a normal `{}` here would let a
  // key like "__proto__" reach a bracket assignment below and repoint this
  // object's prototype instead of creating an ordinary own property, and
  // would let the `in` check further down give a false positive for
  // inherited names like "toString"/"constructor" it never actually stored.
  const decisions: Record<string, ApproverDecision> = Object.create(null);
  const decisionValues: ApproverDecision[] = ["pending", "approved", "declined"];
  for (const [key, val] of Object.entries(v.decisions as Record<string, unknown>)) {
    if (typeof val !== "string" || !decisionValues.includes(val as ApproverDecision)) throw relayError("malformed");
    decisions[key] = val as ApproverDecision;
  }
  if (
    targetedApproverIDs.length !== Object.keys(decisions).length ||
    !targetedApproverIDs.every((id) => id in decisions)
  ) {
    throw relayError("malformed");
  }
  return {
    requestID,
    owner,
    pairingID,
    pairEpoch,
    consentGeneration,
    sessionID,
    activeSetID,
    purpose: "approveEarlyEnd",
    targetedApproverIDs,
    targetBindings,
    message: null,
    createdAt,
    expiresAt,
    status: v.status as TrustedRequestStatus,
    decisions
  };
}

export function encodeTrustedRequest(r: TrustedRequest): object {
  return {
    requestID: r.requestID,
    owner: encodeDeviceIdentity(r.owner),
    pairingID: r.pairingID,
    pairEpoch: r.pairEpoch,
    consentGeneration: r.consentGeneration,
    sessionID: r.sessionID,
    activeSetID: r.activeSetID,
    purpose: r.purpose,
    targetedApproverIDs: r.targetedApproverIDs,
    targetBindings: r.targetBindings.map(encodeTargetBinding),
    message: null,
    createdAt: encodeDate(r.createdAt),
    expiresAt: encodeDate(r.expiresAt),
    status: r.status,
    decisions: r.decisions
  };
}

export function requestBinding(r: TrustedRequest, approverIdentityID: string): RequestTargetBinding | undefined {
  return r.targetBindings.find((b) => b.approverIdentityID === approverIdentityID);
}

export function requestEffectiveStatus(r: TrustedRequest, atSeconds: number): TrustedRequestStatus {
  if (r.status === "cancelled" || r.status === "declined") return r.status;
  return atSeconds >= r.expiresAt ? "expired" : r.status;
}

export interface Approval {
  approvalID: string;
  nonce: Buffer;
  requestID: string;
  pairingID: string;
  pairEpoch: number;
  consentGeneration: number;
  sessionID: string;
  activeSetID: string;
  approver: DeviceIdentity;
  decision: ApproverDecision;
  issuedAt: number;
  signature: Buffer;
}

export function approvalSigningFields(a: Omit<Approval, "signature">): string[] {
  const fields = [
    a.approvalID,
    a.requestID,
    a.pairingID,
    String(a.pairEpoch),
    String(a.consentGeneration),
    a.sessionID,
    a.activeSetID,
    a.approver.identityID,
    base64url(a.approver.publicKey),
    a.decision,
    msString(a.issuedAt)
  ];
  if (a.nonce.length > 0) fields.push(base64url(a.nonce));
  return fields;
}

export function decodeApproval(value: unknown): Approval {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const approvalID = requireIdentifier(v.approvalID, "approvalID");
  const nonce = v.nonce === undefined ? Buffer.alloc(0) : decodeData(v.nonce);
  const requestID = requireIdentifier(v.requestID, "requestID");
  const pairingID = requireIdentifier(v.pairingID, "pairingID");
  const pairEpoch = requireSafeUint(v.pairEpoch);
  const consentGeneration = v.consentGeneration === undefined ? 0 : requireSafeUint(v.consentGeneration);
  const sessionID = requireIdentifier(v.sessionID, "sessionID");
  const activeSetID = requireIdentifier(v.activeSetID, "activeSetID");
  const approver = decodeDeviceIdentity(v.approver);
  if (approver.role !== "trustedApprover") throw relayError("malformed");
  const decisions: ApproverDecision[] = ["pending", "approved", "declined"];
  if (typeof v.decision !== "string" || !decisions.includes(v.decision as ApproverDecision)) throw relayError("malformed");
  const issuedAt = requireTimestampSeconds(v.issuedAt);
  const signature = decodeData(v.signature);
  if (signature.length !== 64 || pairEpoch <= 0) throw relayError("malformed");
  return {
    approvalID,
    nonce,
    requestID,
    pairingID,
    pairEpoch,
    consentGeneration,
    sessionID,
    activeSetID,
    approver,
    decision: v.decision as ApproverDecision,
    issuedAt,
    signature
  };
}

export function encodeApproval(a: Approval): object {
  return {
    approvalID: a.approvalID,
    nonce: encodeData(a.nonce),
    requestID: a.requestID,
    pairingID: a.pairingID,
    pairEpoch: a.pairEpoch,
    consentGeneration: a.consentGeneration,
    sessionID: a.sessionID,
    activeSetID: a.activeSetID,
    approver: encodeDeviceIdentity(a.approver),
    decision: a.decision,
    issuedAt: encodeDate(a.issuedAt),
    signature: encodeData(a.signature)
  };
}

export function verifyApprovalSignature(a: Approval): boolean {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.approval`, approvalSigningFields(a));
  return ed25519Verify(bytes, a.signature, a.approver.publicKey);
}

export function approvalsEqual(a: Approval, b: Approval): boolean {
  return (
    a.approvalID === b.approvalID &&
    a.nonce.equals(b.nonce) &&
    a.requestID === b.requestID &&
    a.pairingID === b.pairingID &&
    a.pairEpoch === b.pairEpoch &&
    a.consentGeneration === b.consentGeneration &&
    a.sessionID === b.sessionID &&
    a.activeSetID === b.activeSetID &&
    identitiesEqual(a.approver, b.approver) &&
    a.decision === b.decision &&
    a.issuedAt === b.issuedAt &&
    a.signature.equals(b.signature)
  );
}

export interface ApprovalVerification {
  approval: Approval;
  verifiedAt: number;
  useID: string;
}

export function encodeApprovalVerification(v: ApprovalVerification): object {
  return { approval: encodeApproval(v.approval), verifiedAt: encodeDate(v.verifiedAt), useID: v.useID };
}

export function decodeApprovalVerification(value: unknown): ApprovalVerification {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const approval = decodeApproval(v.approval);
  const verifiedAt = requireTimestampSeconds(v.verifiedAt);
  const useID = requireIdentifier(v.useID, "useID");
  return { approval, verifiedAt, useID };
}

export interface ApprovalUse {
  approval: Approval;
  requestID: string;
  useID: string;
  consentGeneration: number;
}

export function decodeApprovalUse(value: unknown): ApprovalUse {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const approval = decodeApproval(v.approval);
  const requestID = requireIdentifier(v.requestID, "requestID");
  const useID = requireIdentifier(v.useID, "useID");
  const consentGeneration = requireSafeUint(v.consentGeneration);
  return { approval, requestID, useID, consentGeneration };
}

export interface RequestReference {
  requestID: string;
}

export function decodeRequestReference(value: unknown): RequestReference {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const requestID = requireIdentifier((value as Record<string, unknown>).requestID, "requestID");
  return { requestID };
}

export interface PairingReference {
  pairingID: string;
  epoch: number;
}

export function decodePairingReference(value: unknown): PairingReference {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  return { pairingID: requireIdentifier(v.pairingID, "pairingID"), epoch: requireSafeUint(v.epoch) };
}

export interface DurableNaturalEnd {
  sessionID: string;
  activeSetID: string;
}

export function decodeNaturalEnd(value: unknown): DurableNaturalEnd {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  return { sessionID: requireIdentifier(v.sessionID, "sessionID"), activeSetID: requireIdentifier(v.activeSetID, "activeSetID") };
}

export interface PairingReplacement {
  replacementID: string;
  previousPairingID: string;
  previousEpoch: number;
  replacementPairingID: string;
  replacement: DeviceIdentity;
  owner: DeviceIdentity;
  replacementEpoch: number;
  issuedAt: number;
  signature: Buffer;
}

export function pairingReplacementSigningFields(p: Omit<PairingReplacement, "signature">): string[] {
  return [
    p.replacementID,
    p.previousPairingID,
    String(p.previousEpoch),
    p.replacementPairingID,
    p.owner.identityID,
    base64url(p.owner.publicKey),
    p.replacement.identityID,
    base64url(p.replacement.publicKey),
    String(p.replacementEpoch),
    msString(p.issuedAt)
  ];
}

export function decodePairingReplacement(value: unknown): PairingReplacement {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const replacementID = requireIdentifier(v.replacementID, "replacementID");
  const previousPairingID = requireIdentifier(v.previousPairingID, "previousPairingID");
  const previousEpoch = requireSafeUint(v.previousEpoch);
  const replacementPairingID = requireIdentifier(v.replacementPairingID, "replacementPairingID");
  const replacement = decodeDeviceIdentity(v.replacement);
  const owner = decodeDeviceIdentity(v.owner);
  const replacementEpoch = requireSafeUint(v.replacementEpoch);
  const issuedAt = requireTimestampSeconds(v.issuedAt);
  const signature = decodeData(v.signature);
  if (replacement.role !== "trustedApprover" || replacementEpoch !== previousEpoch + 1 || signature.length !== 64) {
    throw relayError("malformed");
  }
  return { replacementID, previousPairingID, previousEpoch, replacementPairingID, replacement, owner, replacementEpoch, issuedAt, signature };
}

export function verifyPairingReplacementSignature(p: PairingReplacement): boolean {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.pairing-replacement`, pairingReplacementSigningFields(p));
  return ed25519Verify(bytes, p.signature, p.replacement.publicKey);
}

export interface InboxQuery {
  identityID: string;
  /**
   * Freshness timestamp. The inbox fetch operation otherwise has no
   * freshness check at all (no expiry, no nonce); when present, the relay
   * enforces a 5-minute window around it (src/service.ts). Both Swift
   * clients now always send this field. It stays optional on this type (and
   * the wire format) for backward/legacy decoding, but `src/service.ts`'s
   * `REQUIRE_FRESH_INBOX` defaults to *requiring* it -- only an explicit
   * `REQUIRE_FRESH_INBOX=false` accepts the legacy `issuedAt`-less form.
   */
  issuedAt?: number;
}

export function decodeInboxQuery(value: unknown): InboxQuery {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const identityID = requireIdentifier(v.identityID, "identityID");
  if (v.issuedAt === undefined || v.issuedAt === null) return { identityID };
  return { identityID, issuedAt: requireTimestampSeconds(v.issuedAt) };
}

// ---------------------------------------------------------------------------
// Signed operation envelope
// ---------------------------------------------------------------------------

export interface SignedOperation {
  operationID: string;
  expectedRevision: number | null;
  kind: string;
  signer: DeviceIdentity;
  body: Buffer;
  signature: Buffer;
}

export function signedOperationSigningFields(op: Omit<SignedOperation, "signature">): string[] {
  return [
    op.operationID,
    op.expectedRevision === null ? "none" : String(op.expectedRevision),
    op.kind,
    op.signer.identityID,
    base64url(op.signer.publicKey),
    base64url(digest(op.body))
  ];
}

export function decodeSignedOperation(value: unknown): SignedOperation {
  if (typeof value !== "object" || value === null) throw relayError("malformed");
  const v = value as Record<string, unknown>;
  const operationID = requireIdentifier(v.operationID, "operationID");
  const kind = requireIdentifier(v.kind, "kind");
  const signer = decodeDeviceIdentity(v.signer);
  const body = decodeData(v.body);
  const signature = decodeData(v.signature);
  if (body.length > MAX_OPERATION_BODY_BYTES) throw relayError("malformed");
  if (signature.length !== 64) throw relayError("malformed");
  let expectedRevision: number | null = null;
  if (v.expectedRevision !== undefined && v.expectedRevision !== null) {
    expectedRevision = requireSafeUint(v.expectedRevision);
  }
  return { operationID, expectedRevision, kind, signer, body, signature };
}

/**
 * Port of `SignedOperation.legacyOperationID(kind:signer:body:)`. Used only by
 * the un-enveloped "inbox" fetch operation (see
 * `DurableOperationFactory.makeInbox` / `CompanionClient.fetchInbox`), which
 * predates the `operationID`/`expectedRevision` envelope and derives its
 * operation ID from the command content instead.
 */
export function legacyOperationID(kind: string, signer: DeviceIdentity, body: Buffer): string {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.legacy-operation-id`, [
    kind,
    signer.identityID,
    base64url(digest(body))
  ]);
  return base64url(digest(bytes)).slice(0, 32);
}

function legacySigningFields(kind: string, signer: DeviceIdentity, body: Buffer): string[] {
  return [kind, signer.identityID, base64url(signer.publicKey), base64url(digest(body))];
}

export function verifySignedOperationSignature(op: SignedOperation): boolean {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.operation`, signedOperationSigningFields(op));
  if (ed25519Verify(bytes, op.signature, op.signer.publicKey)) return true;
  // Legacy un-enveloped operations sign a smaller, operationID-independent
  // field list and derive their operationID from the command content.
  // Mirrors `SignedOperation.validateSignature()`'s `hasDerivedLegacyID`
  // fallback in CompanionKit/Sources/CompanionKit/ProtocolModels.swift --
  // deliberately *not* restricted to kind == "inbox" here, because Swift's
  // own check isn't restricted by kind either: it is gated only on
  // `expectedRevision == nil && operationID == legacyOperationID(...)`,
  // for any kind. In practice only "inbox" is ever produced this way today
  // (`DurableOperationFactory.makeInbox`/`CompanionClient.fetchInbox`), but
  // this relay intentionally matches Swift's actual (kind-independent) gate
  // rather than narrowing it, so a client behavior change here would not
  // silently start rejecting a legacy-signed operation of some other kind.
  if (op.expectedRevision !== null) return false;
  if (op.operationID !== legacyOperationID(op.kind, op.signer, op.body)) return false;
  const legacyBytes = canonicalBytes(`${COMPANION_VERSION}.operation`, legacySigningFields(op.kind, op.signer, op.body));
  return ed25519Verify(legacyBytes, op.signature, op.signer.publicKey);
}

// ---------------------------------------------------------------------------
// Wire format note (contract update from Slice B1's iOS-side integration):
//
// Both the sync `CompanionClient` (CompanionKit/Sources/CompanionKit/ProtocolModels.swift)
// and the new async HTTP client send `SignedOperation.body` as the raw,
// sorted-key JSON of the command payload itself (Invitation, TrustedRequest,
// Approval, ...) -- there is no `DurableOperationEnvelope` wrapper on the
// wire. `SignedOperation.expectedRevision` is sent directly (often `null`,
// meaning "no optimistic revision check"); when non-null it must still be
// enforced. This relay never decodes an envelope: `operation.body` *is* the
// per-kind payload, and `operation.expectedRevision` *is* the optimistic
// revision check value, used directly by src/service.ts.
// ---------------------------------------------------------------------------
// RelayResult / RelayResponse / InboxResponse
// (wire shape verified against Swift's synthesized enum Codable in
// test/vectors.test.ts: a zero-payload case encodes as `{case: {}}`, a
// single-associated-value case as `{case: {_0: value}}`.)
// ---------------------------------------------------------------------------

export type RelayResult =
  | { kind: "invitation"; value: Invitation }
  | { kind: "consent"; value: RelationshipConsent }
  | { kind: "acceptance"; value: PairingAcceptance }
  | { kind: "pairing"; value: Pairing }
  | { kind: "session"; value: ActiveSession }
  | { kind: "request"; value: TrustedRequest }
  | { kind: "approval"; value: Approval }
  | { kind: "verification"; value: ApprovalVerification }
  | { kind: "acknowledgement" };

export function encodeRelayResult(result: RelayResult): object {
  switch (result.kind) {
    case "invitation":
      return { invitation: { _0: encodeInvitation(result.value) } };
    case "consent":
      return { consent: { _0: encodeRelationshipConsent(result.value) } };
    case "acceptance":
      return { acceptance: { _0: encodePairingAcceptance(result.value) } };
    case "pairing":
      return { pairing: { _0: encodePairing(result.value) } };
    case "session":
      return { session: { _0: encodeActiveSession(result.value) } };
    case "request":
      return { request: { _0: encodeTrustedRequest(result.value) } };
    case "approval":
      return { approval: { _0: encodeApproval(result.value) } };
    case "verification":
      return { verification: { _0: encodeApprovalVerification(result.value) } };
    case "acknowledgement":
      return { acknowledgement: {} };
  }
}

export interface RelayResponse {
  operationID: string;
  revision: number;
  result: RelayResult;
  /**
   * The identity ID of the ledger this operation *mutated* -- never simply
   * the signer. For an owner-signed operation that is the signer; for a
   * helper-signed operation (accept, consent accept, approval) it is the
   * other person's owner ID. Always populated on `/v1/operations` success
   * responses so the client can anchor `(revision, stateRoot)` per
   * docs/r5-relay-plan.md's "Independent monotonic anchor".
   */
  ownerIdentityID: string;
  /** Canonical root of *that owner's* ledger state only (see computeStateRoot in service.ts). */
  stateRoot: Buffer;
}

export function encodeRelayResponse(r: RelayResponse): object {
  return {
    operationID: r.operationID,
    revision: r.revision,
    result: encodeRelayResult(r.result),
    ownerIdentityID: r.ownerIdentityID,
    stateRoot: encodeData(r.stateRoot)
  };
}

export interface InboxResponse {
  /**
   * Populated only when the signer is an owner fetching their own ledger, in
   * which case it is that owner's identity ID and `stateRoot` is that
   * owner's canonical root -- the pair the client anchors on. Omitted
   * entirely (both fields) for a helper/approver inbox fetch, which can span
   * several owners' ledgers and has no single well-defined anchor; the
   * client does not anchor when they are absent.
   */
  ownerIdentityID?: string;
  stateRoot?: Buffer;
  revision: number;
  requests: TrustedRequest[];
  /** Every pairing where the signer is the owner or the approver, including revoked ones still within retention. */
  pairings: Pairing[];
  /** The current consent record (with its generation) for each pairing in `pairings`. */
  consents: RelationshipConsent[];
  /**
   * R5 Slice B2a (contract v1.2, additive): the relay-stored accepted
   * `Approval` for each request in `requests` whose status is `approved`, or
   * that has a recorded use. Same presence rule as `ownerIdentityID`/
   * `stateRoot` -- populated only when the signer is fetching their own
   * ledger as its owner, `undefined` (omitted from the wire body entirely,
   * not `null`) on a helper/approver fetch. Swift's `InboxResponse.approvals`
   * is `[Approval]?` and decodes its absence via `decodeIfPresent`.
   */
  approvals?: Approval[];
  /**
   * Pairing v3 (contract v1.4, additive): the friend-signed acceptance that
   * created each pairing in `pairings`, for pairings created by a v3 accept
   * that are still retained. Populated only on an owner fetch of their own
   * ledger (same presence rule as `approvals`); omitted on a helper fetch.
   * Because there is no owner "confirm" step any more, this is what lets the
   * owner device verify -- against the invite it created -- that a pairing
   * really came from the holder of its token, instead of trusting the relay's
   * word for who "joined" (see `JoinedAcceptanceCheck` in CompanionKit).
   * Swift's `InboxResponse.acceptances` is `[SignedAcceptance]?`.
   */
  acceptances?: SignedAcceptance[];
}

export function encodeInboxResponse(r: InboxResponse): object {
  const base: Record<string, unknown> = {
    revision: r.revision,
    requests: r.requests.map(encodeTrustedRequest),
    pairings: r.pairings.map(encodePairing),
    consents: r.consents.map(encodeRelationshipConsent)
  };
  if (r.ownerIdentityID !== undefined && r.stateRoot !== undefined) {
    base.ownerIdentityID = r.ownerIdentityID;
    base.stateRoot = encodeData(r.stateRoot);
  }
  if (r.approvals !== undefined) {
    base.approvals = r.approvals.map(encodeApproval);
  }
  if (r.acceptances !== undefined) {
    base.acceptances = r.acceptances.map(encodeSignedAcceptance);
  }
  return base;
}
