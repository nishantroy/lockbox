import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// One immutable ActivityKit selection fence. A batch may contain multiple
/// sessions, but an exact fence is enumerated once and ends every matching
/// duplicate ActivityKit activity for that fence.
public struct AmbientLiveActivityTerminationFence: Hashable, Sendable {
    public let sessionID: String
    public let fixedEnd: Date
    public let kind: AmbientLiveActivityKind

    public init(sessionID: String, fixedEnd: Date, kind: AmbientLiveActivityKind) {
        self.sessionID = sessionID
        self.fixedEnd = fixedEnd
        self.kind = kind
    }
}

public enum AmbientLiveActivityTerminationPolicy {
    /// The callback bridge uses one configured/nominal semaphore deadline for
    /// the entire batch. This is not an OS-scheduled Activity dismissal and is
    /// not a guaranteed wall-clock callback bound under preemption,
    /// scheduling, or an extension watchdog.
    public static let callbackWaitMilliseconds = 750
    public static let callbackWaitNanoseconds = UInt64(callbackWaitMilliseconds) * 1_000_000
}

/// Cross-platform synchronization seam for the iOS ActivityKit adapter. The
/// operation is launched once for the complete exact-session set and the
/// caller performs one semaphore wait against one absolute deadline.
public enum AmbientLiveActivityBatchWaitRunner {
    public static func run(
        fences: [AmbientLiveActivityTerminationFence],
        waitNanoseconds: UInt64 = AmbientLiveActivityTerminationPolicy.callbackWaitNanoseconds,
        operation: @escaping @Sendable ([AmbientLiveActivityTerminationFence]) async throws -> Int
    ) -> AmbientLiveActivityTerminationResult {
        var uniqueFences: [AmbientLiveActivityTerminationFence] = []
        var seen = Set<AmbientLiveActivityTerminationFence>()
        for fence in fences where seen.insert(fence).inserted {
            uniqueFences.append(fence)
        }
        guard !uniqueFences.isEmpty else { return .noMatchingActivity }

        let latch = AmbientLiveActivityTerminationLatch()
        _ = Task.detached(priority: .utility) {
            do {
                let endedCount = try await operation(uniqueFences)
                latch.finish(AmbientLiveActivityTerminationResultMapper.result(forEndedCount: endedCount))
            } catch {
                latch.finish(.failed)
            }
        }

        let boundedNanoseconds = min(
            waitNanoseconds,
            AmbientLiveActivityTerminationPolicy.callbackWaitNanoseconds
        )
        // Capture one absolute deadline for this entire batch. The caller may
        // resume later than this deadline if the process is preempted.
        let deadline = DispatchTime.now() + .nanoseconds(Int(boundedNanoseconds))
        guard latch.semaphore.wait(timeout: deadline) == .success else {
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
    private static let lockTimeout: TimeInterval = 0.5
    private static let processLock = NSLock()

    /// The diagnostics lock is deliberately separate from SharedRuntimeStore's
    /// enforcement lock. A presentation write can be dropped if its bounded
    /// lock cannot be acquired; it can never delay or alter enforcement.
    public static func defaultLockURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupSuiteName
        )?.appendingPathComponent("phone-lockbox-ambient-diagnostics.lock")
    }

    public static func append(
        _ result: AmbientLiveActivityTerminationResult,
        observedAt: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName),
        lockURL: URL? = defaultLockURL()
    ) {
        guard let defaults else { return }
        _ = withDiagnosticsLock(lockURL: lockURL) {
            var entries = normalizedEntries(defaults.data(forKey: key))
            entries.append(AmbientLiveActivityTerminationDiagnostic(observedAt: observedAt, result: result))
            let finalEntries = Array(entries.suffix(maximumEntries))
            guard let data = try? JSONEncoder().encode(finalEntries) else { return }
            defaults.set(data, forKey: key)
        }
    }

    public static func read(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName),
        lockURL: URL? = defaultLockURL()
    ) -> [AmbientLiveActivityTerminationDiagnostic] {
        guard let defaults else { return [] }
        return withDiagnosticsLock(lockURL: lockURL) {
            normalizedEntries(defaults.data(forKey: key))
        } ?? []
    }

    private static func normalizedEntries(_ data: Data?) -> [AmbientLiveActivityTerminationDiagnostic] {
        guard let data,
              let entries = try? JSONDecoder().decode([AmbientLiveActivityTerminationDiagnostic].self, from: data) else {
            return []
        }
        return Array(entries.suffix(maximumEntries))
    }

    private static func withDiagnosticsLock<T>(lockURL: URL?, _ body: () -> T) -> T? {
        guard let lockURL else {
            processLock.lock()
            defer { processLock.unlock() }
            return body()
        }
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            guard (errno == EWOULDBLOCK || errno == EAGAIN),
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return body()
        #else
        return body()
        #endif
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
    /// Runs one async ActivityKit batch operation on a detached task and waits
    /// once on a semaphore from the synchronous callback. The configured/
    /// nominal deadline applies to the complete exact-session set; it is not a
    /// guaranteed wall-clock callback bound under preemption, scheduling, or
    /// an extension watchdog.
    public static func run(
        fences: [AmbientLiveActivityTerminationFence],
        waitNanoseconds: UInt64 = AmbientLiveActivityTerminationPolicy.callbackWaitNanoseconds,
        operation: @escaping @Sendable ([AmbientLiveActivityTerminationFence]) async throws -> Int
    ) -> AmbientLiveActivityTerminationResult {
        AmbientLiveActivityBatchWaitRunner.run(
            fences: fences,
            waitNanoseconds: waitNanoseconds,
            operation: operation
        )
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

    /// Ends every duplicate matching each exact fence in one ActivityKit
    /// operation. The caller supplies the complete batch before launching the
    /// operation; exact duplicate activities are intentionally all ended.
    public static func endExactSessions(
        _ fences: [AmbientLiveActivityTerminationFence],
        status: AmbientLiveActivityStatus
    ) async -> Int {
        var uniqueFences: [AmbientLiveActivityTerminationFence] = []
        var seen = Set<AmbientLiveActivityTerminationFence>()
        for fence in fences where seen.insert(fence).inserted {
            uniqueFences.append(fence)
        }
        var endedCount = 0
        for fence in uniqueFences {
            let matches = Activity<AmbientLiveActivityAttributes>.activities.filter {
                AmbientLiveActivityTermination.matchesExactSession(
                    activity: $0.attributes,
                    sessionID: fence.sessionID,
                    fixedEnd: fence.fixedEnd,
                    kind: fence.kind
                )
            }
            let state = AmbientActivityContentState(fixedEnd: fence.fixedEnd, status: status)
            for activity in matches {
                await activity.end(
                    .init(state: state, staleDate: fence.fixedEnd),
                    dismissalPolicy: .immediate
                )
            }
            endedCount += matches.count
        }
        return endedCount
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
