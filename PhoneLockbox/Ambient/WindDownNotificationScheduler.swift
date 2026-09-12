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
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .permissionRequired: return "Notification permission has not been requested."
            case .authorizationDenied: return "Notifications are disabled for Phone Lockbox."
            case .tooManyRequests: return "Wind-down scheduling is limited to seven notifications."
            case .invalidRequestIdentifier: return "A wind-down request had an invalid identifier."
            case .underlying(let message): return message
            }
        }
    }

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorization() async -> Authorization {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
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
    public func replace(occurrences: [WindDownOccurrence], calendar: Calendar) async throws {
        guard occurrences.count <= WindDownConfiguration.maximumScheduledOccurrences else {
            throw SchedulerError.tooManyRequests
        }
        guard occurrences.allSatisfy({ $0.identifier.hasPrefix(WindDownNotificationNamespace.prefix) }) else {
            throw SchedulerError.invalidRequestIdentifier
        }
        guard Set(occurrences.map(\.identifier)).count == occurrences.count else {
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

        let pending = await pendingRequests()
        let ownIDs = pending.map(\.identifier).filter { $0.hasPrefix(WindDownNotificationNamespace.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ownIDs)

        for occurrence in occurrences {
            let content = UNMutableNotificationContent()
            content.title = "Wind-down soon"
            content.body = "Your planned bedtime session begins soon."
            content.sound = .default
            var components = occurrence.triggerComponents
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: occurrence.identifier, content: content, trigger: trigger)
            do {
                try await add(request)
            } catch {
                throw SchedulerError.underlying(error.localizedDescription)
            }
        }
    }

    /// Disabling wind-down removes only this adapter's requests.
    public func disable() async {
        let pending = await pendingRequests()
        let ownIDs = pending.map(\.identifier).filter { $0.hasPrefix(WindDownNotificationNamespace.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ownIDs)
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
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

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
#endif
