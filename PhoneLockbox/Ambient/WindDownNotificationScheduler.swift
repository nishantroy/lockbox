import Foundation
import AmbientKit
#if canImport(UserNotifications)
import UserNotifications
#endif

#if canImport(UserNotifications)

/// Owns only the `com.phone-lockbox.ambient.wind-down.` namespace. It never
/// requests permission implicitly; the host must call requestAuthorization from
/// an explicit user action first.
@available(iOS 17.0, macOS 13.0, *)
public actor WindDownNotificationScheduler {
    public enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral
    }

    public enum SchedulerError: Error, LocalizedError, Equatable, Sendable {
        case permissionRequired
        case authorizationDenied
        case tooManyRequests
        case invalidRequestIdentifier
        case insufficientQueueCapacity(available: Int, requested: Int)
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .permissionRequired: return "Notification permission has not been requested."
            case .authorizationDenied: return "Notifications are disabled for Phone Lockbox."
            case .tooManyRequests: return "Wind-down scheduling is limited to seven notifications."
            case .invalidRequestIdentifier: return "A wind-down request had an invalid identifier."
            case .insufficientQueueCapacity(let available, let requested):
                return "Wind-down was not changed: only \(available) notification queue slot(s) are available for \(requested) request(s)."
            case .underlying(let message): return message
            }
        }
    }

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorization() async -> Authorization {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: Authorization
                switch settings.authorizationStatus {
                case .notDetermined: status = .notDetermined
                case .denied: status = .denied
                case .authorized: status = .authorized
                case .provisional: status = .provisional
                case .ephemeral: status = .ephemeral
                @unknown default: status = .denied
                }
                // Transfer only our Sendable value, not UNNotificationSettings.
                continuation.resume(returning: status)
            }
        }
    }

    /// Call only from an explicit user gesture. Scheduling does not call this.
    public func requestAuthorization() async throws -> Authorization {
        do {
            let granted = try await requestAuthorizationFromSystem()
            guard granted else { return .denied }
            return await authorization()
        } catch {
            throw SchedulerError.underlying(error.localizedDescription)
        }
    }

    /// Replaces this adapter's requests and leaves every other app request alone.
    /// The supplied occurrences are already concrete and are never repeating.
    /// Capacity is checked before owned requests are removed. If a later add
    /// fails, the transaction reports whether the old schedule was restored.
    public func replace(
        occurrences: [WindDownOccurrence]
    ) async throws -> WindDownReplacementOutcome {
        guard occurrences.count <= WindDownConfiguration.maximumScheduledOccurrences else {
            throw SchedulerError.tooManyRequests
        }
        guard occurrences.allSatisfy({ $0.identifier.hasPrefix(WindDownNotificationNamespace.prefix) }),
              Set(occurrences.map(\.identifier)).count == occurrences.count else {
            throw SchedulerError.invalidRequestIdentifier
        }

        switch await authorization() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            throw SchedulerError.permissionRequired
        case .denied:
            throw SchedulerError.authorizationDenied
        }

        let requests = occurrences.map { occurrence in
            let content = UNMutableNotificationContent()
            content.title = "Wind-down"
            content.body = "Your bedtime starts soon. This reminder is informational and does not enforce a lock."
            content.sound = .default
            // The planner already resolved this absolute occurrence. Never
            // reinterpret it in a possibly changed device calendar/time zone.
            let trigger = UNCalendarNotificationTrigger(dateMatching: occurrence.triggerComponents, repeats: false)
            return StoredNotificationRequest(
                identifier: occurrence.identifier,
                request: UNNotificationRequest(
                    identifier: occurrence.identifier,
                    content: content,
                    trigger: trigger
                )
            )
        }

        do {
            return try await WindDownNotificationReplacementEngine.replace(
                store: UserNotificationCenterStore(center: center),
                requests: requests,
                identifier: \.identifier
            )
        } catch WindDownPlanningError.insufficientQueueCapacity(let available, let requested) {
            throw SchedulerError.insufficientQueueCapacity(available: available, requested: requested)
        } catch WindDownPlanningError.invalidLimit {
            throw SchedulerError.tooManyRequests
        } catch {
            throw SchedulerError.underlying(error.localizedDescription)
        }
    }

    public func pendingOwnedRequestCount() async -> Int {
        await pendingIdentifiers().filter { $0.hasPrefix(WindDownNotificationNamespace.prefix) }.count
    }

    /// Disabling wind-down removes only this adapter's requests.
    public func disable() async {
        let pending = await pendingIdentifiers()
        let ownIDs = pending.filter { $0.hasPrefix(WindDownNotificationNamespace.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ownIDs)
    }

    private func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests {
                continuation.resume(returning: $0.map(\.identifier))
            }
        }
    }

    private func requestAuthorizationFromSystem() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }
}

// UNNotificationRequest is an immutable request snapshot. Never expose mutable
// content through this bridge; replacement constructs a fresh system request.
private struct StoredNotificationRequest: @unchecked Sendable {
    let identifier: String
    let request: UNNotificationRequest
}

// The system notification center supports asynchronous access from multiple
// queues. This adapter has no mutable Swift state; all mutations go through the
// center's APIs. The SDK's Objective-C type lacks Sendable annotations.
private struct UserNotificationCenterStore: WindDownNotificationStore, @unchecked Sendable {
    let center: UNUserNotificationCenter

    func pendingRequests() async -> [StoredNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(
                    returning: requests.map {
                        StoredNotificationRequest(identifier: $0.identifier, request: $0)
                    }
                )
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ request: StoredNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request.request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
#endif
