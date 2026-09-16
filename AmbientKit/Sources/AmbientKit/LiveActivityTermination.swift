import Foundation

/// The synchronous DeviceActivity callback can give presentation cleanup only
/// a small, bounded opportunity. This is policy/presentation-only: it must
/// never be treated as an enforcement timer or release acknowledgement.
public enum AmbientLiveActivityTerminationResult: Codable, Equatable, Sendable {
    case noMatchingActivity
    case ended(count: Int)
    case timedOut
    case failed

    private enum CodingKeys: String, CodingKey {
        case kind
        case count
    }

    private enum Kind: String, Codable {
        case noMatchingActivity
        case ended
        case timedOut
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .noMatchingActivity: self = .noMatchingActivity
        case .ended: self = .ended(count: try container.decode(Int.self, forKey: .count))
        case .timedOut: self = .timedOut
        case .failed: self = .failed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noMatchingActivity: try container.encode(Kind.noMatchingActivity, forKey: .kind)
        case .ended(let count):
            try container.encode(Kind.ended, forKey: .kind)
            try container.encode(count, forKey: .count)
        case .timedOut: try container.encode(Kind.timedOut, forKey: .kind)
        case .failed: try container.encode(Kind.failed, forKey: .kind)
        }
    }

    public var diagnosticLabel: String {
        switch self {
        case .noMatchingActivity: return "no matching activity"
        case .ended(let count): return "ended \(count) activity(ies)"
        case .timedOut: return "bounded wait timed out"
        case .failed: return "presentation cleanup failed"
        }
    }
}

/// Privacy-minimal presentation diagnostics are kept outside the runtime JSON
/// transaction. The monitor writes only a result and timestamp after policy
/// reconciliation, so this namespace cannot contend with enforcement state or
/// turn a presentation failure into operationStatus/lastError.
public enum AmbientLiveActivityTerminationResultMapper {
    public static func result(forEndedCount count: Int) -> AmbientLiveActivityTerminationResult {
        count > 0 ? .ended(count: count) : .noMatchingActivity
    }
}

public enum AmbientLiveActivityTerminationPolicy {
    /// The callback bridge is presentation-only and intentionally below one
    /// second. It is not an OS-scheduled Activity dismissal.
    public static let callbackWaitMilliseconds = 750
    public static let callbackWaitNanoseconds = UInt64(callbackWaitMilliseconds) * 1_000_000
}

public struct AmbientLiveActivityTerminationDiagnostic: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let result: AmbientLiveActivityTerminationResult

    public init(observedAt: Date = Date(), result: AmbientLiveActivityTerminationResult) {
        self.observedAt = observedAt
        self.result = result
    }
}

public enum AmbientLiveActivityDiagnosticsStore {
    public static let appGroupSuiteName = "group.com.phone-lockbox"
    public static let key = "phone-lockbox.ambient.live-activity-termination-diagnostics"
    public static let maximumEntries = 16

    public static func append(
        _ result: AmbientLiveActivityTerminationResult,
        observedAt: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)
    ) {
        guard let defaults else { return }
        var entries = read(defaults: defaults)
        entries.append(AmbientLiveActivityTerminationDiagnostic(observedAt: observedAt, result: result))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    public static func read(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)
    ) -> [AmbientLiveActivityTerminationDiagnostic] {
        guard let data = defaults?.data(forKey: key),
              let entries = try? JSONDecoder().decode([AmbientLiveActivityTerminationDiagnostic].self, from: data) else {
            return []
        }
        return entries
    }
}

/// Selection rules for ending this app's Live Activities. These rules are
/// value-only so callback identity and the past-end fallback can be tested
/// without pretending to exercise ActivityKit.
public enum AmbientLiveActivityTermination {
    /// Canonical mapping shared by the host and DeviceActivity adapter. A
    /// bedtime-purpose manual route retains bedtime presentation semantics.
    public static func kind(isBedtimePurpose: Bool, isScheduledOrigin: Bool) -> AmbientLiveActivityKind {
        isBedtimePurpose || isScheduledOrigin ? .bedtime : .focus
    }

