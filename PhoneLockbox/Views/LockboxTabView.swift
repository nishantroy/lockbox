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
        .lockboxScreen()
        .sheet(isPresented: $showingManualLock) {
            ManualLockSheet(coordinator: coordinator)
        }
    }
}

private struct SetupView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "A calmer phone, when you need it")

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        LockboxIconBadge(systemImage: "moon.stars.fill", color: LockboxTheme.rest)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("A calmer phone at night")
                                .font(.title3.weight(.semibold))
                            Text("Keep essentials available while making app-hopping inconvenient during bedtime.")
                                .font(.subheadline)
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                    }
                    Text("You can use People and Settings without granting Screen Time access. Access is needed only to save and enforce your own rules.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        LockboxSectionLabel("Screen Time access", systemImage: "hourglass")
                        Spacer()
                        LockboxStatusBadge(
                            title: AuthorizationStatusLabel.value(for: coordinator),
                            color: coordinator.isAuthorized ? LockboxTheme.focus : LockboxTheme.secondary
                        )
                    }
                    if coordinator.isAuthorized {
                        NavigationLink {
                            ConfigurationEditorView(coordinator: coordinator, isInitialSetup: true)
                        } label: {
                            Label("Set up bedtime rules", systemImage: "slider.horizontal.3")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens bedtime rules setup")
                    } else {
                        Button("Request access") {
                            Task { await coordinator.requestAuthorization() }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .accessibilityHint("Opens Apple's Screen Time authorization prompt")
                        Text("Bedtime settings and app selection become available after access is granted.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                }
            }

            if let error = coordinator.lastError {
                LockboxCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LockboxTheme.destructive)
                        .font(.subheadline)
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
        LockboxScrollView {
            LockboxPageHeader(title: "A calmer phone, when you need it")

            VStack(alignment: .leading, spacing: 10) {
                LockboxSectionLabel("Focus when you need it", systemImage: "sparkles")
                    .padding(.horizontal, 4)
                Button {
                    showingManualLock = true
                } label: {
                    Label("Lock now", systemImage: "lock.fill")
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                .disabled(!coordinator.isAuthorized)
                .accessibilityHint("Choose a finite focus lock duration")
                Text("Block distractions for 30 minutes, 1 hour, or until a time you choose.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                    .padding(.horizontal, 4)
            }

            TonightCard(coordinator: coordinator)

            LockboxCard {
                VStack(alignment: .leading, spacing: 15) {
                    LockboxSectionLabel("Your rhythm", systemImage: "waveform.path.ecg")
                    LockboxValueRow(label: "Mode", value: coordinator.savedModeTitle)
                    LockboxValueRow(label: "Apps & categories", value: "\(coordinator.savedSelectedItemCount) selected")
                    Divider().overlay(LockboxTheme.border).padding(.vertical, 2)
                    NavigationLink {
                        SettingsView(coordinator: coordinator)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: coordinator.windDownEnabled ? "bell.badge" : "bell.slash")
                                .foregroundStyle(coordinator.ambientError == nil ? LockboxTheme.accent : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Wind-down")
                                    .font(.subheadline.weight(.semibold))
                                Text(windDownStatusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(coordinator.ambientError == nil ? LockboxTheme.secondary : .orange)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            OperationalWarning(coordinator: coordinator)
        }
    }
}

private struct TonightCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var proposedBedtimeEnd: Date?
    @State private var showingBedtimeConfirmation = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    LockboxSectionLabel("Tonight", systemImage: "moon.stars.fill")
                    Spacer()
                    if coordinator.recurringEnabledIntent, nextOccurrence != nil {
                        LockboxStatusBadge(title: "Ready", color: LockboxTheme.rest)
                    }
                }
                if coordinator.recurringEnabledIntent, let occurrence = nextOccurrence {
                    Text("Bedtime lock is set")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 0) {
                        scheduleTime(title: "Locks at", value: occurrence.start.formatted(date: .abbreviated, time: .shortened))
                        Divider().frame(height: 38).overlay(LockboxTheme.border)
                        scheduleTime(title: "Opens at", value: occurrence.end.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        // Freeze the absolute boundary at preview time. The
                        // confirmation submits this same Date unchanged;
                        // runtime rejects it if the saved occurrence is stale.
                        let previewedAt = Date()
                        guard let end = coordinator.bedtimeNowProposedEnd(at: previewedAt) else { return }
                        proposedBedtimeEnd = end
                        showingBedtimeConfirmation = true
                    } label: {
                        Label("Start bedtime now", systemImage: "moon.fill")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                    .disabled(!coordinator.canStartBedtimeNow)
                    .accessibilityLabel("Start bedtime now")
                    .accessibilityHint("Uses your saved bedtime rules and opens at the configured morning time")
                } else {
                    Label("Automatic bedtime schedule is off", systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    Text("Save and register a schedule in Settings to turn on automatic sessions.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }
        }
        .alert("Start bedtime now?", isPresented: $showingBedtimeConfirmation) {
            Button("Start bedtime now") {
                guard let proposedBedtimeEnd else { return }
                coordinator.startBedtimeNow(expectedEnd: proposedBedtimeEnd)
                self.proposedBedtimeEnd = nil
            }
            Button("Cancel", role: .cancel) {
                proposedBedtimeEnd = nil
            }
        } message: {
            if let proposedBedtimeEnd {
                Text("Saved bedtime rules will be used. Your apps will open at \(proposedBedtimeEnd.formatted(date: .complete, time: .complete)). Future nights remain scheduled.")
            } else {
                Text("Saved bedtime rules will be used, and future nights remain scheduled.")
            }
        }
    }

    private func scheduleTime(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(LockboxTheme.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LockboxTheme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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

    private var semanticColor: Color {
        coordinator.activeLockTitle == "Get some rest" ? LockboxTheme.rest : LockboxTheme.focus
    }

    private var activePageHeading: String {
        coordinator.activeLockTitle == "Get some rest" ? "Protect your evening" : "Keep a clear lane"
    }

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: activePageHeading)

            LockboxCard {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 13) {
                        LockboxIconBadge(
                            systemImage: coordinator.activeLockTitle == "Get some rest" ? "moon.stars.fill" : "sparkles",
                            color: semanticColor
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.activeLockTitle)
                                .font(.title2.weight(.semibold))
                            if let end = coordinator.activeLockEnd {
                                Text("Your apps will open at \(end.formatted(date: .omitted, time: .shortened)).")
                                    .font(.subheadline)
                                    .foregroundStyle(LockboxTheme.secondary)
                            } else {
                                Text("The opening time isn’t available.")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Divider().overlay(LockboxTheme.border)
                    HStack {
                        if let end = coordinator.activeLockEnd {
                            VStack(alignment: .leading, spacing: 4) {
                                LockboxSectionLabel("Opens")
                                Text(end.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                            }
                        } else {
                            Text("Opening time unavailable")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(semanticColor)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(activeSummary)

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("This lock", systemImage: "checkmark.shield.fill")
                    if let end = coordinator.activeLockEnd {
                        LockboxValueRow(label: "Opens", value: end.formatted(date: .abbreviated, time: .shortened))
                    }
                    LockboxValueRow(label: "Started by", value: coordinator.activeLockOriginSummary)
                }
            }

            if let pending = coordinator.pendingChangesSummary {
                LockboxCard {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(LockboxTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Changes after this lock")
                                .font(.subheadline.weight(.semibold))
                            Text(pending)
                                .font(.footnote)
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Need to end early?", systemImage: "arrow.uturn.backward.circle")
                    Text("Recovery waits 15 minutes, then asks you to confirm. Waiting alone never unlocks your phone.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    NavigationLink {
                        RecoveryView(coordinator: coordinator)
                    } label: {
                        HStack {
                            Text("Start recovery")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            OperationalWarning(coordinator: coordinator)
        }
    }

    private var activeSummary: String {
        let end = coordinator.activeLockEnd?.formatted(date: .abbreviated, time: .shortened) ?? "an unavailable time"
        return "\(coordinator.activeLockTitle). Your protected time is underway. Opens \(end)."
    }
}

struct OperationalWarning: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    @ViewBuilder
    var body: some View {
        if let error = coordinator.lastError {
            LockboxCard {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
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
