import SwiftUI

struct ManualLockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var choice: ManualLockChoice = .thirtyMinutes
    @State private var customEnd = Date(timeIntervalSinceNow: 30 * 60)
    @State private var attempted = false
    private let referenceDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Duration", selection: $choice) {
                        ForEach(ManualLockChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)

                    if choice == .custom {
                        DatePicker(
                            "End",
                            selection: $customEnd,
                            in: referenceDate.addingTimeInterval(15 * 60)...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                } header: {
                    Text("Choose an end")
                } footer: {
                    Text("The end is finite and is checked again when you confirm. A manual lock never silently uses the bedtime end.")
                }

                Section("Review before locking") {
                    if let proposedEnd {
                        LabeledContent("Immutable proposed end", value: proposedEnd.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Label("This end is no longer available.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Restriction", value: coordinator.savedModeTitle)
                    LabeledContent("Selection", value: "\(coordinator.savedSelectedItemCount) selected")
                    Text("Unsaved settings edits are not included. The saved policy is frozen for this lock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if attempted, let error = coordinator.lastError {
                    Section("Could not start lock") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Lock now")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm lock", role: .destructive) {
                        attempted = true
                        guard let proposedEnd else { return }
                        coordinator.startManualLock(expectedEnd: proposedEnd)
                    }
                    .disabled(proposedEnd == nil || !coordinator.isAuthorized)
                }
            }
            .onChange(of: coordinator.hasActiveLock) { _, isActive in
                if attempted && isActive {
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var proposedEnd: Date? {
        switch choice {
        case .thirtyMinutes:
            return coordinator.manualLockProposedEnd(after: 30 * 60, at: referenceDate)
        case .oneHour:
            return coordinator.manualLockProposedEnd(after: 60 * 60, at: referenceDate)
        case .custom:
            let duration = customEnd.timeIntervalSince(referenceDate)
            guard duration.isFinite, duration >= 15 * 60 else { return nil }
            return coordinator.manualLockProposedEnd(after: duration, at: referenceDate)
        }
    }
}

private enum ManualLockChoice: String, CaseIterable, Identifiable {
    case thirtyMinutes
    case oneHour
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .custom: return "Custom end"
        }
    }
}
