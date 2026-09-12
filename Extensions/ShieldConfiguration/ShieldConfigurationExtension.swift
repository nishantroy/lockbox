import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    private func configuration() -> ShieldConfiguration {
        ShieldConfiguration(
            title: ShieldConfiguration.Label(text: "Unavailable during this lock", color: .label),
            subtitle: ShieldConfiguration.Label(text: "Open Phone Lockbox to review your restrictions.", color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Keep lock active", color: .label)
        )
    }
}
