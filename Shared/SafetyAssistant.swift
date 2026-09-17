import Foundation

/// The local, non-authoritative review shown before a stricter Lockbox policy.
/// This model intentionally contains summaries and checklist identifiers only;
/// it must never be given FamilyControls tokens, bundle identifiers, URLs, or
/// network state.
public enum SafetyAssistantChecklistItem: String, CaseIterable, Codable, Sendable, Identifiable {
    case phone
    case messages
    case maps
    case passwordAuthenticator
    case healthTransit
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .phone: return "Phone"
        case .messages: return "Messages"
        case .maps: return "Maps"
        case .passwordAuthenticator: return "Password or authenticator"
        case .healthTransit: return "Health or transit"
        case .other: return "Other owner needs"
        }
    }

    public var prompt: String {
        switch self {
        case .phone: return "Keep the Phone app and ordinary emergency controls available."
        case .messages: return "Decide whether Messages or a trusted contact path is essential."
        case .maps: return "Decide whether Maps or another navigation path is essential."
        case .passwordAuthenticator: return "Keep password and authenticator access available for sign-in."
        case .healthTransit: return "Keep health, transport, and travel access available when needed."
        case .other: return "Add anything else you need for recovery, care, work, or travel."
        }
    }
}

/// These are deliberately bounded, user-stopped checks. They are not an
/// emergency test, do not place calls, and do not establish universal
/// enforcement.
public enum SafetyAssistantTestStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case selectedPath
    case browserPath
    case categoryPath
    case systemAndEmergencyPath

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .selectedPath: return "Selected app or website"
        case .browserPath: return "Browser path"
        case .categoryPath: return "Category path"
        case .systemAndEmergencyPath: return "System and emergency path"
        }
    }

    public var instructions: String {
        switch self {
        case .selectedPath:
            return "During a short, disposable check, open one selected path and confirm the result matches the saved mode. Stop if anything is unclear."
        case .browserPath:
            return "Try the browser and one needed website path separately. Do not assume an app selection covers every browser or website route."
        case .categoryPath:
            return "If a category is selected, check one relevant app from that category. Category expansion and coverage can vary by device."
        case .systemAndEmergencyPath:
            return "Open the normal system and emergency controls without placing a call. Never use this check to claim an emergency guarantee."
        }
    }
}

public enum SafetyAssistantAuthorizationState: String, Codable, Sendable {
    case authorized
    case unavailable
    case unknown
}

public enum SafetyAssistantRegistrationState: String, Codable, Sendable {
    case matching
    case notRegistered
    case mismatch
    case unknown
}

public struct SafetyAssistantAcknowledgements: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var checklist: Set<SafetyAssistantChecklistItem>
    public var testSteps: Set<SafetyAssistantTestStep>

    public init(
        version: Int = SafetyAssistantAcknowledgements.currentVersion,
        checklist: Set<SafetyAssistantChecklistItem> = [],
        testSteps: Set<SafetyAssistantTestStep> = []
    ) {
        self.version = version
        self.checklist = checklist
        self.testSteps = testSteps
    }

    public func validated() throws -> SafetyAssistantAcknowledgements {
        guard version == Self.currentVersion else {
            throw SafetyAssistantValidationError.unsupportedVersion
        }
        return self
    }

    public var isComplete: Bool {
        checklist.count == SafetyAssistantChecklistItem.allCases.count
            && testSteps.count == SafetyAssistantTestStep.allCases.count
    }
}

public enum SafetyAssistantValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
}

public struct SafetyAssistantAuditInput: Equatable, Sendable {
    public let mode: RuntimeMode?
    public let selection: RuntimeSelectionSummary?
    public let authorization: SafetyAssistantAuthorizationState
    public let registration: SafetyAssistantRegistrationState

    public init(
        mode: RuntimeMode?,
        selection: RuntimeSelectionSummary?,
        authorization: SafetyAssistantAuthorizationState,
        registration: SafetyAssistantRegistrationState
    ) {
        self.mode = mode
        self.selection = selection
        self.authorization = authorization
        self.registration = registration
    }
}

