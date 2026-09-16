import SwiftUI

struct ManualLockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var choice: ManualLockChoice = .thirtyMinutes
    @State private var customEnd: Date
    @State private var attempted = false
    @State private var referenceDate: Date

    init(coordinator: ScreenTimeCoordinator) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        let capturedDate = Date()
        let calendar = Calendar.current
        _referenceDate = State(initialValue: capturedDate)
        _customEnd = State(initialValue: RuntimeManualLockDecision.defaultCustomEnd(at: capturedDate, calendar: calendar) ?? capturedDate.addingTimeInterval(30 * 60))
    }

    var body: some View {
        NavigationStack {
            LockboxScrollView {
                LockboxCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LockboxSectionLabel("Choose an end", systemImage: "clock")
                        Picker("Duration", selection: $choice) {
                            ForEach(ManualLockChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)

                        if choice == .custom {
                            if let customRange {
                                DatePicker(
                                    "End",
                                    selection: $customEnd,
                                    in: customRange,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                            } else {
                                Label("No finite end is available at the moment.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(LockboxTheme.destructive)
                            }
                        }
                        Text("The end is finite and is checked again when you confirm. A manual lock never silently uses the bedtime end.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                }

                LockboxCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LockboxSectionLabel("Review before locking", systemImage: "checkmark.shield")
                        if let proposedEnd {
                            LockboxValueRow(label: "Immutable proposed end", value: proposedEnd.formatted(date: .abbreviated, time: .shortened))
                        } else {
                            Label("This end is no longer available.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        LockboxValueRow(label: "Restriction", value: coordinator.savedModeTitle)
                        LockboxValueRow(label: "Selection", value: "\(coordinator.savedSelectedItemCount) selected")
                        Text("Unsaved settings edits are not included. The saved policy is frozen for this lock.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                }

                if attempted, let error = coordinator.lastError {
                    LockboxCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.destructive)
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
            .onChange(of: choice) { _, newChoice in
                guard newChoice == .custom else { return }
                // Rebase the minute picker when Custom is chosen. Its bounds
                // must not retain seconds from sheet creation or an earlier
                // choice; confirmation still validates the frozen Date again.
                referenceDate = Date()
                customEnd = RuntimeManualLockDecision.defaultCustomEnd(
                    at: referenceDate,
                    calendar: Calendar.current
                ) ?? referenceDate.addingTimeInterval(30 * 60)
            }
            .onChange(of: coordinator.hasActiveLock) { _, isActive in
                if attempted && isActive {
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .lockboxScreen()
    }

    private var customRange: ClosedRange<Date>? {
        coordinator.manualLockCustomRange(at: referenceDate)
    }

    private var proposedEnd: Date? {
        switch choice {
        case .thirtyMinutes:
            return coordinator.manualLockProposedEnd(after: 30 * 60, at: referenceDate)
        case .oneHour:
            return coordinator.manualLockProposedEnd(after: 60 * 60, at: referenceDate)
        case .custom:
            guard let customRange, customRange.contains(customEnd) else { return nil }
            return customEnd
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
