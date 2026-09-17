import Foundation

/// The App Intent handoff contains only a short-lived navigation URL. It is
/// not runtime state and is removed when the host app reads it.
enum QuickActionPendingRouteStore {
    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private static let pendingURLKey = "phone-lockbox.quick-action.pending-url"

    static func enqueue(_ action: QuickActionRoute.Action, now: Date = Date()) -> Bool {
        guard let url = QuickActionRoute.url(for: action, now: now),
              let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
        defaults.set(url.absoluteString, forKey: pendingURLKey)
        return true
    }

    static func take() -> URL? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let value = defaults.string(forKey: pendingURLKey) else { return nil }
        defaults.removeObject(forKey: pendingURLKey)
        return URL(string: value)
    }
}
