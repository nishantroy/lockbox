import Foundation

#if canImport(CompanionKit)
import CompanionKit
import Security

/// Where the owner device keeps every `IssuedInvite` (invitation **and its
/// token**) for as long as the pairing it created exists. The token is the
/// link secret and `JoinedAcceptanceCheck` needs it on every inbox fetch to
/// prove that a relay-reported pairing really came from the link holder, so it
/// lives in the Keychain, never in plain `UserDefaults` (pairing v3,
/// `docs/r5-pairing-v3-plan.md`, P3a review follow-up 2).
protocol IssuedInviteStore: AnyObject {
    func load() -> IssuedInviteLoad
    /// `false` when the write did not happen; the caller must treat the invite as not stored.
    @discardableResult func save(_ invites: [String: IssuedInvite]) -> Bool
    func removeAll()
}

/// A read must tell "nothing stored yet" from "could not read" (for example the
/// Keychain is locked, or the item no longer decodes). On `.failed` the app
/// keeps its previously verified people as they are and never writes over the item.
enum IssuedInviteLoad {
    case found([String: IssuedInvite])
    case notFound
    case failed
}

/// Keychain-backed store: one generic-password item holding the JSON map,
/// readable after first unlock and never synced or backed up off this device.
final class KeychainIssuedInviteStore: IssuedInviteStore {
    private let service: String
    private let account = "issued-invites.v1"

    init(service: String = "com.phone-lockbox.companion.invites") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> IssuedInviteLoad {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        // Anything else (errSecInteractionNotAllowed while locked, decode failure, ...) is an error, not "empty".
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: IssuedInvite].self, from: data) else { return .failed }
        return .found(decoded)
    }

    @discardableResult
    func save(_ invites: [String: IssuedInvite]) -> Bool {
        if invites.isEmpty { removeAll(); return true }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(invites) else { return false }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func removeAll() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory store for tests and for any coordinator built with an injected
/// (non-Keychain) key store. Reference type so two coordinators can share it
/// to model a relaunch.
final class InMemoryIssuedInviteStore: IssuedInviteStore {
    var invites: [String: IssuedInvite] = [:]
    /// Test hooks: simulate a locked/broken Keychain.
    var failLoads = false
    var failSaves = false
    func load() -> IssuedInviteLoad {
        if failLoads { return .failed }
        return invites.isEmpty ? .notFound : .found(invites)
    }
    @discardableResult
    func save(_ invites: [String: IssuedInvite]) -> Bool {
        if failSaves { return false }
        self.invites = invites
        return true
    }
    func removeAll() { invites = [:] }
}
#endif
