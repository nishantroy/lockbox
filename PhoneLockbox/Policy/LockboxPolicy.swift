import Foundation
#if SWIFT_PACKAGE
import PhoneLockboxRuntime
#endif

public struct LocalTime: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        precondition((0..<24).contains(hour) && (0..<60).contains(minute))
        self.hour = hour
        self.minute = minute
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw DecodingError.dataCorruptedError(
                forKey: .hour,
                in: container,
                debugDescription: "Local time must be an hour from 0 through 23 and a minute from 0 through 59"
            )
        }
        self.hour = hour
        self.minute = minute
    }

    private enum CodingKeys: String, CodingKey {
        case hour, minute
    }
}

public struct LockboxConfiguration: Codable, Equatable, Sendable {
    public var start: LocalTime
    public var end: LocalTime
    public var enabled: Bool

    public init(start: LocalTime, end: LocalTime, enabled: Bool = false) {
        self.start = start
        self.end = end
        self.enabled = enabled
    }

    public var isOvernight: Bool { start.minutesSinceMidnight > end.minutesSinceMidnight }

    /// Time values must describe a non-empty daily window. `enabled` is deliberately
    /// separate: a valid, disabled configuration has no resolved occurrence.
    public var isValid: Bool {
        start.minutesSinceMidnight != end.minutesSinceMidnight
    }

    public var isEnabled: Bool { enabled && isValid }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(LocalTime.self, forKey: .start)
        let end = try container.decode(LocalTime.self, forKey: .end)
        // Missing enabled is treated as the safe, disabled value for old data.
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        guard start.minutesSinceMidnight != end.minutesSinceMidnight else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "A lockbox window must have different start and end times"
            )
        }
        self.start = start
        self.end = end
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, enabled
    }
}

public struct LockboxSession: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case scheduled, manual }
    public enum State: String, Codable, Sendable { case active, recoveryPending, released, expired }

    public let id: UUID
    public let origin: Origin
    public let start: Date
    public let end: Date
    public var state: State
    public let policyRevision: Int

    public init(id: UUID = UUID(), origin: Origin, start: Date, end: Date, state: State = .active, policyRevision: Int) {
        precondition(Self.isValid(start: start, end: end, policyRevision: policyRevision))
        self.id = id
        self.origin = origin
        self.start = start
        self.end = end
        self.state = state
        self.policyRevision = policyRevision
    }

    public var isValid: Bool {
        Self.isValid(start: start, end: end, policyRevision: policyRevision)
    }

    public func isEffective(at date: Date) -> Bool {
        state == .active || state == .recoveryPending ? date >= start && date < end : false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let origin = try container.decode(Origin.self, forKey: .origin)
        let start = try container.decode(Date.self, forKey: .start)
        let end = try container.decode(Date.self, forKey: .end)
        let state = try container.decode(State.self, forKey: .state)
        let policyRevision = try container.decode(Int.self, forKey: .policyRevision)
        guard Self.isValid(start: start, end: end, policyRevision: policyRevision) else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "A session must have finite dates, end after start, and a non-negative policy revision"
            )
        }
        self.id = id
        self.origin = origin
        self.start = start
        self.end = end
        self.state = state
        self.policyRevision = policyRevision
    }

    private static func isValid(start: Date, end: Date, policyRevision: Int) -> Bool {
        start.timeIntervalSinceReferenceDate.isFinite &&
            end.timeIntervalSinceReferenceDate.isFinite &&
            end > start &&
            policyRevision >= 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, origin, start, end, state, policyRevision
    }
}

public struct RecoveryRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let requestedAt: Date
    public let eligibleAt: Date
    public var cancelled: Bool

    public init(sessionID: UUID, requestedAt: Date, delay: TimeInterval, cancelled: Bool = false) {
        precondition(Self.isValid(requestedAt: requestedAt, eligibleAt: requestedAt.addingTimeInterval(delay)))
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.eligibleAt = requestedAt.addingTimeInterval(delay)
        self.cancelled = cancelled
    }

    public func isEligible(at date: Date) -> Bool { !cancelled && date >= eligibleAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        let eligibleAt = try container.decode(Date.self, forKey: .eligibleAt)
        let cancelled = try container.decode(Bool.self, forKey: .cancelled)
        guard Self.isValid(requestedAt: requestedAt, eligibleAt: eligibleAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .eligibleAt,
                in: container,
                debugDescription: "Recovery eligibility must be finite and strictly after its request"
            )
        }
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.eligibleAt = eligibleAt
        self.cancelled = cancelled
    }

    private static func isValid(requestedAt: Date, eligibleAt: Date) -> Bool {
        requestedAt.timeIntervalSinceReferenceDate.isFinite &&
            eligibleAt.timeIntervalSinceReferenceDate.isFinite &&
            eligibleAt > requestedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, requestedAt, eligibleAt, cancelled
    }
}

