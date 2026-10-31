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
    func load() -> [String: IssuedInvite]
    func save(_ invites: [String: IssuedInvite])
    func removeAll()
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

    func load() -> [String: IssuedInvite] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: IssuedInvite].self, from: data) else { return [:] }
        return decoded
    }

    func save(_ invites: [String: IssuedInvite]) {
        if invites.isEmpty { removeAll(); return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(invites) else { return }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func removeAll() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory store for tests and for any coordinator built with an injected
/// (non-Keychain) key store. Reference type so two coordinators can share it
/// to model a relaunch.
final class InMemoryIssuedInviteStore: IssuedInviteStore {
    private var invites: [String: IssuedInvite] = [:]
    func load() -> [String: IssuedInvite] { invites }
    func save(_ invites: [String: IssuedInvite]) { self.invites = invites }
    func removeAll() { invites = [:] }
}
#endif
