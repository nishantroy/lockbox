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

    private var windDownStatusMessage: String {
        if let error = coordinator.ambientError { return error }
        guard coordinator.windDownEnabled else { return "Off" }
        guard coordinator.windDownAuthorizationStatus != "Not requested" else {
            return "Allow notifications in Settings to turn this on."
        }
        return "You’ll be reminded \(coordinator.windDownLeadMinutes) minutes before bedtime."
    }

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
                Text("Block distractions for 30 minutes, 1 hour, or until a time you choose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Focus when you need it")
            }

            TonightCard(coordinator: coordinator)

            Section("Your rules") {
                LabeledContent("Mode", value: coordinator.savedModeTitle)
                LabeledContent("Apps & categories", value: "\(coordinator.savedSelectedItemCount) selected")
            }

            Section("Wind-down") {
                Label(windDownStatusMessage, systemImage: coordinator.windDownEnabled ? "bell.badge" : "bell.slash")
                    .foregroundStyle(coordinator.ambientError == nil ? Color.primary : Color.orange)
                NavigationLink("Wind-down settings") {
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
                Label("Bedtime lock is set", systemImage: "moon.stars")
                    .font(.headline)
                LabeledContent("Locks at", value: occurrence.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Opens at", value: occurrence.end.formatted(date: .abbreviated, time: .shortened))
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
                if let end = coordinator.activeLockEnd {
                    Text("Your apps will open at \(end.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(.secondary)
                }
            }

            Section("This lock") {
                if let end = coordinator.activeLockEnd {
                    LabeledContent("Opens", value: end.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("The opening time isn’t available. Developer cleanup remains in Settings if needed.")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Started by", value: coordinator.activeLockOriginSummary)
            }

            if let pending = coordinator.pendingChangesSummary {
                Section("Changes after this lock") {
                    Label(pending, systemImage: "clock.arrow.circlepath")
                    Text("They’ll take effect after this lock ends.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Need to end early?") {
                Text("Recovery waits 15 minutes, then asks you to confirm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Start recovery") {
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

@MainActor
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

@MainActor
private enum SavedWindowFormatter {
    static func value(for coordinator: ScreenTimeCoordinator) -> String {
        let start = coordinator.savedStartComponents
        let end = coordinator.savedEndComponents
        return "\(String(format: "%02d:%02d", start.hour ?? 0, start.minute ?? 0)) – \(String(format: "%02d:%02d", end.hour ?? 0, end.minute ?? 0))"
    }
}
