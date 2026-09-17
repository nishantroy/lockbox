import Foundation

/// The deliberately small set of provider kinds considered by the task-unlock
/// experiment. A provider is an early-release condition, not an enforcement
/// mechanism, health feature, or proof system.
public enum TaskProviderKind: String, Codable, Equatable, Sendable {
    case morningSteps
    case privatePhotoRitual
    case mathChallenge
}

public enum TaskProviderConfigurationError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidParameter
    case unsupportedParameter
}

/// Versioned configuration contains only provider inputs that are safe to keep
/// locally. It intentionally has no photo bytes, HealthKit samples, answers,
/// app selections, or user-entered task content.
public struct TaskProviderConfiguration: Codable, Equatable, Sendable {
    public let kind: TaskProviderKind
    public let version: Int
    public let parameters: [String: String]

    public init(kind: TaskProviderKind, version: Int, parameters: [String: String]) throws {
        guard version > 0 else { throw TaskProviderConfigurationError.invalidVersion }
        guard parameters.count <= 8,
              parameters.keys.allSatisfy(Self.allowedKeys(for: kind).contains) else {
            throw TaskProviderConfigurationError.unsupportedParameter
        }
        guard parameters.values.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            throw TaskProviderConfigurationError.invalidParameter
        }
        // Every currently known key is validated for every version. A future
        // schema must add an explicit safe key/validator rather than turning
        // this dictionary into an unbounded proof or content payload.
        guard Self.isValidParameters(kind: kind, parameters: parameters) else {
            throw TaskProviderConfigurationError.invalidParameter
        }
        self.kind = kind
        self.version = version
        self.parameters = parameters
    }

    public static func morningSteps(version: Int = 1, targetSteps: Int = 2_000) throws -> Self {
        guard (1...100_000).contains(targetSteps) else {
            throw TaskProviderConfigurationError.invalidParameter
        }
        return try Self(kind: .morningSteps, version: version, parameters: ["targetSteps": String(targetSteps)])
    }

    public static func privatePhotoRitual(version: Int = 1) throws -> Self {
        try Self(kind: .privatePhotoRitual, version: version, parameters: [
            "confirmation": "required",
            "storage": "none"
        ])
    }

    public static func mathChallenge(version: Int = 1, problemCount: Int = 3) throws -> Self {
        guard (1...10).contains(problemCount) else {
            throw TaskProviderConfigurationError.invalidParameter
        }
        return try Self(kind: .mathChallenge, version: version, parameters: ["problemCount": String(problemCount)])
    }

    private static func allowedKeys(for kind: TaskProviderKind) -> Set<String> {
        switch kind {
        case .morningSteps: ["targetSteps"]
        case .privatePhotoRitual: ["confirmation", "storage"]
        case .mathChallenge: ["problemCount"]
        }
    }

    private static func isValidParameters(kind: TaskProviderKind, parameters: [String: String]) -> Bool {
        switch kind {
        case .morningSteps:
            guard let target = parameters["targetSteps"], let value = Int(target) else { return false }
            return parameters.count == 1 && (1...100_000).contains(value)
        case .privatePhotoRitual:
            return parameters == ["confirmation": "required", "storage": "none"]
        case .mathChallenge:
            guard let count = parameters["problemCount"], let value = Int(count) else { return false }
            return parameters.count == 1 && (1...10).contains(value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, version, parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            kind: container.decode(TaskProviderKind.self, forKey: .kind),
            version: container.decode(Int.self, forKey: .version),
            parameters: container.decode([String: String].self, forKey: .parameters)
        )
    }
}

/// A provider implementation is deliberately injected at a seam. The core
/// only consumes its result; it does not claim to collect background steps,
/// validate a camera image, or provide anti-cheat math verification. A result
/// of `.accepted` is untrusted adapter input until a future provider
/// integration supplies its own permission, integrity, and lifecycle checks.
public protocol TaskUnlockProvider: Sendable {
    var kind: TaskProviderKind { get }
    var version: Int { get }
    func evaluate(
        configuration: TaskProviderConfiguration,
        evidence: TaskCompletionEvidence
    ) -> TaskProviderEvaluation
}

