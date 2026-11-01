import CryptoKit
import Foundation

// Pure, host-testable pieces of the APNs wake-up flow (R5 slice P4,
// docs/r5-apns-plan.md). Nothing here touches UIKit, UserNotifications or
// CompanionKit; the app glue lives in PhoneLockbox/Companion. A push is only
// ever a hint to fetch the signed inbox, never state, and the device token is
// never logged.

/// The top-level `kind` of a Phone Lockbox wake-up payload.
enum PushWakeKind: String, Equatable, Sendable {
    case request, answer, joined

    /// Unknown, missing or non-string kinds return nil and are ignored, so
    /// every other notification keeps its existing behavior.
    static func parse(userInfo: [AnyHashable: Any]) -> PushWakeKind? {
        guard let raw = userInfo["kind"] as? String else { return nil }
        return PushWakeKind(rawValue: raw)
    }
}

/// `sandbox` in DEBUG builds, `production` otherwise (matches the
/// `aps-environment` the build is signed with).
enum PushEnvironmentName {
    static func current(isDebug: Bool) -> String { isDebug ? "sandbox" : "production" }

    static var forThisBuild: String {
        #if DEBUG
        return current(isDebug: true)
        #else
        return current(isDebug: false)
        #endif
    }
}

/// System notification permission, reduced to what the UI needs.
enum NotificationPermission: Equatable, Sendable {
    case notDetermined, denied, allowed
}

enum NotificationsOffRow {
    /// One quiet row, only when the person has at least one pairing and has
    /// explicitly denied notifications.
    static func isVisible(permission: NotificationPermission, pairingCount: Int) -> Bool {
        permission == .denied && pairingCount > 0
    }

    /// Role-aware copy. `helpingNames` are the people this device helps (it
    /// receives their requests); `trustedNames` are the people who help this
    /// device's owner (it receives their answers). A real name is used only
    /// when exactly one person is on that side.
    static func message(helpingNames: [String], trustedNames: [String]) -> String {
        switch (!helpingNames.isEmpty, !trustedNames.isEmpty) {
        case (true, true):
            return "Notifications are off, so you won't hear about requests or answers."
        case (true, false):
            return helpingNames.count == 1
                ? "Notifications are off, so you won't hear when \(helpingNames[0]) asks."
                : "Notifications are off, so you won't hear when they ask."
        case (false, true):
            return trustedNames.count == 1
                ? "Notifications are off, so you won't hear when \(trustedNames[0]) answers."
                : "Notifications are off, so you won't hear when they answer."
        case (false, false):
            return "Notifications are off."
        }
    }
}

enum PushPromptPolicy {
    /// An approver who paired before push existed never hit another prompt
    /// moment; offer the inline card while still undecided and helping someone.
    static func shouldPromptOnPeopleAppear(permission: NotificationPermission, helpingCount: Int) -> Bool {
        permission == .notDetermined && helpingCount > 0
    }
}

/// The inline "Get notified" card in People. It replaces the old automatic
/// system prompt when People appeared.
enum NotificationCard {
    static let snoozeInterval: TimeInterval = 7 * 24 * 3_600
    static let snoozeDefaultsKey = "com.phone-lockbox.companion.notificationCardSnoozedUntil.v1"

    /// Shown while undecided to anyone who helps someone (receives requests)
    /// or has at least one trusted person (receives answers).
    static func isVisible(permission: NotificationPermission, helpingCount: Int, trustedCount: Int = 0,
                          snoozedUntil: Date?, now: Date) -> Bool {
        guard permission == .notDetermined, helpingCount > 0 || trustedCount > 0 else { return false }
        // A stamp further out than one snooze (clock moved back) is ignored.
        if let snoozedUntil, snoozedUntil > now, snoozedUntil.timeIntervalSince(now) <= snoozeInterval { return false }
        return true
    }

    static func title(helpingNames: [String], trustedNames: [String] = []) -> String {
        switch (!helpingNames.isEmpty, !trustedNames.isEmpty) {
        case (true, false) where helpingNames.count == 1: return "Get notified when \(helpingNames[0]) asks"
        case (false, true) where trustedNames.count == 1: return "Get notified when \(trustedNames[0]) answers"
        case (true, false): return "Get notified when someone asks"
        case (false, true): return "Get notified when someone answers"
        case (false, false): return "Get notified when someone asks"
        default: return "Get notified about requests and answers"
        }
    }

    static func body(helpingNames: [String], trustedNames: [String] = []) -> String {
        switch (!helpingNames.isEmpty, !trustedNames.isEmpty) {
        case (true, true): return "Otherwise you'll only see updates when you open People."
        case (false, true): return "Otherwise you'll only see answers when you open People."
        default: return "Otherwise you'll only see requests when you open People."
        }
    }

