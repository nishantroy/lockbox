import SwiftUI
import FamilyControls

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = ScreenTimeCoordinator()
    @State private var showingPicker = false
    @State private var showingEmergencyReset = false
    @State private var showingDeveloperUnlock = false
    @State private var showingManualLockConfirmation = false
    @State private var manualLockPreviewEnd: Date?
    @State private var manualLockNotice: String?
    @State private var draftSelection = FamilyActivitySelection(includeEntireCategory: true)

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isConfigured { dashboardView } else { setupView }
            }
            .navigationTitle("Phone Lockbox")
        }
        .task { coordinator.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The system picker can make the scene inactive. Refresh shared
                // status, but do not overwrite still-unsaved local time edits.
                coordinator.refreshAuthorization()
            }
        }
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                FamilyActivityPicker(selection: $draftSelection)
                    .navigationTitle("Choose apps")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingPicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                coordinator.commitSelection(draftSelection)
                                showingPicker = false
                            }
                        }
                    }
            }
        }
        .alert("Start a manual lock?", isPresented: $showingManualLockConfirmation) {
            Button("Start lock", role: .destructive) {
                guard let expectedEnd = manualLockPreviewEnd,
                      coordinator.manualLockProposedEnd == expectedEnd else {
                    manualLockNotice = "The proposed end changed. Review Lock now and confirm again."
                    return
                }
                coordinator.startManualLock(expectedEnd: expectedEnd)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(manualLockConfirmationMessage)
        }
        .alert("Developer unlock", isPresented: $showingDeveloperUnlock) {
            Button("Unlock now", role: .destructive) {
                coordinator.developerUnlockNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is a developer-only destructive escape hatch. It releases current Phone Lockbox sessions immediately and does not prove that other owners or system restrictions are cleared.")
        }
        .alert("Emergency reset", isPresented: $showingEmergencyReset) {
            Button("Reset", role: .destructive) { coordinator.emergencyReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops Phone Lockbox monitoring and clears this app's named Managed Settings and shared state. Use only when ordinary cleanup is unavailable. It cannot clear settings owned by another app.")
        }
    }

    private var setupView: some View {
        Form {
            Section {
                Label("A calmer phone at night", systemImage: "moon.stars")
                    .font(.headline)
                Text("Keep essentials available while making app-hopping inconvenient during bedtime.")
                    .foregroundStyle(.secondary)
                Text("This prototype requires Screen Time authorization and a real-device test before relying on it overnight.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("1. Screen Time access") {
                LabeledContent("Status", value: authorizationLabel)
                // Keep this hidden once access has been granted; authorization
                // restoration is reported by the status and diagnostics below.
                if !coordinator.isAuthorized {
                    Button("Request access") { Task { await coordinator.requestAuthorization() } }
                }
            }
            if coordinator.isAuthorized {
                configurationSections
                Section {
                    Button("Save and register bedtime schedule") { save() }
                        .disabled(!coordinator.canApplySelection)
                    Text("A successful request is not proof that every app is blocked or that a future callback will arrive on time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Label("Authorize Screen Time to continue", systemImage: "lock.shield")
                    Text("Bedtime settings and app selection become available after access is granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            recoveryExplanationSection
            developerSection
            diagnosticsSection
        }
    }

    private var recoveryExplanationSection: some View {
        Section("Recovery") {
            Label("Recovery has a fixed 15-minute wait and requires explicit confirmation.", systemImage: "hourglass")
            Text("You can leave the app while waiting. Waiting alone never unlocks the phone, and recovery does not disable future bedtime sessions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var developerSection: some View {
        Section("Developer tools — safety escape hatch") {
            NavigationLink("Wind-down & Live Activity prototypes") {
                AmbientPrototypeView()
            }
            Text("Optional standalone demos—not connected to your lock schedule. They never apply or release restrictions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if coordinator.testScheduleActive {
                Label("A migrated or active prototype restriction may still be shielding apps.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if coordinator.legacyRegistrationNeedsReview {
                Label("Legacy monitoring ownership is unknown; do not assume the device is unlocked.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
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
            Text("Developer unlock releases current Phone Lockbox sessions. Emergency reset is the corruption cleanup route: it stops monitoring and clears this app's named state. Neither route clears restrictions owned by another app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var configurationSections: some View {
        Section("Restriction") {
            Picker("Mode", selection: Binding(get: { coordinator.mode }, set: { coordinator.setDraftMode($0) })) {
                ForEach(ScreenTimeCoordinator.RestrictionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(!coordinator.canEditDraft)
            Text(coordinator.mode == .blockSelected
                 ? "Selected apps, categories, and websites will be blocked."
                 : "Everything except selected apps, including apps from selected categories, will be blocked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section("2. Bedtime window") {
            DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                .disabled(!coordinator.canEditDraft)
            DatePicker("Ends", selection: endBinding, displayedComponents: .hourAndMinute)
                .disabled(!coordinator.canEditDraft)
            Text("The window repeats every day and can cross midnight. Saved windows must be at least 15 minutes; DST remains OS-authoritative.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section("3. Apps and websites") {
            pickerButton
            Text(coordinator.mode == .blockSelected
                 ? "Choose individual apps, categories, or websites to block."
                 : "Choose apps, categories, or websites to allow. Categories are expanded to their apps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if coordinator.mode == .allowOnlySelected && coordinator.selectedItemCount > 0 && !coordinator.canApplySelection {
                Label("Allow-only mode needs at least one app token.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        Section("Prototype test") {
            Button {
                coordinator.startImmediateTestLock()
            } label: {
                Label(coordinator.testScheduleActive ? "Test lock is active" : "Start test lock now", systemImage: coordinator.testScheduleActive ? "checkmark.circle.fill" : "bolt.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.canApplySelection || coordinator.testScheduleActive || coordinator.hasOSRegistration || coordinator.recurringEnabledIntent || !coordinator.isAuthorized)
            Text(coordinator.testScheduleActive
                 ? "Developer test restriction; use Developer unlock now to clear it explicitly."
                 : "The prototype test is mutually exclusive with recurring monitoring and is cleared through the marked developer escape hatch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dashboardView: some View {
        Form {
            Section {
                let healthy = coordinator.isAuthorized && coordinator.scheduleIsRegistered && coordinator.recurringEnabledIntent
                Label(coordinator.registrationLabel, systemImage: healthy ? "checkmark.circle" : "info.circle")
                    .font(.headline)
                    .foregroundStyle(healthy ? .green : .primary)
                Text(coordinator.hasUnsavedDraft
                     ? "Draft edits do not change the saved policy. Registration status is shown above."
                     : (coordinator.mode == .blockSelected
                        ? "The saved policy requests selected apps, categories, and websites for restriction during its window."
                        : "The saved policy requests everything except selected apps during its window."))
                    .foregroundStyle(.secondary)
                if coordinator.hasUnsavedDraft {
                    Label("Draft changes are not registered yet.", systemImage: "pencil")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !coordinator.isAuthorized {
                    Label("Screen Time access is unavailable; enforcement is not confirmed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if coordinator.legacyRegistrationNeedsReview {
                    Label("A pre-runtime registration may still exist. Ownership is unknown; do not assume the phone is unlocked.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if coordinator.hasActiveLock {
                activeLockSection
                if let pending = coordinator.pendingChangesSummary {
                    Section("Changes for after this lock") {
                        Label(pending, systemImage: "clock.arrow.circlepath")
                        Text("These changes are queued and do not weaken the current committed lock.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Recovery") {
                    NavigationLink("Recovery options") {
                        RecoveryView(coordinator: coordinator)
                    }
                }
            } else {
                manualLockSection
                if let pending = coordinator.pendingChangesSummary {
                    Section("Pending changes") {
                        Text(pending)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Saved / registered policy") {
                LabeledContent("Mode", value: coordinator.savedModeTitle)
                LabeledContent("Bedtime", value: savedWindow)
                LabeledContent("Selection", value: "\(coordinator.savedSelectedItemCount) selected")
                LabeledContent("Authorization", value: authorizationLabel)
            }
            configurationSections
            Section {
                Button("Save and register schedule") { save() }
                    .disabled(!coordinator.canApplySelection || !coordinator.isAuthorized)
            }
            developerSection
            diagnosticsSection
        }
    }

    private var activeLockSection: some View {
        Section("Active lock") {
            Label("Current restrictions are committed", systemImage: "lock.fill")
                .font(.headline)
            if let end = coordinator.activeLockEnd {
                LabeledContent("Scheduled to open", value: end.formatted(date: .abbreviated, time: .shortened))
                Text("This end is fixed for the active session and is not changed by routine settings edits.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("The active lock has no trustworthy end time. Use the marked developer recovery route if cleanup is needed.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Active sessions", value: "\(coordinator.activeSessionCount)")
        }
    }

    private var manualLockSection: some View {
        Section("Lock now") {
            if let proposedEnd = coordinator.manualLockProposedEnd {
                LabeledContent("Proposed end", value: proposedEnd.formatted(date: .abbreviated, time: .shortened))
                Button("Lock now") {
                    guard let end = coordinator.manualLockProposedEnd else { return }
                    manualLockPreviewEnd = end
                    manualLockNotice = nil
                    showingManualLockConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.isAuthorized)
                Text("This is a bounded manual lock. If the preview becomes unavailable or a lock starts first, the coordinator rejects the request rather than weakening an existing session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Lock now requires a saved policy and a supported future end at least 15 minutes away.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { date(from: coordinator.startComponents) }, set: { coordinator.setDraftStart($0) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { date(from: coordinator.endComponents) }, set: { coordinator.setDraftEnd($0) })
    }

    private var savedWindow: String {
        "\(coordinator.savedStartComponents.hour ?? 0):\(String(format: "%02d", coordinator.savedStartComponents.minute ?? 0)) – \(coordinator.savedEndComponents.hour ?? 0):\(String(format: "%02d", coordinator.savedEndComponents.minute ?? 0))"
    }

    private var pickerButton: some View {
        Button {
            draftSelection = coordinator.selection
            showingPicker = true
        } label: {
            HStack {
                Text("Choose apps or categories")
                Spacer()
                Text("\(coordinator.selectedItemCount) selected")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(!coordinator.canEditDraft)
    }

    private var diagnosticsSection: some View {
        Section("Operational status") {
            if let notice = manualLockNotice {
                Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error = coordinator.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            LabeledContent("Registration", value: coordinator.registrationLabel)
            if let operation = coordinator.lastOperation.operation {
                LabeledContent("Last operation", value: diagnosticLabel(operation))
                if let observedAt = coordinator.lastOperation.observedAt {
                    LabeledContent("Observed", value: observedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let detail = coordinator.lastOperation.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(coordinator.lastOperation.succeeded == false ? .red : .secondary)
                }
            }
            DisclosureGroup("Recent callback and operation log") {
                ForEach(Array(coordinator.recentDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnosticLine(diagnostic))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var authorizationLabel: String {
        if coordinator.isAuthorized { return "Authorized" }
        switch coordinator.authorizationStatus {
        case .approved: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        default: return "Unknown"
        }
    }

    private var manualLockConfirmationMessage: String {
        guard let end = manualLockPreviewEnd else {
            return "A finite manual lock end is no longer available. No lock will be started."
        }
        return "Lock until \(end.formatted(date: .abbreviated, time: .shortened)) using the saved policy: \(coordinator.savedModeTitle), \(coordinator.savedSelectedItemCount) selected. Unsaved draft edits are not included. The end and policy are checked again before starting."
    }

    private func save() {
        coordinator.saveConfiguration(start: coordinator.startComponents, end: coordinator.endComponents)
    }

    private func diagnosticLine(_ diagnostic: RuntimeDiagnostic) -> String {
        let timestamp = diagnostic.observedAt.formatted(date: .abbreviated, time: .standard)
        return "\(timestamp): \(diagnosticLabel(diagnostic.operation))\n\(diagnostic.detail ?? "")"
    }

    private func diagnosticLabel(_ operation: RuntimeOperation) -> String {
        switch operation {
        case .configurationSaved: return "Configuration saved"
        case .registrationAttempted: return "Schedule registration requested"
        case .registrationSucceeded: return "Schedule registration accepted"
        case .registrationFailed: return "Schedule registration failed"
        case .callbackReceived: return "System callback received"
        case .policyApplyAttempted: return "Restriction update requested"
        case .policyApplied: return "Restriction update completed"
        case .policyApplyFailed: return "Restriction update failed"
        case .policyClearAttempted: return "Restriction cleanup requested"
        case .policyCleared: return "Restriction cleanup completed"
        case .policyClearFailed: return "Restriction cleanup failed"
        case .conflictRejected: return "Conflicting operation rejected"
        case .legacyMigration: return "Previous settings migrated"
        case .emergencyReset: return "Emergency reset completed"
        @unknown default: return "Other operation"
        }
    }

    private func date(from components: DateComponents) -> Date {
        Calendar.current.date(from: DateComponents(hour: components.hour ?? 0, minute: components.minute ?? 0)) ?? .now
    }
}

#Preview { ContentView() }
