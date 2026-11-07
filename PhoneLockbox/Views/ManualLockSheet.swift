import SwiftUI

struct ManualLockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var choice: ManualLockChoice = .thirtyMinutes
    @State private var customSelection = RuntimeCustomEndSelectionState()
    @State private var attempted = false
    @State private var referenceDate: Date
    private let onPresented: (ScreenTimeCoordinator.PendingQuickAction?) -> Void

    init(
        coordinator: ScreenTimeCoordinator,
        requestedPreset: QuickActionRoute.FocusPreset? = nil,
        onPresented: @escaping (ScreenTimeCoordinator.PendingQuickAction?) -> Void = { _ in }
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _choice = State(initialValue: requestedPreset.map(Self.choice) ?? .thirtyMinutes)
        _referenceDate = State(initialValue: Date())
        self.onPresented = onPresented
    }

    private static func choice(for preset: QuickActionRoute.FocusPreset) -> ManualLockChoice {
        switch preset {
        case .thirtyMinutes: return .thirtyMinutes
        case .oneHour: return .oneHour
        }
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
                                    selection: customEndBinding,
                                    in: customRange,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                            } else {
                                Label("No finite end is available at the moment.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(LockboxTheme.attention)
                            }
                            customEndAvailabilityLabel
                        }
                        Text("This lock ends at the time you choose. Bedtime still starts on schedule.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                    }
                }

                LockboxCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LockboxSectionLabel("Review before locking", systemImage: "checkmark.shield")
                        if let proposedEnd {
                            LockboxValueRow(label: "Ends at", value: RuntimeTimeFormat.string(proposedEnd, now: referenceDate))
                        } else {
                            Label("This end is no longer available.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(LockboxTheme.attention)
                        }
                        LockboxValueRow(label: "Restriction", value: coordinator.savedModeTitle)
                        LockboxValueRow(label: "Selection", value: "\(coordinator.savedSelectedItemCount) selected")
                        Text("Uses your saved settings. Unsaved edits are not included.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                    }
                }

                if attempted, let error = coordinator.lastError {
                    LockboxCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.attention)
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
                referenceDate = newChoice == .custom ? Date() : referenceDate
                customSelection = RuntimeCustomEndSelectionState.transition(
                    customSelection,
                    event: newChoice == .custom ? .enteredCustom : .selectedPreset,
                    at: referenceDate,
                    calendar: Calendar.current
                )
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
        .onAppear {
            // A sheet onAppear is the explicit presentation callback. A crash
            // or failed presentation before this point leaves the durable
            // claim leased rather than acknowledged.
            onPresented(coordinator.pendingQuickAction)
        }
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
            guard let customEnd = customSelection.customEnd,
                  let customRange,
                  customRange.contains(customEnd) else { return nil }
            return customEnd
        }
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: {
                customSelection.customEnd
                    ?? RuntimeManualLockDecision.defaultCustomEnd(at: referenceDate, calendar: Calendar.current)
                    ?? referenceDate.addingTimeInterval(30 * 60)
            },
            set: { newEnd in
                customSelection = RuntimeCustomEndSelectionState.transition(
                    customSelection,
                    event: .userSelected(newEnd),
                    at: referenceDate,
                    calendar: Calendar.current
                )
            }
        )
    }

    @ViewBuilder
    private var customEndAvailabilityLabel: some View {
        switch RuntimeCustomEndAvailability.evaluate(
            customSelection.customEnd,
            at: referenceDate,
            calendar: Calendar.current
        ) {
        case .available:
            EmptyView()
        case .unavailable:
            Label("Choose a finite custom end before confirming.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(LockboxTheme.attention)
        case .tooSoon:
            Label("This end is too soon. Choose one at least 15 minutes from now.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(LockboxTheme.attention)
        case .tooLate:
            Label("This end is too late. Choose one within seven days.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(LockboxTheme.attention)
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
