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
        XCTAssertEqual(audit.applicableTestSteps, SafetyAssistantTestStep.allCases)
    }

    func testNoCategorySelectionOmitsCategoryFindingAndTestStepButKeepsBrowserAndSystemReview() {
        let audit = SafetyAssistantAudit.evaluate(input: SafetyAssistantAuditInput(
            mode: .blockSelected,
            selection: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            authorization: .authorized,
            registration: .matching
        ))

        XCTAssertFalse(audit.findings.contains { $0.id == .categoryCoverage })
        XCTAssertTrue(audit.findings.contains { $0.id == .browserCoverage })
        XCTAssertTrue(audit.findings.contains { $0.id == .systemCoverage })
        XCTAssertEqual(audit.applicableTestSteps, [.selectedPath, .browserPath, .systemAndEmergencyPath])
        XCTAssertFalse(audit.applicableTestSteps.contains(.categoryPath))
        XCTAssertEqual(audit.outstandingTestSteps, audit.applicableTestSteps)
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

    func testNoCategoryAcknowledgementsAreReadyWithoutIrrelevantCategoryAcknowledgement() {
        var acknowledgements = SafetyAssistantAcknowledgements()
        acknowledgements.checklist = Set(SafetyAssistantChecklistItem.allCases)
        acknowledgements.testSteps = Set([.selectedPath, .browserPath, .systemAndEmergencyPath])
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
        XCTAssertTrue(audit.isReadyForReview, "Cautions remain visible, but all applicable review actions are acknowledged.")
    }

    func testCategoryAcknowledgementIsRequiredOnlyWhenCategoryIsSelected() {
        let input = SafetyAssistantAuditInput(
            mode: .blockSelected,
            selection: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 1, webDomainCount: 0),
            authorization: .authorized,
            registration: .matching
        )
        var acknowledgements = SafetyAssistantAcknowledgements(
            checklist: Set(SafetyAssistantChecklistItem.allCases),
            testSteps: [.selectedPath, .browserPath, .systemAndEmergencyPath]
        )

        let incompleteAudit = SafetyAssistantAudit.evaluate(input: input, acknowledgements: acknowledgements)
        XCTAssertTrue(incompleteAudit.findings.contains { $0.id == .categoryCoverage })
        XCTAssertEqual(incompleteAudit.applicableTestSteps, SafetyAssistantTestStep.allCases)
        XCTAssertEqual(incompleteAudit.outstandingTestSteps, [.categoryPath])
        XCTAssertFalse(incompleteAudit.isReadyForReview)

        acknowledgements.testSteps.insert(.categoryPath)
        let completeAudit = SafetyAssistantAudit.evaluate(input: input, acknowledgements: acknowledgements)
        XCTAssertTrue(completeAudit.outstandingTestSteps.isEmpty)
        XCTAssertTrue(completeAudit.isReadyForReview)
    }
}
