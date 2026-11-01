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
    static let message = "Notifications are off, so you won't hear about requests."

    /// One quiet row, only when the person has at least one pairing and has
    /// explicitly denied notifications.
    static func isVisible(permission: NotificationPermission, pairingCount: Int) -> Bool {
        permission == .denied && pairingCount > 0
    }
}

enum PushPromptPolicy {
    /// An approver who paired before push existed never hit another prompt
    /// moment; ask when People appears, only while still undecided.
    static func shouldPromptOnPeopleAppear(permission: NotificationPermission, helpingCount: Int) -> Bool {
        permission == .notDetermined && helpingCount > 0
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
