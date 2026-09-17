import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class SafetyAssistantTests: XCTestCase {
    func testAuditExposesOnlyOpaqueCountAndCurrentMode() {
        let audit = SafetyAssistantAudit.evaluate(input: SafetyAssistantAuditInput(
            mode: .allowOnlySelected,
            selection: RuntimeSelectionSummary(applicationCount: 2, categoryCount: 1, webDomainCount: 3),
            authorization: .authorized,
            registration: .matching
        ))

        XCTAssertEqual(audit.version, SafetyAssistantAcknowledgements.currentVersion)
        XCTAssertEqual(audit.mode, .allowOnlySelected)
        XCTAssertEqual(audit.opaqueSelectionCount, 6)
        XCTAssertFalse(audit.findings.contains { $0.id == .authorization })
        XCTAssertTrue(audit.findings.contains { $0.id == .allowOnlyCoverage })
        XCTAssertTrue(audit.findings.contains { $0.id == .categoryCoverage })
        XCTAssertTrue(audit.findings.contains { $0.id == .browserCoverage })
        XCTAssertTrue(audit.findings.contains { $0.id == .systemCoverage })
    }

    func testAuditRequiresSetupAndNeverCallsTheReviewACompletionGuarantee() {
        let audit = SafetyAssistantAudit.evaluate(input: SafetyAssistantAuditInput(
            mode: nil,
            selection: nil,
            authorization: .unavailable,
            registration: .notRegistered
        ))

        XCTAssertTrue(audit.findings.contains { $0.id == .authorization && $0.severity == .action })
        XCTAssertTrue(audit.findings.contains { $0.id == .selection && $0.severity == .action })
        XCTAssertTrue(audit.findings.contains { $0.id == .registration && $0.severity == .action })
        XCTAssertTrue(audit.findings.contains { $0.id == .systemCoverage })
        XCTAssertTrue(SafetyAssistantTestStep.allCases.contains(.systemAndEmergencyPath))
        XCTAssertTrue(SafetyAssistantTestStep.systemAndEmergencyPath.instructions.contains("without placing a call"))
        XCTAssertFalse(audit.isReadyForReview)
    }

    func testAcknowledgementVersionRoundTripsAndRejectsUnknownVersion() throws {
        let acknowledgements = SafetyAssistantAcknowledgements(
            checklist: [.phone, .passwordAuthenticator],
            testSteps: [.selectedPath]
        )
        let encoded = try JSONEncoder().encode(acknowledgements)
        XCTAssertEqual(try JSONDecoder().decode(SafetyAssistantAcknowledgements.self, from: encoded), acknowledgements)
        XCTAssertNoThrow(try acknowledgements.validated())

        var future = acknowledgements
        future.version = SafetyAssistantAcknowledgements.currentVersion + 1
        XCTAssertThrowsError(try future.validated()) { error in
            XCTAssertEqual(error as? SafetyAssistantValidationError, .unsupportedVersion)
        }
    }

    func testCompletedAcknowledgementsRemoveOnlyChecklistItemsAndTestSteps() {
        var acknowledgements = SafetyAssistantAcknowledgements()
        acknowledgements.checklist = Set(SafetyAssistantChecklistItem.allCases)
        acknowledgements.testSteps = Set(SafetyAssistantTestStep.allCases)
        let audit = SafetyAssistantAudit.evaluate(
            input: SafetyAssistantAuditInput(
                mode: .blockSelected,
                selection: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
                authorization: .authorized,
                registration: .matching
            ),
            acknowledgements: acknowledgements
        )

        XCTAssertTrue(audit.outstandingChecklist.isEmpty)
        XCTAssertTrue(audit.outstandingTestSteps.isEmpty)
        XCTAssertTrue(audit.isReadyForReview, "Cautions remain visible, but all required review actions are acknowledged.")
    }
}
