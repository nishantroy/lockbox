import XCTest
@testable import CompanionKit

/// R5 Slice B2a review fixes (N2, then N3):
/// `AsyncCompanionClient.UseFailureDisposition.classify(_:)`. Every case
/// name below is the exact wire error code from
/// `relay/test/fixtures/error-codes.json`, paired with the Swift
/// `CompanionError`/`CompanionTransportError` case it decodes to.
///
/// N3 narrowed `integrityFatal` to exactly three things:
/// `.responseVerificationFailed` (bare or wrapped), `.relayRollback` (bare
/// or wrapped) and `CompanionTransportError.malformedResponse`. Every other
/// bare `CompanionError` -- including one thrown by a LOCAL pre-call guard
/// in `useApproval` (owner-identity check, keychain/signing failure, a
/// malformed `SignedOperation`) -- is `.definitive`, same as the
/// corresponding wrapped `.server(...)` code (including `.malformed`, which
/// moved out of the old integrityFatal catch-all).
final class UseFailureDispositionTests: XCTestCase {
    private typealias Disposition = AsyncCompanionClient.UseFailureDisposition

    // MARK: - retryable

    func testTransportUnavailableAndTimedOutAreRetryable() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.unavailable), .retryable)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.timedOut), .retryable)
    }

    func test5xxIsRetryableBecauseTheTransportMapsItToUnavailable() {
        // HTTPCompanionTransport maps every 5xx status to `.unavailable`
        // before any `CompanionError` is ever produced -- see
        // `transportError(status:data:)`. There is nothing further to
        // classify here; this documents that contract.
        XCTAssertEqual(Disposition.classify(CompanionTransportError.unavailable), .retryable)
    }

    func testRateLimitedIsRetryable() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.rateLimited)), .retryable)
    }

    func testRelayStaleRevisionIsRetryable() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.staleRevision(expected: 1, actual: 2))), .retryable)
    }

    // MARK: - definitive: wrapped (relay-originated) codes

    func testEveryListedDefinitiveCodeClassifiesAsDefinitiveWhenWrapped() {
        let definitiveErrors: [CompanionError] = [
            .replay, .expired, .wrongTarget, .unauthorized, .notFound,
            .consentRequired, .revokedPairing, .invalidSignature, .operationConflict
        ]
        for error in definitiveErrors {
            XCTAssertEqual(Disposition.classify(CompanionTransportError.server(error)), .definitive,
                           "expected \(error) to classify as .definitive")
        }
    }

    func testIdempotencyConflictWireCodeDecodesToOperationConflictAndClassifiesAsDefinitive() {
        // `fromTransportCode("idempotency_conflict")` and
        // `fromTransportCode("operation_conflict")` both decode to the same
        // Swift case, `.operationConflict`.
        XCTAssertEqual(CompanionError.fromTransportCode("idempotency_conflict"), .operationConflict)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.fromTransportCode("idempotency_conflict"))), .definitive)
    }

    /// N3: `.server(.malformed)` (a 400, or a 413 "payload too large" --
    /// both decode to `.malformed`) moved out of the old integrityFatal
    /// catch-all; it is a definitive rejection of the submitted command.
    func testWrappedMalformedIncludingPayloadTooLargeIsDefinitive() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.malformed("relay rejected the operation"))), .definitive)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.fromTransportCode("payload_too_large"))), .definitive)
    }

    /// N3: every other wrapped server code not explicitly named elsewhere
    /// is also definitive now -- the only wrapped codes left in
    /// `integrityFatal` are `.relayRollback` and `.responseVerificationFailed`.
    func testEveryOtherWrappedServerCodeIsDefinitive() {
        let otherErrors: [CompanionError] = [
            .unknownIdentity, .staleSession, .wrongVerificationCode, .keyUnavailable,
            .alreadyPaired, .invalidTransition, .missingOperationRevision, .unsupportedScope
        ]
        for error in otherErrors {
            XCTAssertEqual(Disposition.classify(CompanionTransportError.server(error)), .definitive,
                           "expected \(error) to classify as .definitive")
        }
    }

    // MARK: - definitive: bare (local pre-call guard) errors

    /// N3: a bare `CompanionError` is not always a failed-verification
    /// response -- `useApproval`'s own pre-call guards throw these same
    /// cases directly. They are ordinary definitive rejections of this
    /// call, not integrity failures.
    func testBareErrorsFromLocalPreCallGuardsAreDefinitive() {
        // The owner-identity guard at the top of `useApproval`.
        XCTAssertEqual(Disposition.classify(CompanionError.unauthorized), .definitive)
        // A keychain/signing failure (`DeviceSigner.sign`).
        XCTAssertEqual(Disposition.classify(CompanionError.keyUnavailable), .definitive)
        // A malformed `SignedOperation` (its validating initializer throws
        // `.malformed` for an oversized body, etc.).
        XCTAssertEqual(Disposition.classify(CompanionError.malformed("invalid operation")), .definitive)
    }

    func testEveryOtherBareCompanionErrorIsDefinitive() {
        let bareErrors: [CompanionError] = [
            .malformed("x"), .invalidSignature, .unknownIdentity, .unauthorized,
            .revokedPairing, .expired, .replay, .staleSession, .wrongTarget,
            .wrongVerificationCode, .rateLimited, .keyUnavailable, .alreadyPaired,
            .notFound, .invalidTransition, .staleRevision(expected: 1, actual: 1),
            .operationConflict, .missingOperationRevision, .unsupportedScope, .consentRequired
        ]
        for error in bareErrors {
            XCTAssertEqual(Disposition.classify(error), .definitive, "expected bare \(error) to classify as .definitive")
        }
    }

    // MARK: - integrityFatal

    func testAnAnchorRollbackOrForkIsIntegrityFatal() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.relayRollback(.regressedRevision(expected: 5, actual: 3)))), .integrityFatal)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.relayRollback(.conflictingRoot(revision: 5)))), .integrityFatal)
        // Defense in depth: a bare `.relayRollback` (should never actually
        // occur -- `validateAnchor` always wraps it) is still integrityFatal.
        XCTAssertEqual(Disposition.classify(CompanionError.relayRollback(.regressedRevision(expected: 5, actual: 3))), .integrityFatal)
    }

    func testAnUndecodableResponseIsIntegrityFatal() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.malformedResponse), .integrityFatal)
    }

    /// N3: a failed-verification "use" response -- the ONLY bare
    /// `CompanionError` case that is integrityFatal. `useApproval`
    /// (both sync and async) wraps every `validateUseVerification` failure,
    /// and the "relay response was not a verification" case, as this
    /// dedicated error specifically so it is distinguishable from the
    /// local pre-call guard failures above.
    func testResponseVerificationFailedIsIntegrityFatalBareOrWrapped() {
        XCTAssertEqual(Disposition.classify(CompanionError.responseVerificationFailed("wrong useID")), .integrityFatal)
        // Defense in depth: should never actually arrive wrapped, but is
        // still integrityFatal if it somehow did.
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.responseVerificationFailed("wrong useID"))), .integrityFatal)
    }

    func testAnUnrelatedErrorTypeDefaultsToDefinitive() {
        // N3: an unrecognized error type (e.g. `EncodingError` from
        // `JSONEncoder` inside `submit`) is a definitive rejection of this
        // call, not escalated to an integrity emergency.
        struct SomeOtherError: Error {}
        XCTAssertEqual(Disposition.classify(SomeOtherError()), .definitive)
    }
}
