import Foundation

/// The single durable record for the optional Live Activity presentation.
///
/// This is intentionally one Codable value rather than a version key and an
/// enabled key. A process can therefore observe either the previous complete
/// record or no usable record; it cannot mistake an interrupted pair of
/// legacy writes for an explicit opt-in.
public struct AmbientLiveActivityPreference: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let enabled: Bool

    public init(version: Int = currentVersion, enabled: Bool) {
        self.version = version
        self.enabled = enabled
    }

    /// Encodes the complete preference record for storage in UserDefaults.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes only a record from the currently supported schema. Unknown
    /// versions and malformed data are not preferences and must migrate off.
    public static func decodeCurrent(_ data: Data) -> AmbientLiveActivityPreference? {
        guard let preference = try? JSONDecoder().decode(Self.self, from: data),
              preference.version == currentVersion else {
            return nil
        }
        return preference
    }
}

public enum AmbientLiveActivityPreferenceMigration {
    /// The result of resolving a stored record. `shouldPersist` is true for a
    /// missing, malformed, or unknown-version record. Callers must persist
    /// the returned safe value before removing obsolete legacy keys.
    public struct Resolution: Equatable, Sendable {
        public let preference: AmbientLiveActivityPreference
        public let shouldPersist: Bool

        public init(preference: AmbientLiveActivityPreference, shouldPersist: Bool) {
            self.preference = preference
            self.shouldPersist = shouldPersist
        }
    }

    /// Resolves the new encoded record. Legacy split values are accepted only
    /// to make the migration boundary explicit; they are never interpreted as
    /// opt-in. This includes the interrupted state where an old version key
    /// looks current while the old enabled key is true.
    public static func resolve(
        encodedRecord: Data?,
        legacyVersion: Int? = nil,
        legacyEnabled: Bool? = nil
    ) -> Resolution {
        if let encodedRecord, let preference = AmbientLiveActivityPreference.decodeCurrent(encodedRecord) {
            return Resolution(preference: preference, shouldPersist: false)
        }
        return Resolution(
            preference: AmbientLiveActivityPreference(enabled: false),
            shouldPersist: true
        )
    }

    /// Pure migration entry point used by the host and tests.
    public static func migrate(
        encodedRecord: Data?,
        legacyVersion: Int? = nil,
        legacyEnabled: Bool? = nil
    ) -> AmbientLiveActivityPreference {
        resolve(
            encodedRecord: encodedRecord,
            legacyVersion: legacyVersion,
            legacyEnabled: legacyEnabled
        ).preference
    }

    /// Compatibility helper for callers that still have only the pre-build-14
    /// split values. No split combination is trusted as an opt-in.
    public static func migrate(
        storedVersion: Int?,
        storedEnabled: Bool?
    ) -> AmbientLiveActivityPreference {
        migrate(
            encodedRecord: nil,
            legacyVersion: storedVersion,
            legacyEnabled: storedEnabled
        )
    }
}