public enum TaskProviderEvaluation: Equatable, Sendable {
    /// Adapter-reported acceptance only; this is not authenticated proof and
    /// cannot itself release enforcement.
    case accepted
    case rejected
    case unavailable
}

/// The sole release proof retained by the core is a provider-issued opaque
/// identifier. Raw evidence is intentionally outside this model.
public struct TaskCompletionEvidence: Codable, Equatable, Sendable {
    public let evidenceIdentifier: UUID
    public let commitmentID: UUID
    public let sessionID: UUID
    public let providerKind: TaskProviderKind
    public let providerVersion: Int
    public let observedAt: Date

    public init(
        evidenceIdentifier: UUID = UUID(),
        commitmentID: UUID,
        sessionID: UUID,
        providerKind: TaskProviderKind,
        providerVersion: Int,
        observedAt: Date
    ) {
        precondition(Self.isValidDate(observedAt) && providerVersion > 0)
        self.evidenceIdentifier = evidenceIdentifier
        self.commitmentID = commitmentID
        self.sessionID = sessionID
        self.providerKind = providerKind
        self.providerVersion = providerVersion
        self.observedAt = observedAt
    }

    private static func isValidDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceIdentifier, commitmentID, sessionID, providerKind, providerVersion, observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        let providerVersion = try container.decode(Int.self, forKey: .providerVersion)
        guard Self.isValidDate(observedAt), providerVersion > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .observedAt,
                in: container,
                debugDescription: "Task evidence must contain finite dates and a positive provider version"
            )
        }
        self.evidenceIdentifier = try container.decode(UUID.self, forKey: .evidenceIdentifier)
        self.commitmentID = try container.decode(UUID.self, forKey: .commitmentID)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.providerKind = try container.decode(TaskProviderKind.self, forKey: .providerKind)
        self.providerVersion = providerVersion
        self.observedAt = observedAt
    }
}

/// A release authorization is separate from task completion. This framework
/// currently accepts only a local recovery confirmation. Its `grantedAt` is
/// metadata about when the local confirmation was made; it is not the trusted
/// delivery/processing clock used for cutoff ordering.
///
/// A friend approval is intentionally not a source in this type. An arbitrary
/// UUID cannot represent the R5 authenticated, exact-session-and-policy,
/// revocable, single-use capability that a future friend integration requires.
public struct TaskReleaseAuthorization: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case recoveryConfirmation
    }

    public let source: Source
    public let commitmentID: UUID
    public let sessionID: UUID
    public let grantedAt: Date

    public init(
        source: Source = .recoveryConfirmation,
        commitmentID: UUID,
        sessionID: UUID,
        grantedAt: Date
    ) {
        precondition(grantedAt.timeIntervalSinceReferenceDate.isFinite)
        self.source = source
        self.commitmentID = commitmentID
        self.sessionID = sessionID
        self.grantedAt = grantedAt
    }

    private enum CodingKeys: String, CodingKey {
        case source, commitmentID, sessionID, grantedAt
        // Kept only to reject old persisted friend-approval placeholders
        // instead of silently accepting their extra field.
        case approvalIdentifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(commitmentID, forKey: .commitmentID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(grantedAt, forKey: .grantedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(Source.self, forKey: .source)
        let grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        guard source == .recoveryConfirmation,
              grantedAt.timeIntervalSinceReferenceDate.isFinite,
              !container.contains(.approvalIdentifier) else {
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "Only locally verified recovery authorization is supported"
            )
        }
        self.source = source
        self.commitmentID = try container.decode(UUID.self, forKey: .commitmentID)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.grantedAt = grantedAt
    }
}

