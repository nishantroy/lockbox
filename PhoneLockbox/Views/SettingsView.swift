import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var showingDeveloperUnlock = false
    @State private var showingEmergencyReset = false

    var body: some View {
        Form {
            Section("Bedtime schedule") {
                if coordinator.isConfigured {
                    NavigationLink {
                        ConfigurationEditorView(coordinator: coordinator, isInitialSetup: false)
                    } label: {
                        Label("Schedule and restrictions", systemImage: "calendar.badge.clock")
                    }
                    Text("Edits made during a committed lock are queued and cannot weaken that lock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Finish setup from the Lockbox tab", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recovery") {
                LabeledContent("Wait", value: "15 minutes")
                Text("Recovery always requires this fixed wait and an explicit confirmation. Waiting alone never unlocks the phone. It does not disable future bedtime sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Wind-down") {
                Toggle("Wind-down reminders", isOn: Binding(
                    get: { coordinator.windDownEnabled },
                    set: { coordinator.setWindDownEnabled($0) }
                ))
                Stepper(value: Binding(
                    get: { coordinator.windDownLeadMinutes },
                    set: { coordinator.setWindDownLeadMinutes($0) }
                ), in: coordinator.windDownLeadChoices, step: 5) {
                    Text("Lead time: \(coordinator.windDownLeadMinutes) minutes")
                }
                .disabled(!coordinator.windDownEnabled)
                Text("Wind-down derives its reminder time from the saved bedtime start. There is no second bedtime clock.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Allow notifications") {
                    Task { await coordinator.requestWindDownNotificationAuthorization() }
                }
                LabeledContent("Notification access", value: coordinator.windDownAuthorizationStatus)
                if coordinator.windDownEnabled {
                    Text(coordinator.pendingWindDownNotificationCount == 0
                         ? "No reminder is currently scheduled."
                         : "You’ll be reminded \(coordinator.windDownLeadMinutes) minutes before bedtime.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = coordinator.ambientError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Live Activity") {
                Toggle("Show lock status when available", isOn: Binding(
                    get: { coordinator.liveActivityEnabled },
                    set: { coordinator.setLiveActivityEnabled($0) }
                ))
                Text("Live Activity is a best-effort status surface. It never enforces, releases, or proves that restrictions changed; scheduled sessions may appear only after a later foreground update.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            DeveloperToolsSection(
                coordinator: coordinator,
                showingDeveloperUnlock: $showingDeveloperUnlock,
                showingEmergencyReset: $showingEmergencyReset
            )
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Unlock current Phone Lockbox sessions?",
            isPresented: $showingDeveloperUnlock,
            titleVisibility: .visible
        ) {
            Button("Developer unlock now", role: .destructive) {
                coordinator.developerUnlockNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Developer-only escape hatch. This releases current Phone Lockbox sessions immediately and does not prove that other owners or system restrictions are cleared.")
        }
        .confirmationDialog(
            "Reset Phone Lockbox state?",
            isPresented: $showingEmergencyReset,
            titleVisibility: .visible
        ) {
            Button("Emergency reset", role: .destructive) {
                coordinator.emergencyReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops Phone Lockbox monitoring and clears this app's named Managed Settings and shared state. Use only when ordinary cleanup is unavailable.")
        }
    }
}

private struct DeveloperToolsSection: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @Binding var showingDeveloperUnlock: Bool
    @Binding var showingEmergencyReset: Bool

    var body: some View {
        Section("Developer") {
            NavigationLink {
                AmbientPrototypeView()
            } label: {
                Label("Ambient standalone screen", systemImage: "waveform.path.ecg")
            }
            Text("Prototype wind-down and Live Activity controls are intentionally separate from the saved lock. They never apply or release restrictions.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                coordinator.startImmediateTestLock()
            } label: {
                Label(
                    coordinator.testScheduleActive ? "Prototype test is active" : "Start prototype test",
                    systemImage: coordinator.testScheduleActive ? "checkmark.circle.fill" : "bolt.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!coordinator.canApplySelection || coordinator.testScheduleActive || coordinator.hasOSRegistration || coordinator.recurringEnabledIntent || !coordinator.isAuthorized)
            Text(coordinator.testScheduleActive
                 ? "This developer restriction remains until Developer unlock now is used."
                 : "The prototype test is not part of normal Lockbox operation and is mutually exclusive with recurring monitoring.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if coordinator.recurringEnabledIntent || coordinator.hasOSRegistration {
                Button("Disable recurring schedule", role: .destructive) {
                    coordinator.stopSchedule()
                }
            }
            Button("Developer unlock now", role: .destructive) {
                showingDeveloperUnlock = true
            }
            Button("Emergency reset shared state", role: .destructive) {
                showingEmergencyReset = true
            }
            Text("Use these controls only for development cleanup. Manual cleanup is not proof of automatic release.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if coordinator.legacyRegistrationNeedsReview {
                Label("Legacy monitoring ownership needs explicit cleanup; do not assume the phone is unlocked.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            DiagnosticsSection(coordinator: coordinator)
        }
    }
}
