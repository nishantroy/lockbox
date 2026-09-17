import Foundation
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

    private func commitmentJSON(
        for original: TaskCommitment,
        state: TaskCommitmentState,
        evidencePresent: Bool
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["state"] = state.rawValue
        if evidencePresent {
            object["completionEvidenceIdentifier"] = UUID().uuidString
        } else {
            object.removeValue(forKey: "completionEvidenceIdentifier")
        }
        return try JSONSerialization.data(withJSONObject: object)
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

    func testReleaseUsesTrustedReceiptAndProcessingTimesNotGrantMetadata() throws {
        var receivedAtCutoff = try commitment()
        XCTAssertEqual(receivedAtCutoff.apply(.start(at: start)), .started)
        XCTAssertEqual(receivedAtCutoff.apply(.submitCompletion(
            evidence: evidence(for: receivedAtCutoff),
            receivedAt: cutoff.addingTimeInterval(-1),
            providerResult: .accepted
        )), .completion(.accepted))
        let backdatedGrant = TaskReleaseAuthorization(
            commitmentID: receivedAtCutoff.id,
            sessionID: receivedAtCutoff.sessionID,
            grantedAt: cutoff.addingTimeInterval(-10)
        )
        XCTAssertEqual(receivedAtCutoff.apply(.releaseEarly(
            authorization: backdatedGrant,
            receivedAt: cutoff,
            processedAt: cutoff.addingTimeInterval(1)
        )), .naturallyExpired)
        XCTAssertEqual(receivedAtCutoff.state, .naturallyExpired)

        var processedAfterCutoff = try commitment()
        XCTAssertEqual(processedAfterCutoff.apply(.start(at: start)), .started)
        XCTAssertEqual(processedAfterCutoff.apply(.submitCompletion(
            evidence: evidence(for: processedAfterCutoff),
            receivedAt: cutoff.addingTimeInterval(-20),
            providerResult: .accepted
        )), .completion(.accepted))
        let timelyGrant = TaskReleaseAuthorization(
            commitmentID: processedAfterCutoff.id,
            sessionID: processedAfterCutoff.sessionID,
            grantedAt: cutoff.addingTimeInterval(-30)
        )
        XCTAssertEqual(processedAfterCutoff.apply(.releaseEarly(
            authorization: timelyGrant,
            receivedAt: cutoff.addingTimeInterval(-2),
            processedAt: cutoff
        )), .naturallyExpired)
        XCTAssertEqual(processedAfterCutoff.state, .naturallyExpired)
    }

    func testLateReleaseAfterRelaunchCannotUseCompletionEligibleState() throws {
        var beforeRelaunch = try commitment()
        XCTAssertEqual(beforeRelaunch.apply(.start(at: start)), .started)
        XCTAssertEqual(beforeRelaunch.apply(.submitCompletion(
            evidence: evidence(for: beforeRelaunch),
            receivedAt: cutoff.addingTimeInterval(-1),
            providerResult: .accepted
        )), .completion(.accepted))
        let relaunched = try JSONDecoder().decode(
            TaskCommitment.self,
            from: JSONEncoder().encode(beforeRelaunch)
        )
        var afterRelaunch = relaunched
        let authorization = TaskReleaseAuthorization(
            commitmentID: afterRelaunch.id,
            sessionID: afterRelaunch.sessionID,
            grantedAt: cutoff.addingTimeInterval(-5)
        )
        XCTAssertEqual(afterRelaunch.apply(.releaseEarly(
            authorization: authorization,
            receivedAt: cutoff.addingTimeInterval(1),
            processedAt: cutoff.addingTimeInterval(2)
        )), .naturallyExpired)
        XCTAssertEqual(afterRelaunch.state, .naturallyExpired)
    }

    func testReleaseRejectsUnorderedLocalTimesAndGrantMetadataAfterReceipt() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        XCTAssertEqual(commitment.apply(.submitCompletion(
            evidence: evidence(for: commitment),
            receivedAt: start.addingTimeInterval(1),
            providerResult: .accepted
        )), .completion(.accepted))

        let grantAfterReceipt = TaskReleaseAuthorization(
            commitmentID: commitment.id,
            sessionID: commitment.sessionID,
            grantedAt: start.addingTimeInterval(20)
        )
        XCTAssertEqual(commitment.apply(.releaseEarly(
            authorization: grantAfterReceipt,
            receivedAt: start.addingTimeInterval(10),
            processedAt: start.addingTimeInterval(10)
        )), .rejected)
        XCTAssertEqual(commitment.state, .completionEligible)

        let unordered = TaskReleaseAuthorization(
            commitmentID: commitment.id,
            sessionID: commitment.sessionID,
            grantedAt: start.addingTimeInterval(5)
        )
        XCTAssertEqual(commitment.apply(.releaseEarly(
            authorization: unordered,
            receivedAt: start.addingTimeInterval(10),
            processedAt: start.addingTimeInterval(9)
        )), .rejected)
        XCTAssertEqual(commitment.state, .completionEligible)

        let nonFinite = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertEqual(commitment.apply(.releaseEarly(
            authorization: unordered,
            receivedAt: nonFinite,
            processedAt: nonFinite
        )), .rejected)
        XCTAssertEqual(commitment.state, .completionEligible)
    }

    func testCommitmentCodableRejectsImpossibleEvidenceStates() throws {
        let original = try commitment()
        for state in [TaskCommitmentState.committed, .active, .cancelled, .disabledForFuture] {
            let data = try commitmentJSON(for: original, state: state, evidencePresent: true)
            XCTAssertThrowsError(try JSONDecoder().decode(TaskCommitment.self, from: data), "evidence in \(state) must be rejected")
        }
        for state in [TaskCommitmentState.completionEligible, .releasedEarly] {
            let data = try commitmentJSON(for: original, state: state, evidencePresent: false)
            XCTAssertThrowsError(try JSONDecoder().decode(TaskCommitment.self, from: data), "missing evidence in \(state) must be rejected")
        }

        var naturallyExpiredWithoutCompletion = try commitment()
        XCTAssertEqual(naturallyExpiredWithoutCompletion.apply(.naturalCutoff(at: cutoff)), .naturallyExpired)
        let noEvidenceData = try JSONEncoder().encode(naturallyExpiredWithoutCompletion)
        XCTAssertNoThrow(try JSONDecoder().decode(TaskCommitment.self, from: noEvidenceData))

        var naturallyExpiredAfterCompletion = try commitment()
        XCTAssertEqual(naturallyExpiredAfterCompletion.apply(.start(at: start)), .started)
        XCTAssertEqual(naturallyExpiredAfterCompletion.apply(.submitCompletion(
            evidence: evidence(for: naturallyExpiredAfterCompletion),
            receivedAt: cutoff.addingTimeInterval(-1),
            providerResult: .accepted
        )), .completion(.accepted))
        XCTAssertEqual(naturallyExpiredAfterCompletion.apply(.naturalCutoff(at: cutoff)), .naturallyExpired)
        XCTAssertNotNil(naturallyExpiredAfterCompletion.completionEvidenceIdentifier)
        let evidenceData = try JSONEncoder().encode(naturallyExpiredAfterCompletion)
        XCTAssertNoThrow(try JSONDecoder().decode(TaskCommitment.self, from: evidenceData))
    }

    func testFriendApprovalPlaceholderCannotBeDecodedAsLocalAuthorization() throws {
        let data = Data("""
        {"source":"exactSessionFriendApproval","commitmentID":"\(UUID().uuidString)","sessionID":"\(UUID().uuidString)","grantedAt":10100,"approvalIdentifier":"\(UUID().uuidString)"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskReleaseAuthorization.self, from: data))

        let recoveryWithFriendField = Data("""
        {"source":"recoveryConfirmation","commitmentID":"\(UUID().uuidString)","sessionID":"\(UUID().uuidString)","grantedAt":10100,"approvalIdentifier":"\(UUID().uuidString)"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskReleaseAuthorization.self, from: recoveryWithFriendField))
    }

    func testSettingsCodableRejectsNegativeAndOverflowRevisions() throws {
        let negative = Data(#"{"enabled":true,"revision":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskUnlockSettings.self, from: negative))

        let tooHigh = Data("{\"enabled\":true,\"revision\":\(TaskUnlockSettings.maxRevision + 1)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskUnlockSettings.self, from: tooHigh))

        let intMax = Data("{\"enabled\":false,\"revision\":\(Int.max)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskUnlockSettings.self, from: intMax))

        let atBound = try JSONDecoder().decode(
            TaskUnlockSettings.self,
            from: Data("{\"enabled\":false,\"revision\":\(TaskUnlockSettings.maxRevision)}".utf8)
        )
        var bounded = atBound
        XCTAssertFalse(bounded.setEnabled(true))
        XCTAssertFalse(bounded.enabled)
        XCTAssertEqual(bounded.revision, TaskUnlockSettings.maxRevision)
    }

    func testEarlyReleaseRequiresCompletionAndExactIndependentAuthorization() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        let noCompletionAuthorization = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start)
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: noCompletionAuthorization, receivedAt: start.addingTimeInterval(1), processedAt: start.addingTimeInterval(1))), .rejected)
        let completion = evidence(for: commitment)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: completion, receivedAt: start.addingTimeInterval(2), providerResult: .accepted)), .completion(.accepted))
        let wrongSession = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: UUID(), grantedAt: start.addingTimeInterval(3))
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: wrongSession, receivedAt: start.addingTimeInterval(4), processedAt: start.addingTimeInterval(4))), .rejected)
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start.addingTimeInterval(3)), receivedAt: start.addingTimeInterval(5), processedAt: start.addingTimeInterval(5))), .releasedEarly)
        XCTAssertEqual(commitment.state, .releasedEarly)
    }

    func testRecoveryAuthorizationIsTheOnlyLocalReleaseSource() throws {
        var commitment = try commitment()
        XCTAssertEqual(commitment.apply(.start(at: start)), .started)
        XCTAssertEqual(commitment.apply(.submitCompletion(evidence: evidence(for: commitment), receivedAt: start.addingTimeInterval(1), providerResult: .accepted)), .completion(.accepted))
        let recovery = TaskReleaseAuthorization(source: .recoveryConfirmation, commitmentID: commitment.id, sessionID: commitment.sessionID, grantedAt: start.addingTimeInterval(2))
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: recovery, receivedAt: start.addingTimeInterval(3), processedAt: start.addingTimeInterval(3))), .releasedEarly)
        XCTAssertEqual(recovery.source, .recoveryConfirmation)
    }

    func testCancellationAndFutureDisableOnlyApplyBeforeCommitmentStarts() throws {
        var cancelled = try commitment()
        XCTAssertEqual(cancelled.apply(.cancel(at: start.addingTimeInterval(-1))), .cancelled)
        XCTAssertEqual(cancelled.apply(.start(at: start)), .rejected)

        var cancellationAtStart = try commitment()
        // Activation is half-open. Cancellation is strictly pre-start, so the
        // same instant cannot cancel a commitment, regardless of event order.
        XCTAssertEqual(cancellationAtStart.apply(.cancel(at: start)), .rejected)
        XCTAssertEqual(cancellationAtStart.state, .committed)
        XCTAssertEqual(cancellationAtStart.apply(.start(at: start)), .started)
        XCTAssertEqual(cancellationAtStart.apply(.cancel(at: start)), .rejected)
        XCTAssertEqual(cancellationAtStart.state, .active)

        var disabled = try commitment()
        XCTAssertEqual(disabled.apply(.disableFuture(at: start.addingTimeInterval(-1))), .disabledForFuture)
        XCTAssertEqual(disabled.state, .disabledForFuture)

        var disableAtStart = try commitment()
        XCTAssertEqual(disableAtStart.apply(.disableFuture(at: start)), .futureDisableRecorded)
        XCTAssertEqual(disableAtStart.state, .committed)
        XCTAssertEqual(disableAtStart.apply(.start(at: start)), .started)
        XCTAssertEqual(disableAtStart.state, .active)

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
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: authorization, receivedAt: start.addingTimeInterval(3), processedAt: start.addingTimeInterval(3))), .releasedEarly)
        XCTAssertEqual(commitment.apply(.naturalCutoff(at: cutoff)), .rejected)
        XCTAssertEqual(commitment.state, .releasedEarly)
        XCTAssertEqual(commitment.apply(.releaseEarly(authorization: authorization, receivedAt: cutoff.addingTimeInterval(1), processedAt: cutoff.addingTimeInterval(1))), .rejected)
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