public enum TaskCompletionDecision: Equatable, Sendable {
    case accepted
    case duplicate
    case replay
    case lateEvidence
    case naturalCutoffWins
    case notActive
    case cancelled
    case disabledForFuture
    case wrongCommitment
    case wrongSession
    case wrongProvider
    case wrongProviderVersion
    case providerRejected
    case providerUnavailable
    case invalidEvidence
}

public enum TaskCommitmentState: String, Codable, Sendable {
    case committed
    case active
    case completionEligible
    case releasedEarly
    case naturallyExpired
    case cancelled
    case disabledForFuture
}

public enum TaskCommitmentEvent: Equatable, Sendable {
    case start(at: Date)
    case submitCompletion(evidence: TaskCompletionEvidence, receivedAt: Date, providerResult: TaskProviderEvaluation)
    /// `grantedAt` in the authorization is grant metadata. `receivedAt` and
    /// `processedAt` must come from the trusted local receipt/processing
    /// boundary and are authoritative for the immutable cutoff.
    case releaseEarly(authorization: TaskReleaseAuthorization, receivedAt: Date, processedAt: Date)
    case cancel(at: Date)
    case disableFuture(at: Date)
    case naturalCutoff(at: Date)
}

public enum TaskCommitmentTransition: Equatable, Sendable {
    case started
    case completion(TaskCompletionDecision)
    case releasedEarly
    case naturallyExpired
    case cancelled
    case disabledForFuture
    /// The preference changed for later commitments; an active exact-session
    /// commitment intentionally remains unchanged.
    case futureDisableRecorded
    case rejected
}

public enum TaskCommitmentError: Error, Equatable, Sendable {
    case invalidDateBounds
    case invalidPolicyReference
    case invalidState
}

