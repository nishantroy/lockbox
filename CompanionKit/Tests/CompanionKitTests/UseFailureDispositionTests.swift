import XCTest
@testable import CompanionKit

/// R5 Slice B2a review fix (N2):
/// `AsyncCompanionClient.UseFailureDisposition.classify(_:)`. Every case
/// name below is the exact wire error code from
/// `relay/test/fixtures/error-codes.json`, paired with the Swift
/// `CompanionError`/`CompanionTransportError` case it decodes to.
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

    // MARK: - definitive

    func testEveryListedDefinitiveCodeClassifiesAsDefinitive() {
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

    // MARK: - integrityFatal

    func testAnAnchorRollbackOrForkIsIntegrityFatal() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.relayRollback(.regressedRevision(expected: 5, actual: 3)))), .integrityFatal)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.relayRollback(.conflictingRoot(revision: 5)))), .integrityFatal)
    }

    func testAnUndecodableResponseIsIntegrityFatal() {
        XCTAssertEqual(Disposition.classify(CompanionTransportError.malformedResponse), .integrityFatal)
    }

    func testABareCompanionErrorThrownDirectlyByValidateUseVerificationIsIntegrityFatal() {
        // These are exactly the shapes `validateUseVerification`
        // (`ProtocolModels.swift`) throws directly -- never wrapped in
        // `CompanionTransportError.server` -- when the relay's "use"
        // response fails local verification (wrong approval/useID, a
        // request-binding mismatch, a non-approved decision).
        XCTAssertEqual(Disposition.classify(CompanionError.malformed("relay use verification does not match the submitted approval")), .integrityFatal)
        XCTAssertEqual(Disposition.classify(CompanionError.wrongTarget), .integrityFatal)
    }

    func testABareInvalidSignatureIsIntegrityFatalWhileAWrappedOneIsDefinitive() {
        // The crux of the N2 classifier: the SAME `CompanionError` case
        // means two different things depending on whether the HTTP
        // transport wrapped it (the relay rejected the submitted
        // operation's own signature -- a definitive, non-retryable client
        // bug) or it was thrown bare (this device's own check on the
        // relay's claimed verification response failed -- the response
        // itself cannot be trusted).
        XCTAssertEqual(Disposition.classify(CompanionError.invalidSignature), .integrityFatal)
        XCTAssertEqual(Disposition.classify(CompanionTransportError.server(.invalidSignature)), .definitive)
    }

    func testUnrecognizedServerCodesDefaultToIntegrityFatal() {
        let unclassifiedErrors: [CompanionError] = [
            .malformed("unrecognized relay error: pairing_conflict"),
            .unknownIdentity, .staleSession, .wrongVerificationCode, .keyUnavailable,
            .alreadyPaired, .invalidTransition, .missingOperationRevision, .unsupportedScope
        ]
        for error in unclassifiedErrors {
            XCTAssertEqual(Disposition.classify(CompanionTransportError.server(error)), .integrityFatal,
                           "expected \(error) to classify as .integrityFatal")
        }
    }

    func testAnUnrelatedErrorTypeDefaultsToIntegrityFatal() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(Disposition.classify(SomeOtherError()), .integrityFatal)
    }
}
