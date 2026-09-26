// Port of CompanionRelayService's `DurableOwnerLedger`
// (CompanionRelayService/Sources/CompanionRelayService/DurableStore.swift).
//
// Unlike the Swift reference (which keeps the operation log inside the
// ledger snapshot), this TS ledger holds only *protocol* state; the durable
// operation/idempotency log lives in its own Postgres table
// (`companion_operation`, see migrations/001_init.sql and db.ts) per the
// `PostgreSQLDurableStoreContract` sketch in
// CompanionRelayService/Sources/CompanionRelayService/DurableRelay.swift.
//
// Every collection that can hold a terminal (no-longer-actionable) record
// also carries a `terminalAt` timestamp so the retention job
// (src/retention.ts) can find and delete it 30 days after it turned
// terminal, per docs/r5-relay-plan.md's owner-approved retention window.

import type {
  ActiveSession,
  Approval,
  DeviceIdentity,
  Invitation,
  Pairing,
  PairingAcceptance,
  RelationshipConsent,
  TrustedRequest
} from "./protocol.js";

export interface LedgerInvitation {
  invitation: Invitation;
  consumedAt: number | null;
}

export interface LedgerPairing {
  pairing: Pairing;
  revokedAt: number | null;
}

export interface LedgerSession {
  session: ActiveSession;
  publishedAt: number;
}

export interface LedgerRequest {
  request: TrustedRequest;
  cancelledAt: number | null;
  expiredAt: number | null;
}

export interface LedgerApproval {
  approval: Approval;
  acceptedAt: number;
}

export interface LedgerApprovalUse {
  useID: string;
  approvalID: string;
  requestID: string;
  usedAt: number;
  committedRevision: number;
}

/** A used one-time marker with the time it was recorded, for retention pruning. */
export interface Marker {
  createdAt: number;
}

export interface Ledger {
  owner: DeviceIdentity;
  invitations: Record<string, LedgerInvitation>;
  pendingAcceptances: Record<string, PairingAcceptance>;
  pairings: Record<string, LedgerPairing>;
  pairingEpochs: Record<string, number>;
  sessions: Record<string, LedgerSession>;
  currentSessionID: string | null;
  requests: Record<string, LedgerRequest>;
  approvals: Record<string, LedgerApproval>;
  approvalUses: Record<string, LedgerApprovalUse>;
  relationshipConsents: Record<string, RelationshipConsent>;
  usedConsentNonces: Record<string, Marker>;
  usedApprovalIDs: Record<string, Marker>;
  usedApprovalNonces: Record<string, Marker>;
  rateLimits: Record<string, number[]>;
}

export function emptyLedger(owner: DeviceIdentity): Ledger {
  return {
    owner,
    invitations: {},
    pendingAcceptances: {},
    pairings: {},
    pairingEpochs: {},
    sessions: {},
    currentSessionID: null,
    requests: {},
    approvals: {},
    approvalUses: {},
    relationshipConsents: {},
    usedConsentNonces: {},
    usedApprovalIDs: {},
    usedApprovalNonces: {},
    rateLimits: {}
  };
}

// ---------------------------------------------------------------------------
// JSON (de)serialization with Buffer support, for the `companion_owner.state`
// TEXT column (kept as TEXT, not a native jsonb column, precisely so we
// control (de)serialization of Buffer fields ourselves rather than relying on
// the driver's jsonb type parser -- see db.ts).
// ---------------------------------------------------------------------------

const BUFFER_MARKER = "$b64";

export function ledgerReplacer(_key: string, value: unknown): unknown {
  if (value && typeof value === "object" && (value as { type?: string }).type === "Buffer" && Array.isArray((value as { data?: unknown }).data)) {
    // Defensive: Buffer's default toJSON() shape, in case it slips through
    // before this replacer sees the raw Buffer instance.
    return { [BUFFER_MARKER]: Buffer.from((value as { data: number[] }).data).toString("base64") };
  }
  if (Buffer.isBuffer(value)) {
    return { [BUFFER_MARKER]: value.toString("base64") };
  }
  return value;
}

export function ledgerReviver(_key: string, value: unknown): unknown {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record);
    if (keys.length === 1 && keys[0] === BUFFER_MARKER && typeof record[BUFFER_MARKER] === "string") {
      return Buffer.from(record[BUFFER_MARKER] as string, "base64");
    }
  }
  return value;
}

export function serializeLedger(ledger: Ledger): string {
  return JSON.stringify(ledger, ledgerReplacer);
}

export function deserializeLedger(text: string): Ledger {
  return JSON.parse(text, ledgerReviver) as Ledger;
}
