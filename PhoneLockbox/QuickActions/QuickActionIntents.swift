import AppIntents
import Foundation

/// App Intents are deliberately navigation-only. The app receives a short-lived
/// URL and presents its existing confirmation/status/recovery UI; no intent
/// calls Managed Settings, changes rules, or releases a session.
struct StartThirtyMinuteFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start 30-Minute Focus"
    static let description = IntentDescription("Open Phone Lockbox to review and confirm a finite 30-minute focus session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard QuickActionPendingRouteStore.enqueue(.focus(.thirtyMinutes)) else {
            return .result(dialog: "Phone Lockbox could not create a safe confirmation link. No lock was changed.")
        }
        return .result(dialog: "Phone Lockbox will ask you to confirm a finite 30-minute focus session.")
    }
}

struct StartOneHourFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start One-Hour Focus"
    static let description = IntentDescription("Open Phone Lockbox to review and confirm a finite one-hour focus session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard QuickActionPendingRouteStore.enqueue(.focus(.oneHour)) else {
            return .result(dialog: "Phone Lockbox could not create a safe confirmation link. No lock was changed.")
        }
        return .result(dialog: "Phone Lockbox will ask you to confirm a finite one-hour focus session.")
    }
}

struct ShowLockboxStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Phone Lockbox Status"
    static let description = IntentDescription("Open Phone Lockbox and show current lock status. This does not change restrictions.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard QuickActionPendingRouteStore.enqueue(.status) else {
            return .result(dialog: "Phone Lockbox could not open its status safely. No lock was changed.")
        }
        return .result(dialog: "Opening Phone Lockbox status.")
    }
}

struct OpenLockboxRecoveryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Phone Lockbox Recovery"
    static let description = IntentDescription("Open Phone Lockbox recovery. Recovery remains delayed and requires explicit confirmation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard QuickActionPendingRouteStore.enqueue(.recovery) else {
            return .result(dialog: "Phone Lockbox could not open recovery safely. No lock was changed.")
        }
        return .result(dialog: "Opening Phone Lockbox recovery. A wait and explicit confirmation are still required.")
    }
}

struct PhoneLockboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartThirtyMinuteFocusIntent(),
            phrases: ["Start a 30-minute focus session in \(.applicationName)"],
            shortTitle: "30-Minute Focus",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: StartOneHourFocusIntent(),
            phrases: ["Start a one-hour focus session in \(.applicationName)"],
            shortTitle: "One-Hour Focus",
            systemImageName: "hourglass"
        )
        AppShortcut(
            intent: ShowLockboxStatusIntent(),
            phrases: ["Show my lock status in \(.applicationName)"],
            shortTitle: "Lockbox Status",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: OpenLockboxRecoveryIntent(),
            phrases: ["Open recovery in \(.applicationName)"],
            shortTitle: "Open Recovery",
            systemImageName: "arrow.uturn.backward.circle"
        )
    }
}