/// Immutable task/session inputs with a small pure lifecycle reducer. The
/// provider, policy, cutoff, and exact session ID are snapshots: no transition
/// can edit them or create another session.
public struct TaskCommitment: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let providerConfiguration: TaskProviderConfiguration
    public let createdAt: Date
    public let startAt: Date
    public let cutoffAt: Date
    public let policyReference: TaskUnlockPolicyReference
    public private(set) var state: TaskCommitmentState
    public private(set) var completionEvidenceIdentifier: UUID?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        providerConfiguration: TaskProviderConfiguration,
        createdAt: Date,
        startAt: Date,
        cutoffAt: Date,
        policyReference: TaskUnlockPolicyReference,
        state: TaskCommitmentState = .committed,
        completionEvidenceIdentifier: UUID? = nil
    ) throws {
        guard Self.validDateBounds(createdAt: createdAt, startAt: startAt, cutoffAt: cutoffAt) else {
            throw TaskCommitmentError.invalidDateBounds
        }
        guard policyReference.scope == .distractionOnly else {
            throw TaskCommitmentError.invalidPolicyReference
        }
        guard Self.validState(state, hasEvidence: completionEvidenceIdentifier != nil) else {
            throw TaskCommitmentError.invalidState
        }
        self.id = id
        self.sessionID = sessionID
        self.providerConfiguration = providerConfiguration
        self.createdAt = createdAt
        self.startAt = startAt
        self.cutoffAt = cutoffAt
        self.policyReference = policyReference
        self.state = state
        self.completionEvidenceIdentifier = completionEvidenceIdentifier
    }

    /// Evaluates evidence without mutating the commitment. `receivedAt` is the
    /// local decision time; a provider may report an older observation, but no
    /// report received at or after the immutable cutoff can win that cutoff.
    public func decideCompletion(
        evidence: TaskCompletionEvidence,
        receivedAt: Date,
        providerResult: TaskProviderEvaluation
    ) -> TaskCompletionDecision {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else { return .invalidEvidence }
        guard evidence.commitmentID == id else { return .wrongCommitment }
        guard evidence.sessionID == sessionID else { return .wrongSession }
        guard evidence.providerKind == providerConfiguration.kind else { return .wrongProvider }
        guard evidence.providerVersion == providerConfiguration.version else { return .wrongProviderVersion }
        guard evidence.observedAt.timeIntervalSinceReferenceDate.isFinite else { return .invalidEvidence }
        // Natural expiry is terminal and authoritative, including when the
        // delivered evidence repeats an identifier accepted before the cutoff.
        if state == .naturallyExpired { return .naturalCutoffWins }
        if state == .releasedEarly { return .replay }
        if state == .cancelled { return .cancelled }
        if state == .disabledForFuture { return .disabledForFuture }
        guard state == .active || state == .completionEligible else { return .notActive }
        // This ordering is intentional: the immutable OS-managed cutoff wins
        // over a duplicate, completion, or replay delivered at its boundary.
        guard receivedAt < cutoffAt else { return .naturalCutoffWins }
        if let completionEvidenceIdentifier {
            return completionEvidenceIdentifier == evidence.evidenceIdentifier ? .duplicate : .replay
        }
        guard state == .active else { return .notActive }
        guard evidence.observedAt >= startAt else { return .invalidEvidence }
        guard evidence.observedAt < cutoffAt else { return .lateEvidence }
        switch providerResult {
        case .accepted: return .accepted
        case .rejected: return .providerRejected
        case .unavailable: return .providerUnavailable
        }
    }

    @discardableResult
    public mutating func apply(_ event: TaskCommitmentEvent) -> TaskCommitmentTransition {
        switch event {
        case let .start(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { return .rejected }
            if date >= cutoffAt {
                return expireNaturally(at: date)
            }
            guard state == .committed, date >= startAt else { return .rejected }
            state = .active
            return .started

        case let .submitCompletion(evidence, receivedAt, providerResult):
            let decision = decideCompletion(evidence: evidence, receivedAt: receivedAt, providerResult: providerResult)
            guard decision == .accepted else {
                if decision == .naturalCutoffWins { return expireNaturally(at: receivedAt) }
                return .completion(decision)
            }
            completionEvidenceIdentifier = evidence.evidenceIdentifier
            state = .completionEligible
            return .completion(.accepted)

        case let .releaseEarly(authorization, receivedAt, processedAt):
            guard receivedAt.timeIntervalSinceReferenceDate.isFinite,
                  processedAt.timeIntervalSinceReferenceDate.isFinite else {
                return .rejected
            }
            // Receipt and processing are local lifecycle facts, unlike the
            // authorization's grant metadata. Either trusted local instant
            // at/after the cutoff means natural expiry wins this event, even
            // when completion was already eligible or the event was delayed
            // and replayed after relaunch.
            if receivedAt >= cutoffAt || processedAt >= cutoffAt {
                return expireNaturally(at: max(receivedAt, processedAt))
            }
            guard processedAt >= receivedAt,
                  state == .completionEligible,
                  authorization.commitmentID == id,
                  authorization.sessionID == sessionID,
                  authorization.grantedAt >= startAt,
                  authorization.grantedAt <= receivedAt else {
                return .rejected
            }
            state = .releasedEarly
            return .releasedEarly

        case let .cancel(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { return .rejected }
            if date >= cutoffAt { return expireNaturally(at: date) }
            // The activation interval is half-open: cancellation is strictly
            // pre-start, so a same-instant start/cancel race cannot cancel an
            // occurrence that is beginning.
            guard state == .committed, date < startAt else { return .rejected }
            state = .cancelled
            return .cancelled

        case let .disableFuture(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { return .rejected }
            // At/after activation this records only the preference for later
            // commitments; it never changes this exact-session commitment.
            guard state == .committed, date < startAt else { return .futureDisableRecorded }
            state = .disabledForFuture
            return .disabledForFuture

        case let .naturalCutoff(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite, date >= cutoffAt else { return .rejected }
            return expireNaturally(at: date)
        }
    }

    private mutating func expireNaturally(at date: Date) -> TaskCommitmentTransition {
        guard date >= cutoffAt else { return .rejected }
        guard state != .releasedEarly, state != .cancelled, state != .disabledForFuture,
              state != .naturallyExpired else {
            return state == .naturallyExpired ? .naturallyExpired : .rejected
        }
        state = .naturallyExpired
        return .naturallyExpired
    }

    private static func validDateBounds(createdAt: Date, startAt: Date, cutoffAt: Date) -> Bool {
        createdAt.timeIntervalSinceReferenceDate.isFinite &&
            startAt.timeIntervalSinceReferenceDate.isFinite &&
            cutoffAt.timeIntervalSinceReferenceDate.isFinite &&
            createdAt <= startAt && startAt < cutoffAt
    }

    private static func validState(_ state: TaskCommitmentState, hasEvidence: Bool) -> Bool {
        switch state {
        case .completionEligible, .releasedEarly:
            // These states can only follow an accepted completion.
            return hasEvidence
        case .naturallyExpired:
            // A commitment may expire with no completion, or retain the
            // evidence from a legitimate completion that became eligible but
            // lost the cutoff race.
            return true
        case .committed, .active, .cancelled, .disabledForFuture:
            return !hasEvidence
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, providerConfiguration, createdAt, startAt, cutoffAt, policyReference, state, completionEvidenceIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            id: container.decode(UUID.self, forKey: .id),
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            providerConfiguration: container.decode(TaskProviderConfiguration.self, forKey: .providerConfiguration),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            startAt: container.decode(Date.self, forKey: .startAt),
            cutoffAt: container.decode(Date.self, forKey: .cutoffAt),
            policyReference: container.decode(TaskUnlockPolicyReference.self, forKey: .policyReference),
            state: container.decode(TaskCommitmentState.self, forKey: .state),
            completionEvidenceIdentifier: container.decodeIfPresent(UUID.self, forKey: .completionEvidenceIdentifier)
        )
    }
}

public struct TaskUnlockPolicyReference: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        case distractionOnly
    }

    public let policyID: UUID
    public let revision: Int
    public let scope: Scope

    public init(policyID: UUID = UUID(), revision: Int, scope: Scope = .distractionOnly) throws {
        guard revision >= 0 else { throw TaskCommitmentError.invalidPolicyReference }
        self.policyID = policyID
        self.revision = revision
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case policyID, revision, scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(Int.self, forKey: .revision)
        let scope = try container.decode(Scope.self, forKey: .scope)
        guard revision >= 0 else { throw TaskCommitmentError.invalidPolicyReference }
        self.policyID = try container.decode(UUID.self, forKey: .policyID)
        self.revision = revision
        self.scope = scope
    }
}

/// Settings edits are future-facing. A commitment always carries its own
/// provider/configuration snapshot, so disabling or editing this preference
/// cannot rewrite an active exact-session commitment.
public struct TaskUnlockSettings: Codable, Equatable, Sendable {
    /// Revisions are persistence metadata, not an unbounded event counter.
    /// Refusing updates at the bound is safer than wrapping into an old
    /// revision and allowing a stale setting to appear current.
    public static let maxRevision = 1_000_000

    public private(set) var enabled: Bool
    public private(set) var revision: Int

    public init(enabled: Bool = false, revision: Int = 0) {
        precondition(Self.isValidRevision(revision))
        self.enabled = enabled
        self.revision = revision
    }

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool) -> Bool {
        guard self.enabled != enabled, revision < Self.maxRevision else { return false }
        self.enabled = enabled
        // The guard above makes this increment overflow-safe.
        revision += 1
        return true
    }

    private static func isValidRevision(_ revision: Int) -> Bool {
        revision >= 0 && revision <= maxRevision
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, revision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(revision, forKey: .revision)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(Int.self, forKey: .revision)
        guard Self.isValidRevision(revision) else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "Settings revision must be between zero and the supported bound"
            )
        }
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.revision = revision
    }
}
