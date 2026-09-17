import XCTest
@testable import PhoneLockboxCore

final class TaskUnlockTests: XCTestCase {
    private let created = Date(timeIntervalSinceReferenceDate: 10_000)
    private let start = Date(timeIntervalSinceReferenceDate: 10_100)
    private let cutoff = Date(timeIntervalSinceReferenceDate: 11_000)

    private func policy() throws -> TaskUnlockPolicyReference {
        try TaskUnlockPolicyReference(policyID: UUID(), revision: 4)
    }

    private func commitment(
        kind: TaskProviderKind = .morningSteps,
        state: TaskCommitmentState = .committed,
        evidenceID: UUID? = nil
    ) throws -> TaskCommitment {
        let configuration: TaskProviderConfiguration
        switch kind {
        case .morningSteps: configuration = try .morningSteps()
        case .privatePhotoRitual: configuration = try .privatePhotoRitual()
        case .mathChallenge: configuration = try .mathChallenge()
        }
        return try TaskCommitment(
            sessionID: UUID(),
            providerConfiguration: configuration,
            createdAt: created,
            startAt: start,
            cutoffAt: cutoff,
            policyReference: try policy(),
            state: state,
            completionEvidenceIdentifier: evidenceID
        )
    }

    private func evidence(for commitment: TaskCommitment, id: UUID = UUID(), observedAt: Date? = nil) -> TaskCompletionEvidence {
        TaskCompletionEvidence(
            evidenceIdentifier: id,
            commitmentID: commitment.id,
            sessionID: commitment.sessionID,
            providerKind: commitment.providerConfiguration.kind,
            providerVersion: commitment.providerConfiguration.version,
            observedAt: observedAt ?? start.addingTimeInterval(10)
        )
    }

    func testBuiltInProviderConfigurationsAreVersionedAndPrivacyMinimal() throws {
        let steps = try TaskProviderConfiguration.morningSteps()
        XCTAssertEqual(steps.kind, .morningSteps)
        XCTAssertEqual(steps.version, 1)
        XCTAssertEqual(steps.parameters, ["targetSteps": "2000"])

        let photo = try TaskProviderConfiguration.privatePhotoRitual()
        XCTAssertEqual(photo.parameters, ["confirmation": "required", "storage": "none"])
        XCTAssertThrowsError(try TaskProviderConfiguration(
            kind: .privatePhotoRitual,
            version: 1,
            parameters: ["photoBytes": "raw-image"]
        ))
        XCTAssertThrowsError(try TaskProviderConfiguration.morningSteps(targetSteps: 0))
        XCTAssertThrowsError(try TaskProviderConfiguration.mathChallenge(problemCount: 11))
    }

    func testUnknownFutureVersionRetainsOnlyKnownPrivacySafeKeys() throws {
        let configuration = try TaskProviderConfiguration.morningSteps(version: 2, targetSteps: 500)
        XCTAssertEqual(configuration.version, 2)
        XCTAssertThrowsError(try TaskProviderConfiguration(
            kind: .morningSteps,
            version: 2,
            parameters: ["stepsSampleData": "private-data"]
        ))
        XCTAssertThrowsError(try TaskProviderConfiguration(
            kind: .morningSteps,
            version: 2,
            parameters: ["targetSteps": "private-data"]
        ))
    }

    func testCommitmentRequiresFiniteOrderedExactSessionBounds() throws {
        XCTAssertThrowsError(try TaskCommitment(
            sessionID: UUID(), providerConfiguration: try .mathChallenge(), createdAt: created,
            startAt: start, cutoffAt: start, policyReference: try policy()
        ))
        XCTAssertThrowsError(try TaskCommitment(
            sessionID: UUID(), providerConfiguration: try .mathChallenge(), createdAt: .distantFuture,
            startAt: start, cutoffAt: cutoff, policyReference: try policy()
        ))
        XCTAssertThrowsError(try TaskCommitment(
            sessionID: UUID(), providerConfiguration: try .mathChallenge(), createdAt: created,
            startAt: start, cutoffAt: cutoff, policyReference: try TaskUnlockPolicyReference(revision: -1)
        ))
    }

    func testActivationFreezesProviderPolicySessionAndCutoff() throws {
        let sessionID = UUID()
        let selectedPolicy = try policy()
        var commitment = try TaskCommitment(
            sessionID: sessionID, providerConfiguration: try .morningSteps(), createdAt: created,
            startAt: start, cutoffAt: cutoff, policyReference: selectedPolicy
        )
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        XCTAssertEqual(commitment.state, .active)
        XCTAssertEqual(commitment.sessionID, sessionID)
        XCTAssertEqual(commitment.policyReference, selectedPolicy)
        XCTAssertEqual(commitment.cutoffAt, cutoff)
        XCTAssertEqual(commitment.apply(.start(at: start.addingTimeInterval(1))), .rejected)
    }