    static func snoozedUntil(in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: snoozeDefaultsKey) as? Date
    }

    @discardableResult
    static func snooze(in defaults: UserDefaults, now: Date) -> Date {
        let until = now.addingTimeInterval(snoozeInterval)
        defaults.set(until, forKey: snoozeDefaultsKey)
        return until
    }
}

/// Whether an invite-link moment should ask for notification permission now.
/// The ask is deferred until the person returns from sharing (or copies the
/// link), once per link.
enum InvitePromptTrigger {
    /// Fires on the next return to the app, or on Copy link, whichever is
    /// first, only while a link was just created and is still live.
    static func shouldFire(pending: Bool, linkIsLive: Bool) -> Bool { pending && linkIsLive }

    /// A share sheet never changes scene phase, so a pending flag older than
    /// this is dropped silently instead of prompting hours later.
    static let pendingLifetime: TimeInterval = 10 * 60

    static func shouldFire(pendingSince: Date?, linkIsLive: Bool, now: Date) -> Bool {
        guard let pendingSince else { return false }
        let age = now.timeIntervalSince(pendingSince)
        // A stamp from the future (clock moved back) counts as expired.
        return age >= 0 && age <= pendingLifetime && linkIsLive
    }
}

/// Foreground push presentation: People already shows the request, so no
/// banner or sound while it is the selected tab of the active app.
enum PushForegroundPresentation {
    static func showsBanner(peopleTabSelected: Bool, appIsActive: Bool) -> Bool {
        !(peopleTabSelected && appIsActive)
    }
}

/// Detail line of the friend's "You're now a trusted person" notice.
enum AcceptedNoticeCopy {
    static func detail(ownerName: String, notificationsAllowed: Bool) -> String {
        notificationsAllowed
            ? "\(ownerName) can ask you to approve ending a lock early. We'll let you know when \(ownerName) asks."
            : "\(ownerName) can ask you to approve ending a lock early. You'll see requests here."
    }
}

/// Remembers what was last registered, per identity, so the relay is only
/// contacted when `(identityID, token, environment)` changes or after seven
/// days. Only a SHA-256 fingerprint is stored, never the token itself.
struct PushRegistrationLedger {
    static let resendInterval: TimeInterval = 7 * 24 * 3_600
    static let defaultsKey = "com.phone-lockbox.companion.pushRegistrations.v1"

    private struct Entry: Codable { var fingerprint: String; var sentAt: Date }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    static func fingerprint(identityID: String, token: String, environment: String) -> String {
        let digest = SHA256.hash(data: Data("\(identityID)|\(token)|\(environment)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    func needsSend(identityID: String, token: String, environment: String, now: Date) -> Bool {
        guard let entry = load()[identityID],
              entry.fingerprint == Self.fingerprint(identityID: identityID, token: token, environment: environment) else { return true }
        let age = now.timeIntervalSince(entry.sentAt)
        // A clock that moved backwards re-sends rather than trusting a future stamp.
        return age < 0 || age >= Self.resendInterval
    }

    func recordSent(identityID: String, token: String, environment: String, now: Date) {
        var entries = load()
        entries[identityID] = Entry(fingerprint: Self.fingerprint(identityID: identityID, token: token, environment: environment),
                                    sentAt: now)
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Registers the device's APNs token under every local identity. Failures are
/// swallowed (the next launch or foreground retries) and nothing is logged.
@MainActor
final class PushRegistrar {
    private let ledger: PushRegistrationLedger
    private let environment: String
    private let now: () -> Date
    private let identityIDs: () -> [String]
    private let send: (_ identityID: String, _ token: String, _ environment: String) async throws -> Void
    private var syncing = false
    private var syncAgain = false

    private(set) var deviceToken: String?

    init(ledger: PushRegistrationLedger,
         environment: String,
         now: @escaping () -> Date = Date.init,
         identityIDs: @escaping () -> [String],
         send: @escaping (_ identityID: String, _ token: String, _ environment: String) async throws -> Void) {
        self.ledger = ledger
        self.environment = environment
        self.now = now
        self.identityIDs = identityIDs
        self.send = send
    }

    /// Lowercase hex of the raw APNs token bytes.
    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func updateDeviceToken(_ data: Data) { deviceToken = Self.hex(data) }

    func updateDeviceToken(hex: String) { deviceToken = hex }

    /// Sends the token for each identity that needs it. Concurrent calls
    /// coalesce into one more pass.
    func sync() async {
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            guard let token = deviceToken else { return }
            for identityID in identityIDs() {
                let stamp = now()
                guard ledger.needsSend(identityID: identityID, token: token, environment: environment, now: stamp) else { continue }
                do {
                    try await send(identityID, token, environment)
                    ledger.recordSent(identityID: identityID, token: token, environment: environment, now: stamp)
                } catch {
                    // Retried on the next launch or foreground.
                }
            }
        } while syncAgain
    }
}
