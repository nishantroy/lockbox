import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class RecoveryCommitmentTests: XCTestCase {
    func testEligibilityUsesTheExact900SecondDelay() throws {
        let requestedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let commitment = try RecoveryCommitment(sessionIDs: [UUID()], requestedAt: requestedAt)

        XCTAssertEqual(commitment.eligibleAt, requestedAt.addingTimeInterval(900))
        XCTAssertFalse(commitment.isEligible(at: requestedAt.addingTimeInterval(899), activeSessionIDs: commitment.sessionIDs))
        XCTAssertTrue(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: commitment.sessionIDs))
    }

    func testRoundTripPreservesDuplicateTargetAssociation() throws {
        let first = UUID()
        let second = UUID()
        let commitment = try RecoveryCommitment(
            sessionIDs: [first, second],
            requestedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        let data = try JSONEncoder().encode(commitment)
        let decoded = try JSONDecoder().decode(RecoveryCommitment.self, from: data)

        XCTAssertEqual(decoded, commitment)
        XCTAssertTrue(decoded.isEligible(at: decoded.eligibleAt, activeSessionIDs: [first, second]))
    }

    func testNewSessionCannotUseAnOlderCommitment() throws {
        let original = UUID()
        let newSession = UUID()
        let commitment = try RecoveryCommitment(sessionIDs: [original], requestedAt: .now)

        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [newSession]))
        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [original, newSession]))
    }

    func testNaturalExpiryAllowsOnlyTheRemainingTargetSubset() throws {
        let expired = UUID()
        let remaining = UUID()
        let commitment = try RecoveryCommitment(sessionIDs: [expired, remaining], requestedAt: .now)

        XCTAssertTrue(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [remaining]))
        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: []))
        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [UUID()]))
    }

    func testInvalidClockAndTargetValuesAreRejected() {
        XCTAssertThrowsError(try RecoveryCommitment(sessionIDs: [], requestedAt: .now))
        XCTAssertThrowsError(try RecoveryCommitment(
            sessionIDs: [UUID()],
            requestedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        ))
        XCTAssertThrowsError(try RecoveryCommitment(
            sessionIDs: [UUID()],
            requestedAt: Date(timeIntervalSinceReferenceDate: -.infinity)
        ))
    }

    func testFiniteButUnrepresentableDelayIsRejected() {
        XCTAssertThrowsError(try RecoveryCommitment(
            sessionIDs: [UUID()],
            requestedAt: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
        ))
        XCTAssertThrowsError(try RecoveryCommitment(
            sessionIDs: [UUID()],
            requestedAt: Date(timeIntervalSinceReferenceDate: Double.nan)
        ))
    }

    func testDecodeRejectsEditedEligibilityAndMalformedValues() throws {
        let id = UUID()
        let requestedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        let commitment = try RecoveryCommitment(sessionIDs: [id], requestedAt: requestedAt)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(commitment)) as! [String: Any]

        var edited = encoded
        edited["eligibleAt"] = requestedAt.addingTimeInterval(899).timeIntervalSinceReferenceDate
        let editedData = try JSONSerialization.data(withJSONObject: edited)
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryCommitment.self, from: editedData))

        let emptyTargets: [String: Any] = [
            "sessionIDs": [],
            "requestedAt": requestedAt.timeIntervalSinceReferenceDate,
            "eligibleAt": requestedAt.addingTimeInterval(900).timeIntervalSinceReferenceDate
        ]
        let emptyData = try JSONSerialization.data(withJSONObject: emptyTargets)
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryCommitment.self, from: emptyData))

        let nonFiniteClock: [String: Any] = [
            "sessionIDs": [id.uuidString],
            "requestedAt": "not-a-date",
            "eligibleAt": requestedAt.addingTimeInterval(900).timeIntervalSinceReferenceDate
        ]
        let malformedData = try JSONSerialization.data(withJSONObject: nonFiniteClock)
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryCommitment.self, from: malformedData))
    }
}
