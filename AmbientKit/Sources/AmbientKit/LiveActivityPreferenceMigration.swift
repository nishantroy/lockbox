import Foundation

/// Versioned local consent for the optional Live Activity presentation.
/// Missing or pre-build-14 values deliberately migrate to off; a current
/// version preserves only the user's explicit current-version choice.
public struct AmbientLiveActivityPreference: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let enabled: Bool

    public init(version: Int = currentVersion, enabled: Bool) {
        self.version = version
        self.enabled = enabled
    }
}

public enum AmbientLiveActivityPreferenceMigration {
    public static func migrate(
        storedVersion: Int?,
        storedEnabled: Bool?
    ) -> AmbientLiveActivityPreference {
        guard storedVersion == AmbientLiveActivityPreference.currentVersion else {
            return AmbientLiveActivityPreference(enabled: false)
        }
        return AmbientLiveActivityPreference(enabled: storedEnabled ?? false)
    }
}
