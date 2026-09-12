import SwiftUI
import FamilyControls

struct LockboxTabView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var showingManualLock = false

    var body: some View {
        Group {
            if !coordinator.isConfigured {
                SetupView(coordinator: coordinator)
            } else if coordinator.hasActiveLock {
                ActiveLockView(coordinator: coordinator)
            } else {
                UnlockedLockboxView(coordinator: coordinator, showingManualLock: $showingManualLock)
            }
        }
        .navigationTitle("Lockbox")
        .sheet(isPresented: $showingManualLock) {
            ManualLockSheet(coordinator: coordinator)
        }
    }
}

private struct SetupView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        Form {
            Section {
                Label("A calmer phone at night", systemImage: "moon.stars")
                    .font(.headline)
                Text("Keep essentials available while making app-hopping inconvenient during bedtime.")
                    .foregroundStyle(.secondary)
                Text("You can use People and Settings without granting Screen Time access. Access is needed only to save and enforce your own rules.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Screen Time access") {
                LabeledContent("Status", value: AuthorizationStatusLabel.value(for: coordinator))
                if coordinator.isAuthorized {
                    NavigationLink {
                        ConfigurationEditorView(coordinator: coordinator, isInitialSetup: true)
                    } label: {
                        Label("Set up bedtime rules", systemImage: "slider.horizontal.3")
                    }
                } else {
                    Button("Request access") {
                        Task { await coordinator.requestAuthorization() }
                    }
                    .accessibilityHint("Opens Apple's Screen Time authorization prompt")
                    Text("Bedtime settings and app selection become available after access is granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.lastError {
                Section("Needs attention") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct UnlockedLockboxView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @Binding var showingManualLock: Bool

    var body: some View {
        Form {
            Section {
                Button {
                    showingManualLock = true
                } label: {
                    Label("Lock now", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.isAuthorized)
                .accessibilityHint("Choose a finite focus lock duration")
                Text("Starts a separate, finite lock using your saved policy. The end is confirmed before anything is applied.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Ready when you are")
            }

            TonightCard(coordinator: coordinator)

            Section("Saved rules") {
                LabeledContent("Restriction", value: coordinator.savedModeTitle)
                LabeledContent("Bedtime", value: SavedWindowFormatter.value(for: coordinator))
                LabeledContent("Selection", value: "\(coordinator.savedSelectedItemCount) selected")
            }

            Section("Wind-down") {
                Label(coordinator.windDownEnabled ? "Enabled" : "Off", systemImage: coordinator.windDownEnabled ? "bell.badge" : "bell.slash")
                Text(coordinator.ambientStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Change wind-down settings") {
                    SettingsView(coordinator: coordinator)
                }
            }

            OperationalWarning(coordinator: coordinator)
        }
    }
}

private struct TonightCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        Section("Tonight") {
            if coordinator.recurringEnabledIntent, let occurrence = nextOccurrence {
                LabeledContent("Next start", value: occurrence.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Ends", value: occurrence.end.formatted(date: .abbreviated, time: .shortened))
                Text("Your saved bedtime rules will be used for this automatic session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("Automatic bedtime schedule is off", systemImage: "calendar.badge.exclamationmark")
                Text("Save and register a schedule in Settings to turn on automatic sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nextOccurrence: RuntimeOccurrenceResolver.Occurrence? {
        RuntimeOccurrenceResolver.currentOrNext(
            start: RuntimeTime(hour: coordinator.savedStartComponents.hour ?? 22, minute: coordinator.savedStartComponents.minute ?? 0),
            end: RuntimeTime(hour: coordinator.savedEndComponents.hour ?? 7, minute: coordinator.savedEndComponents.minute ?? 0),
            enabled: true,
            after: Date()
        )
    }
}

struct ActiveLockView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        Form {
            Section {
                Label(coordinator.activeLockTitle, systemImage: "lock.fill")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("This lock is committed. Routine settings do not change it.")
                    .foregroundStyle(.secondary)
            }

            Section("Current lock") {
                if let end = coordinator.activeLockEnd {
                    LabeledContent("Fixed end", value: end.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("The active lock has no trustworthy end time. Use Developer in Settings only if cleanup is required.")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Origin", value: coordinator.activeLockTitle)
                LabeledContent("Active sessions", value: "\(coordinator.activeSessionCount)")
            }

            if let pending = coordinator.pendingChangesSummary {
                Section("Changes after this lock") {
                    Label(pending, systemImage: "clock.arrow.circlepath")
                    Text("These changes are queued and cannot weaken the current committed lock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recovery") {
                Text("Recovery has a fixed wait and explicit confirmation. It ends this lock only; future bedtime sessions remain enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Recovery options") {
                    RecoveryView(coordinator: coordinator)
                }
            }

            OperationalWarning(coordinator: coordinator)
        }
    }
}

struct OperationalWarning: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        if let error = coordinator.lastError {
            Section("Needs attention") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private enum AuthorizationStatusLabel {
    static func value(for coordinator: ScreenTimeCoordinator) -> String {
        if coordinator.isAuthorized { return "Authorized" }
        switch coordinator.authorizationStatus {
        case .approved: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        default: return "Unknown"
        }
    }
}

private enum SavedWindowFormatter {
    static func value(for coordinator: ScreenTimeCoordinator) -> String {
        let start = coordinator.savedStartComponents
        let end = coordinator.savedEndComponents
        return "\(String(format: "%02d:%02d", start.hour ?? 0, start.minute ?? 0)) – \(String(format: "%02d:%02d", end.hour ?? 0, end.minute ?? 0))"
    }
}