public enum LockboxSessionTransitionError: Error, Equatable, Sendable {
    case noActiveSession
    case invalidState
    case recoveryNotEligible
    case sessionNotFinished
    case invalidRecoveryDelay
    case invalidDate
}

public enum LockboxSessionEvent: Equatable, Sendable {
    case requestRecovery(at: Date, delay: TimeInterval)
    case cancelRecovery(at: Date)
    case confirmRecovery(at: Date)
    case scheduledEnd(at: Date)
}

/// Pure lifecycle reducer awaiting runtime integration. Persist this value before
/// applying Managed Settings so callbacks and app launches can reconcile idempotently.
public struct LockboxSessionController: Codable, Equatable, Sendable {
    public private(set) var session: LockboxSession
    public private(set) var recovery: RecoveryRequest?

    public init(session: LockboxSession) {
        precondition(Self.hasValidInvariants(session: session, recovery: nil))
        self.session = session
    }

    public mutating func apply(_ event: LockboxSessionEvent) throws {
        switch event {
        case let .requestRecovery(at: date, delay: delay):
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LockboxSessionTransitionError.invalidDate }
            let eligibleAt = date.addingTimeInterval(delay)
            guard delay.isFinite, delay > 0,
                  eligibleAt.timeIntervalSinceReferenceDate.isFinite, eligibleAt > date else {
                throw LockboxSessionTransitionError.invalidRecoveryDelay
            }
            guard session.state == .active, date >= session.start, date < session.end else {
                throw LockboxSessionTransitionError.invalidState
            }
            guard recovery == nil else { throw LockboxSessionTransitionError.invalidState }
            recovery = RecoveryRequest(sessionID: session.id, requestedAt: date, delay: delay)
            session.state = .recoveryPending

        case let .cancelRecovery(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LockboxSessionTransitionError.invalidDate }
            guard session.state == .recoveryPending, let request = recovery else {
                throw LockboxSessionTransitionError.invalidState
            }
            guard date >= request.requestedAt else { throw LockboxSessionTransitionError.invalidDate }
            recovery = nil
            session.state = date >= session.end ? .expired : .active

        case let .confirmRecovery(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LockboxSessionTransitionError.invalidDate }
            guard session.state == .recoveryPending, let request = recovery,
                  request.sessionID == session.id, !request.cancelled else {
                throw LockboxSessionTransitionError.invalidState
            }
            // The natural end is authoritative. This also makes a delayed confirmation
            // deterministic when the app was suspended or the process was relaunched.
            if date >= session.end {
                session.state = .expired
                recovery = nil
                return
            }
            guard request.isEligible(at: date) else { throw LockboxSessionTransitionError.recoveryNotEligible }
            session.state = .released
            recovery = nil

        case let .scheduledEnd(at: date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LockboxSessionTransitionError.invalidDate }
            guard date >= session.end else { throw LockboxSessionTransitionError.sessionNotFinished }
            guard session.state == .active || session.state == .recoveryPending else { return }
            session.state = .expired
            recovery = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let session = try container.decode(LockboxSession.self, forKey: .session)
        let recovery = try container.decodeIfPresent(RecoveryRequest.self, forKey: .recovery)
        guard Self.hasValidInvariants(session: session, recovery: recovery) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recovery,
                in: container,
                debugDescription: "Session state and recovery request are inconsistent"
            )
        }
        self.session = session
        self.recovery = recovery
    }

    private static func hasValidInvariants(session: LockboxSession, recovery: RecoveryRequest?) -> Bool {
        switch session.state {
        case .active, .released, .expired:
            return recovery == nil
        case .recoveryPending:
            guard let recovery else { return false }
            return recovery.sessionID == session.id &&
                !recovery.cancelled &&
                recovery.requestedAt >= session.start &&
                recovery.requestedAt < session.end &&
                recovery.eligibleAt > recovery.requestedAt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case session, recovery
    }
}

public enum LockboxPolicy {
    /// Resolves the current, or otherwise next, occurrence of a daily local-time
    /// window. Occurrences are half-open: [start, end). A disabled configuration
    /// resolves to no occurrence.
    ///
    /// Local boundaries use Calendar's next-valid policy for skipped DST times and
    /// its first occurrence policy for repeated times. The returned dates are absolute
    /// instants; the configuration remains expressed in local civil time.
    public static func nextOccurrence(configuration: LockboxConfiguration, after date: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        RuntimeOccurrenceResolver.currentOrNext(
            start: RuntimeTime(hour: configuration.start.hour, minute: configuration.start.minute),
            end: RuntimeTime(hour: configuration.end.hour, minute: configuration.end.minute),
            enabled: configuration.isEnabled,
            after: date,
            calendar: calendar
        )
    }
}