    func testCompletionIsAcceptedThenSameIdentifierIsDuplicateAndOtherIsReplay() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        let identifier = UUID()
        let first = evidence(for: commitment, id: identifier)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: first, receivedAt: start.addingTimeInterval(20), providerResult: .accepted)), .completion(.accepted))
        XCTAssertEqual(commitment.state, .completionEligible)
        XCTAssertEqual(commitment.completionEvidenceIdentifier, identifier)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: first, receivedAt: start.addingTimeInterval(21), providerResult: .accepted)), .completion(.duplicate))
        let other = evidence(for: commitment)
        XCTAssertEqual(commitment.decideCompletion(evidence: other, receivedAt: start.addingTimeInterval(22), providerResult: .accepted), .replay)
        XCTAssertEqual(commitment.state, .completionEligible)
    }

    func testCompletionRequiresExactCommitmentSessionProviderAndVersion() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        var wrongCommitment = evidence(for: commitment)
        wrongCommitment = TaskCompletionEvidence(
            evidenceIdentifier: wrongCommitment.evidenceIdentifier, commitmentID: UUID(), sessionID: commitment.sessionID,
            providerKind: .morningSteps, providerVersion: 1, observedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(commitment.decideCompletion(evidence: wrongCommitment, receivedAt: start.addingTimeInterval(1), providerResult: .accepted), .wrongCommitment)
        let wrongSession = TaskCompletionEvidence(
            commitmentID: commitment.id, sessionID: UUID(), providerKind: .morningSteps, providerVersion: 1,
            observedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(commitment.decideCompletion(evidence: wrongSession, receivedAt: start.addingTimeInterval(1), providerResult: .accepted), .wrongSession)
        let wrongProvider = TaskCompletionEvidence(
            commitmentID: commitment.id, sessionID: commitment.sessionID, providerKind: .mathChallenge, providerVersion: 1,
            observedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(commitment.decideCompletion(evidence: wrongProvider, receivedAt: start.addingTimeInterval(1), providerResult: .accepted), .wrongProvider)
        let wrongVersion = TaskCompletionEvidence(
            commitmentID: commitment.id, sessionID: commitment.sessionID, providerKind: .morningSteps, providerVersion: 2,
            observedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(commitment.decideCompletion(evidence: wrongVersion, receivedAt: start.addingTimeInterval(1), providerResult: .accepted), .wrongProviderVersion)
    }

    func testProviderRejectionAndUnavailableDoNotComplete() throws {
        for result in [TaskProviderEvaluation.rejected, .unavailable] {
            var commitment = try commitment()
            XCTAssertEqual(commitment.apply(.start(at: start)), .started)
            XCTAssertEqual(commitment.apply(.submitCompletion(evidence: evidence(for: commitment), receivedAt: start.addingTimeInterval(1), providerResult: result)), .completion(result == .rejected ? .providerRejected : .providerUnavailable))
            XCTAssertEqual(commitment.state, .active)
        }
    }

    func testLateObservationAndLateDeliveryCannotComplete() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        let observedLate = evidence(for: commitment, observedAt: cutoff)
        XCTAssertEqual(commitment.decideCompletion(evidence: observedLate, receivedAt: cutoff.addingTimeInterval(-1), providerResult: .accepted), .lateEvidence)
        let deliveredLate = evidence(for: commitment, observedAt: start.addingTimeInterval(1))
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: deliveredLate, receivedAt: cutoff, providerResult: .accepted)), .naturallyExpired)
        XCTAssertEqual(commitment.state, .naturallyExpired)
    }

    func testNaturalCutoffWinsAtBoundaryAfterCompletionWasEligible() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        let completion = evidence(for: commitment)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: completion, receivedAt: cutoff.addingTimeInterval(-1), providerResult: .accepted)), .completion(.accepted))
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: completion, receivedAt: cutoff, providerResult: .accepted)), .naturallyExpired)
        XCTAssertEqual(commitment.apply(.naturalCutoff(at: cutoff)), .naturallyExpired)
        XCTAssertEqual(commitment.state, .naturallyExpired)
        XCTAssertEqual(commitment.decideCompletion(evidence: completion, receivedAt: cutoff.addingTimeInterval(1), providerResult: .accepted), .naturalCutoffWins)
    }

    func testCompletionCannotStartOrExtendAnotherSession() throws {
        var commitment = try commitment()
        let before = commitment
        let beforeStartEvidence = evidence(for: commitment, observedAt: start.addingTimeInterval(-1))
        XCTAssertEqual(commitment.decideCompletion(evidence: beforeStartEvidence, receivedAt: start.addingTimeInterval(-1), providerResult: .accepted), .notActive)
        XCTAssertEqual(commitment.state, .committed)
        XCTAssertEqual(commitment.cutoffAt, before.cutoffAt)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: evidence(for: commitment), receivedAt: start, providerResult: .accepted)), .completion(.notActive))
        XCTAssertEqual(commitment.state, .committed)
    }

    func testEarlyReleaseRequiresCompletionAndExactIndependentAuthorization() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        let noCompletionAuthorization = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start)
        XCTAssertEqual(commitment.apply(.releaseEarly(at: start.addingTimeInterval(1), authorization: noCompletionAuthorization)), .rejected)
        let completion = evidence(for: commitment)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: completion, receivedAt: start.addingTimeInterval(2), providerResult: .accepted)), .completion(.accepted))
        let wrongSession = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: UUID(), grantedAt: start.addingTimeInterval(3))
        XCTAssertEqual(commitment.apply(.releaseEarly(at: start.addingTimeInterval(4), authorization: wrongSession)), .rejected)
        let friend = TaskReleaseAuthorization(source: .exactSessionFriendApproval, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start.addingTimeInterval(3), approvalIdentifier: UUID())
        XCTAssertEqual(commitment.apply(.releaseEarly(at: start.addingTimeInterval(5), authorization: friend)), .releasedEarly)
        XCTAssertEqual(commitment.state, .releasedEarly)
    }

    func testRecoveryAuthorizationIsIndependentOfFriendApproval() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: evidence(for: commitment), receivedAt: start.addingTimeInterval(1), providerResult: .accepted)), .completion(.accepted))
        let recovery = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start.addingTimeInterval(2))
        XCTAssertEqual(commitment.apply(.releaseEarly(at: start.addingTimeInterval(3), authorization: recovery)), .releasedEarly)
        XCTAssertNil(recovery.approvalIdentifier)
    }

    func testCancellationAndFutureDisableOnlyApplyBeforeCommitmentStarts() throws {
        var cancelled = try commitment()
        XCTAssertEqual(cancelled.apply(.cancel(at: start.addingTimeInterval(-1))), .cancelled)
        XCTAssertEqual(cancelled.apply(.start(at: start)), .rejected)

        var disabled = try commitment()
        XCTAssertEqual(disabled.apply(.disableFuture(at: start.addingTimeInterval(-1))), .disabledForFuture)
        XCTAssertEqual(disabled.state, .disabledForFuture)

        var active = try commitment()
        XCTAssertEqual(active.apply(.start(at: start)), .started)
        XCTAssertEqual(active.apply(.disableFuture(at: start.addingTimeInterval(1))), .futureDisableRecorded)
        XCTAssertEqual(active.state, .active)
        XCTAssertEqual(active.cutoffAt, cutoff)
    }

    func testTerminalTransitionsAreIdempotentAndDoNotReclassifyEarlyRelease() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: evidence(for: commitment), receivedAt: start.addingTimeInterval(1), providerResult: .accepted)), .completion(.accepted))
        let authorization = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start.addingTimeInterval(2))
        XCTAssertEqual(commitment.apply(.releaseEarly(at: start.addingTimeInterval(3), authorization: authorization)), .releasedEarly)
        XCTAssertEqual(commitment.apply(.naturalCutoff(at: cutoff)), .rejected)
        XCTAssertEqual(commitment.state, .releasedEarly)
        XCTAssertEqual(commitment.apply(.releaseEarly(at: cutoff.addingTimeInterval(1), authorization: authorization)), .rejected)
        XCTAssertEqual(commitment.state, .releasedEarly)
    }

    func testSettingsRevisionChangesOnlyForFutureCommitments() {
        var settings = TaskUnlockSettings()
        XCTAssertFalse(settings.setEnabled(false))
        XCTAssertTrue(settings.setEnabled(true))
        XCTAssertEqual(settings.revision, 1)
        XCTAssertFalse(settings.setEnabled(true))
        XCTAssertEqual(settings.revision, 1)
    }

    func testCommitmentRoundTripPreservesFrozenSnapshot() throws {
        var original = try commitment()
        XCTAssertEqual(original.apply(.start(at: start)), .started)
        XCTAssertEqual(original.apply(.submitCompletion(evidence: evidence(for: original), receivedAt: start.addingTimeInterval(1), providerResult: .accepted)), .completion(.accepted))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskCommitment.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
