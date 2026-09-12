import Foundation

/// A persisted, fixed-delay request to release a specific set of active
/// sessions. The commitment deliberately contains no countdown state: its
/// eligibility is derived from the request time and the current clock.
public struct RecoveryCommitment: Codable, Equatable, Sendable {
    public static let delay: TimeInterval = 900

    public let sessionIDs: Set<UUID>
    public let requestedAt: Date
    public let eligibleAt: Date

    public init(sessionIDs: Set<UUID>, requestedAt: Date) throws {
        guard !sessionIDs.isEmpty else {
            throw RecoveryCommitmentError.emptySessionIDs
        }
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryCommitmentError.invalidDate
        }
        let eligibleAt = requestedAt.addingTimeInterval(Self.delay)
        guard eligibleAt.timeIntervalSinceReferenceDate.isFinite,
              eligibleAt > requestedAt,
              eligibleAt.timeIntervalSince(requestedAt) == Self.delay else {
            throw RecoveryCommitmentError.invalidDate
        }

        self.sessionIDs = sessionIDs
        self.requestedAt = requestedAt
        self.eligibleAt = eligibleAt
    }

    /// Returns true for a request that has waited the complete product delay
    /// and still refers only to sessions it originally targeted. A naturally
    /// expired session may therefore leave a nonempty remaining subset.
    public func isEligible(at date: Date, activeSessionIDs: Set<UUID>) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date >= eligibleAt,
              !activeSessionIDs.isEmpty else {
            return false
        }
        return activeSessionIDs.isSubset(of: sessionIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionIDs
        case requestedAt
        case eligibleAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionIDs = try container.decode(Set<UUID>.self, forKey: .sessionIDs)
        let requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        let encodedEligibleAt = try container.decode(Date.self, forKey: .eligibleAt)
        let commitment = try RecoveryCommitment(sessionIDs: sessionIDs, requestedAt: requestedAt)
        guard encodedEligibleAt == commitment.eligibleAt else {
            throw RecoveryCommitmentError.editedEligibility
        }
        self = commitment
    }
}

public enum RecoveryCommitmentError: LocalizedError, Equatable, Sendable {
    case emptySessionIDs
    case invalidDate
    case editedEligibility

    public var errorDescription: String? {
        switch self {
        case .emptySessionIDs:
            return "Recovery must target at least one active session."
        case .invalidDate:
            return "Recovery contains an invalid clock value."
        case .editedEligibility:
            return "Recovery eligibility does not match the fixed delay."
        }
    }
}