public enum SafetyAssistantFindingID: String, CaseIterable, Codable, Sendable {
    case authorization
    case selection
    case allowOnlyCoverage
    case categoryCoverage
    case browserCoverage
    case systemCoverage
    case registration
}

public enum SafetyAssistantFindingSeverity: String, Codable, Sendable {
    case action
    case caution
    case information
}

public struct SafetyAssistantFinding: Equatable, Sendable, Identifiable {
    public let id: SafetyAssistantFindingID
    public let severity: SafetyAssistantFindingSeverity
    public let title: String
    public let detail: String

    public init(id: SafetyAssistantFindingID, severity: SafetyAssistantFindingSeverity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct SafetyAssistantAudit: Equatable, Sendable {
    public let version: Int
    public let mode: RuntimeMode?
    /// The count is intentionally opaque: it is a summary, never a token or
    /// app identifier.
    public let opaqueSelectionCount: Int
    public let findings: [SafetyAssistantFinding]
    public let outstandingChecklist: [SafetyAssistantChecklistItem]
    public let outstandingTestSteps: [SafetyAssistantTestStep]

    public var isReadyForReview: Bool {
        findings.allSatisfy { $0.severity != .action }
            && outstandingChecklist.isEmpty
            && outstandingTestSteps.isEmpty
    }

    public static func evaluate(
        input: SafetyAssistantAuditInput,
        acknowledgements: SafetyAssistantAcknowledgements = .init()
    ) -> SafetyAssistantAudit {
        let selectionCount = input.selection?.totalCount ?? 0
        var findings: [SafetyAssistantFinding] = []

        if input.authorization != .authorized {
            findings.append(SafetyAssistantFinding(
                id: .authorization,
                severity: .action,
                title: "Screen Time access needs review",
                detail: "Confirm authorization in the app before relying on a saved policy. This assistant cannot verify enforcement."
            ))
        }
        if input.mode == nil || input.selection == nil || selectionCount == 0 {
            findings.append(SafetyAssistantFinding(
                id: .selection,
                severity: .action,
                title: "Choose a valid policy first",
                detail: "A safety review is more useful after a recognized mode and at least one selected item are saved."
            ))
        }
        if input.registration != .matching {
            findings.append(SafetyAssistantFinding(
                id: .registration,
                severity: .action,
                title: "Registration is not confirmed",
                detail: "Review the saved schedule and registration status. A saved rule is not proof that every restriction is active."
            ))
        }
        if input.mode == .allowOnlySelected {
            findings.append(SafetyAssistantFinding(
                id: .allowOnlyCoverage,
                severity: .caution,
                title: "Allow only selected has a narrow allowlist",
                detail: "Everything outside the selected allowlist may be restricted. Check each essential path before using this mode."
            ))
        }

        findings.append(SafetyAssistantFinding(
            id: .categoryCoverage,
            severity: .caution,
            title: "Category coverage needs a device check",
            detail: "Category expansion is not a promise of universal coverage. Test a representative app and keep a needed alternative available."
        ))
        findings.append(SafetyAssistantFinding(
            id: .browserCoverage,
            severity: .caution,
            title: "Browser and website coverage needs a separate check",
            detail: "An app or category selection may not cover browser routes or every website. Check the paths you rely on."
        ))
        findings.append(SafetyAssistantFinding(
            id: .systemCoverage,
            severity: .caution,
            title: "System and emergency access is outside this app's guarantee",
            detail: "This review cannot promise emergency access or test every system path. Keep ordinary emergency recovery available and do not place a test call."
        ))

        return SafetyAssistantAudit(
            version: SafetyAssistantAcknowledgements.currentVersion,
            mode: input.mode,
            opaqueSelectionCount: selectionCount,
            findings: findings,
            outstandingChecklist: SafetyAssistantChecklistItem.allCases.filter { !acknowledgements.checklist.contains($0) },
            outstandingTestSteps: SafetyAssistantTestStep.allCases.filter { !acknowledgements.testSteps.contains($0) }
        )
    }
}
