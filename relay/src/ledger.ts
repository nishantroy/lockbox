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
  RelationshipConsent,
  SignedAcceptance,
  TrustedRequest
} from "./protocol.js";

export interface LedgerInvitation {
  invitation: Invitation;
  consumedAt: number | null;
}

export interface LedgerPairing {
  pairing: Pairing;
  revokedAt: number | null;
  /** Pairing v3: the friend-signed acceptance that created this pairing, retained so the owner's inbox can deliver it for local verification. Absent for replace_pairing and pre-v3 rows. */
  acceptance?: SignedAcceptance;
}

export interface LedgerSession {
  session: ActiveSession;
  publishedAt: number;
}

export interface LedgerRequest {
  request: TrustedRequest;
  cancelledAt: number | null;
  expiredAt: number | null;
  /**
   * When the request's status became "declined", set once by the reducer.
   * Without this, a terminal-marker recomputation (src/service.ts's
   * `recordTerminalMarkers`, run after every unrelated commit for the same
   * owner) would have to guess a declined request's terminal time from
   * current wall-clock `now` each time, continually pushing its retention
   * clock forward and letting it dodge purge indefinitely.
   */
  declinedAt: number | null;
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
  /**
   * Pairing v2 leftovers only. v3 has no pending-acceptance step (accept
   * activates the pairing directly), so nothing writes or reads this any more.
   * It is deliberately NOT removed from rows that already carry it: the
   * owner state root is a hash of the serialized ledger, so dropping or
   * adding the key on read would make every pre-existing owner row fail its
   * integrity check. New ledgers simply never get the key.
   */
  pendingAcceptances?: Record<string, unknown>;
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

/**
 * A prototype-less dictionary. Every ID-keyed ledger map uses this instead of
 * `{}` because every key is at least partly attacker/client-chosen (request,
 * approval, use, session, pairing, invitation, acceptance IDs are free-form
 * strings from a signed payload, only length/whitespace-validated). On a
 * normal `{}` object, `map[key] = value` for `key === "__proto__"` invokes
 * `Object.prototype`'s special `__proto__` setter instead of creating an own
 * property, which can silently repoint the object's prototype. A
 * null-prototype object has no such accessor, so bracket assignment with any
 * string key -- including `__proto__`, `constructor`, `toString` -- always
 * behaves as a plain own-property write.
 */
export function nullProtoMap<T>(source?: Record<string, T>): Record<string, T> {
  const map: Record<string, T> = Object.create(null);
  if (source) {
    for (const key of Object.keys(source)) map[key] = source[key] as T;
  }
  return map;
}

export function emptyLedger(owner: DeviceIdentity): Ledger {
  return {
    owner,
    invitations: nullProtoMap(),
    pairings: nullProtoMap(),
    pairingEpochs: nullProtoMap(),
    sessions: nullProtoMap(),
    currentSessionID: null,
    requests: nullProtoMap(),
    approvals: nullProtoMap(),
    approvalUses: nullProtoMap(),
    relationshipConsents: nullProtoMap(),
    usedConsentNonces: nullProtoMap(),
    usedApprovalIDs: nullProtoMap(),
    usedApprovalNonces: nullProtoMap(),
    rateLimits: nullProtoMap()
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

const MAP_FIELDS: Array<keyof Ledger> = [
  "invitations",
  "pairings",
  "pairingEpochs",
  "sessions",
  "requests",
  "approvals",
  "approvalUses",
  "relationshipConsents",
  "usedConsentNonces",
  "usedApprovalIDs",
  "usedApprovalNonces",
  "rateLimits"
];

export function deserializeLedger(text: string): Ledger {
  const parsed = JSON.parse(text, ledgerReviver) as Ledger;
  // `JSON.parse` itself is safe from `__proto__` pollution (it defines own
  // properties rather than assigning through `[[Set]]`), but the resulting
  // objects still have the ordinary `Object.prototype` -- convert each
  // ID-keyed map to the same null-prototype shape `emptyLedger`/the reducer
  // use, so later `map[key] = value` bracket assignments elsewhere in this
  // ledger's lifetime stay safe too.
  for (const field of MAP_FIELDS) {
    (parsed as unknown as Record<string, unknown>)[field] = nullProtoMap(parsed[field] as Record<string, unknown>);
  }
  for (const record of Object.values(parsed.requests)) {
    record.request.decisions = nullProtoMap(record.request.decisions);
    if (record.declinedAt === undefined) record.declinedAt = null;
  }
  return parsed;
}