    /// Callback-driven termination is bound to both immutable identity values.
    /// A reused route or a newer activity with a coincidentally equal end must
    /// never be selected by a stale callback.
    public static func matchesExactSession(
        activity: AmbientLiveActivityAttributes,
        sessionID: String,
        fixedEnd: Date,
        kind: AmbientLiveActivityKind? = nil
    ) -> Bool {
        activity.sessionID == sessionID &&
            activity.fixedEnd == fixedEnd &&
            (kind == nil || activity.kind == kind)
    }

    /// Foreground/relaunch cleanup is deliberately broader than callback
    /// cleanup because terminal history may have been pruned. It still only
    /// handles this app's real focus/bedtime activities and never a current or
    /// future activity. Demo activities remain under their explicit demo route.
    public static func shouldSweepPastFixedEnd(
        activity: AmbientLiveActivityAttributes,
        now: Date
    ) -> Bool {
        activity.kind != .demo && activity.fixedEnd <= now
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@available(iOS 17.0, *)
public enum AmbientLiveActivityBoundedTermination {
    /// Runs the async ActivityKit operation on a detached task and waits only
    /// on a semaphore from the synchronous callback. `Task.detached` does not
    /// inherit the callback actor; the callback thread never executes or waits
    /// on a MainActor job. The timeout is a presentation-only hard bound.
    public static func run(
        waitNanoseconds: UInt64 = AmbientLiveActivityTerminationPolicy.callbackWaitNanoseconds,
        operation: @escaping @Sendable () async throws -> Int
    ) -> AmbientLiveActivityTerminationResult {
        let latch = AmbientLiveActivityTerminationLatch()
        DispatchQueue.global(qos: .utility).async {
            _ = Task.detached(priority: .utility) {
                do {
                    latch.finish(AmbientLiveActivityTerminationResultMapper.result(forEndedCount: try await operation()))
                } catch {
                    latch.finish(.failed)
                }
            }
        }
        let boundedNanoseconds = min(
            waitNanoseconds,
            AmbientLiveActivityTerminationPolicy.callbackWaitNanoseconds
        )
        let timeout = DispatchTime.now() + .nanoseconds(Int(boundedNanoseconds))
        guard latch.semaphore.wait(timeout: timeout) == .success else {
            return .timedOut
        }
        return latch.value ?? .timedOut
    }
}

private final class AmbientLiveActivityTerminationLatch: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: AmbientLiveActivityTerminationResult?

    var value: AmbientLiveActivityTerminationResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func finish(_ result: AmbientLiveActivityTerminationResult) {
        lock.lock()
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }
}

@available(iOS 17.0, *)
public enum AmbientLiveActivityTerminator {
    /// Ends every duplicate for one exact committed session. The caller must
    /// invoke this only after durable runtime state and policy replay have
    /// completed. ActivityKit remains presentation-only and best-effort.
    public static func endExactSession(
        sessionID: String,
        fixedEnd: Date,
        kind: AmbientLiveActivityKind? = nil,
        status: AmbientLiveActivityStatus
    ) async -> Int {
        let matches = Activity<AmbientLiveActivityAttributes>.activities.filter {
            AmbientLiveActivityTermination.matchesExactSession(
                activity: $0.attributes,
                sessionID: sessionID,
                fixedEnd: fixedEnd,
                kind: kind
            )
        }
        guard !matches.isEmpty else { return 0 }
        let state = AmbientActivityContentState(fixedEnd: fixedEnd, status: status)
        for activity in matches {
            await activity.end(
                .init(state: state, staleDate: fixedEnd),
                dismissalPolicy: .immediate
            )
        }
        return matches.count
    }

    /// Best-effort foreground/relaunch fallback. It uses stale presentation,
    /// not release-observed copy, because a past immutable end alone does not
    /// prove that Managed Settings released.
    public static func endPastFixedEndAppOwnedActivities(now: Date) async -> Int {
        let matches = Activity<AmbientLiveActivityAttributes>.activities.filter {
            AmbientLiveActivityTermination.shouldSweepPastFixedEnd(
                activity: $0.attributes,
                now: now
            )
        }
        for activity in matches {
            let state = AmbientActivityContentState(
                fixedEnd: activity.attributes.fixedEnd,
                status: .stale
            )
            await activity.end(
                .init(state: state, staleDate: activity.attributes.fixedEnd),
                dismissalPolicy: .immediate
            )
        }
        return matches.count
    }
}
#endif
