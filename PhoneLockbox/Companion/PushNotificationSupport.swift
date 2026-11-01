import Foundation
#if os(iOS)
import UIKit
import UserNotifications

/// Hands UIKit callbacks (device token, a tapped or foreground wake-up) to the
/// SwiftUI side. Whatever arrives before a handler is attached (a cold launch
/// from a notification tap) is held and delivered once, when it is attached.
@MainActor
final class PushWakeBridge {
    static let shared = PushWakeBridge()

    /// Set by the SwiftUI root: whether People is the selected tab.
    var peopleTabIsSelected: () -> Bool = { false }

    private var pendingToken: Data?
    private var pendingWake: (PushWakeKind, Bool)?

    var deviceTokenHandler: ((Data) -> Void)? {
        didSet {
            guard let handler = deviceTokenHandler, let token = pendingToken else { return }
            pendingToken = nil
            handler(token)
        }
    }

    /// `opened` is true when the person tapped the banner.
    var wakeHandler: ((PushWakeKind, Bool) -> Void)? {
        didSet {
            guard let handler = wakeHandler, let wake = pendingWake else { return }
            pendingWake = nil
            handler(wake.0, wake.1)
        }
    }

    func deliver(deviceToken: Data) {
        if let handler = deviceTokenHandler { handler(deviceToken) } else { pendingToken = deviceToken }
    }

    func deliver(kind: PushWakeKind, opened: Bool) {
        if let handler = wakeHandler { handler(kind, opened) } else if opened || pendingWake == nil { pendingWake = (kind, opened) }
    }
}

/// App delegate for remote-notification registration and the notification
/// center delegate. The app had no `UNUserNotificationCenter` delegate
/// before, so wind-down (local) notifications keep their behavior exactly:
/// they are never shown in the foreground and a tap just opens the app. Only
/// payloads with a recognized top-level `kind` are acted on.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must be set before launch finishes so a cold-launch tap is delivered.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushWakeBridge.shared.deliver(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Retried on the next launch or foreground; nothing to show or log.
    }

    // Completion-handler forms: `UNNotification` is not Sendable, so the
    // payload is parsed synchronously and only the Sendable kind crosses to
    // the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let kind = PushWakeKind.parse(userInfo: notification.request.content.userInfo) else {
            completionHandler([])   // Unchanged: other notifications are not shown in the foreground.
            return
        }
        // The completion handler is only ever called once, from the main actor.
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            PushWakeBridge.shared.deliver(kind: kind, opened: false)
            // People already shows the request: no banner or sound there.
            let showsBanner = PushForegroundPresentation.showsBanner(
                peopleTabSelected: PushWakeBridge.shared.peopleTabIsSelected(),
                appIsActive: UIApplication.shared.applicationState == .active)
            complete(showsBanner ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let kind = PushWakeKind.parse(userInfo: response.notification.request.content.userInfo) {
            Task { @MainActor in PushWakeBridge.shared.deliver(kind: kind, opened: true) }
        }
        completionHandler()
    }
}

/// Reads and asks for notification permission. Asking happens only when the
/// caller says the moment matters; an already-decided choice is never asked
/// again.
@MainActor
enum PushPermissionSystem {
    static func current() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .allowed
        @unknown default: return .denied
        }
    }

    /// Prompts only while the choice is undecided.
    static func requestIfUndecided() async -> NotificationPermission {
        let existing = await current()
        guard existing == .notDetermined else { return existing }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await current()
    }

    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
#endif
