// Port of CompanionError (CompanionKit.swift) and DurableRelayError
// (CompanionRelayService/DurableOperation.swift). One flat error type is used
// on the TS side; `code` is what a client (or our own HTTP layer) sees, and
// mirrors `CompanionError.transportCode` / the Swift error case names.
//
// Per docs/r5-relay-plan.md: "Error bodies are `{ "error": "<code>" }` ... no
// echo of input, no stack traces." `RelayError` carries a `code` and nothing
// else that could leak request content; the HTTP layer never serializes a
// message string.

export type RelayErrorCode =
  | "malformed"
  | "invalid_signature"
  | "unknown_identity"
  | "unauthorized"
  | "revoked_pairing"
  | "expired"
  | "replay"
  | "stale_session"
  | "wrong_target"
  | "wrong_verification_code"
  | "rate_limited"
  | "already_paired"
  | "not_found"
  | "invalid_transition"
  | "stale_revision"
  | "operation_conflict"
  | "unsupported_scope"
  | "consent_required"
  | "invalid_envelope"
  | "idempotency_conflict"
  | "unknown_owner"
  | "unsupported_operation"
  | "revision_overflow"
  | "payload_too_large"
  | "internal";

export class RelayError extends Error {
  readonly code: RelayErrorCode;
  /** HTTP status this error maps to (see docs/r5-relay-plan.md's HTTP API table). */
  readonly status: number;

  constructor(code: RelayErrorCode, status: number) {
    super(code);
    this.code = code;
    this.status = status;
    this.name = "RelayError";
  }
}

export const STATUS_BY_CODE: Record<RelayErrorCode, number> = {
  malformed: 400,
  invalid_envelope: 400,
  invalid_signature: 401,
  unknown_identity: 401,
  unauthorized: 403,
  revoked_pairing: 403,
  wrong_target: 403,
  wrong_verification_code: 403,
  unsupported_scope: 403,
  consent_required: 403,
  unsupported_operation: 403,
  unknown_owner: 403,
  expired: 409,
  replay: 409,
  stale_session: 409,
  already_paired: 409,
  invalid_transition: 409,
  stale_revision: 409,
  operation_conflict: 409,
  idempotency_conflict: 409,
  not_found: 404,
  rate_limited: 429,
  payload_too_large: 413,
  revision_overflow: 409,
  internal: 500
};

export function relayError(code: RelayErrorCode): RelayError {
  return new RelayError(code, STATUS_BY_CODE[code]);
}

export function isRelayError(value: unknown): value is RelayError {
  return value instanceof RelayError;
}
