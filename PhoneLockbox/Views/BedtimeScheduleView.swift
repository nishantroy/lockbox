import SwiftUI

/// Focused editor for the recurring bedtime: on/off, Starts, Ends and Save.
///
/// Save is the confirmation. Turning bedtime on (or changing times) goes
/// through `coordinator.saveSchedule`, the same validate / register / queue
/// core as `ConfigurationEditorView`, but it keeps the last saved mode and
/// selection instead of committing any restrictions draft. On/off maps to the
/// existing `recurringEnabledIntent`: on registers the schedule, off calls
/// `stopSchedule()`. No new runtime state.
struct BedtimeScheduleView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    /// Sheet presentations also get a Cancel button.
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var isOn: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var bedtimeOffUntilSaved = false

    /// - Parameter turnOn: opens with bedtime switched on (the "Set bedtime" entry).
    init(coordinator: ScreenTimeCoordinator, isSheet: Bool = false, turnOn: Bool = false) {
        self.coordinator = coordinator
        self.isSheet = isSheet
        _isOn = State(initialValue: coordinator.recurringEnabledIntent || (turnOn && !coordinator.hasActiveLock))
        _start = State(initialValue: LockboxClockTime.date(from: coordinator.effectiveStartComponents))
        _end = State(initialValue: LockboxClockTime.date(from: coordinator.effectiveEndComponents))
    }

    private var wasOn: Bool { coordinator.recurringEnabledIntent }
    private var locked: Bool { coordinator.hasActiveLock }
    private var startComponents: DateComponents { LockboxClockTime.components(from: start) }
    private var endComponents: DateComponents { LockboxClockTime.components(from: end) }
    private var startTime: RuntimeTime { LockboxClockTime.runtimeTime(from: startComponents) }
    private var endTime: RuntimeTime { LockboxClockTime.runtimeTime(from: endComponents) }

    private var validationMessage: String? {
        isOn ? RuntimeBedtimeSummary.validationMessage(start: startTime, end: endTime) : nil
    }

    private var hasChanges: Bool {
        RuntimeBedtimeEditBlock.hasChanges(
            isOn: isOn,
            wasOn: wasOn,
            start: startTime,
            end: endTime,
            savedStart: LockboxClockTime.runtimeTime(from: coordinator.effectiveStartComponents),
            savedEnd: LockboxClockTime.runtimeTime(from: coordinator.effectiveEndComponents)
        )
    }

    /// Whether the window that is currently applied is running right now.
    private var savedWindowInProgress: Bool {
        coordinator.lockingBedtimeEnd(
            start: LockboxClockTime.runtimeTime(from: coordinator.savedStartComponents),
            end: LockboxClockTime.runtimeTime(from: coordinator.savedEndComponents)
        ) != nil
    }

    private var editBlock: RuntimeBedtimeEditBlock? {
        RuntimeBedtimeEditBlock.evaluate(isOn: isOn, wasOn: wasOn, locked: locked, savedWindowInProgress: savedWindowInProgress)
    }

    private var needsSelection: Bool { isOn && !coordinator.effectiveSelectionIsValid }

    private var canSave: Bool {
        guard hasChanges, validationMessage == nil, editBlock == nil else { return false }
        guard isOn else { return !coordinator.testScheduleActive }
        return coordinator.canEditDraft && coordinator.effectiveSelectionIsValid
    }

    /// Saving inside tonight's window: registration makes the system start
    /// the already-open occurrence, so the phone locks straight away, unless
    /// that occurrence was released early or is fenced off.
    private var inProgressNote: String? {
        guard isOn, hasChanges, !locked, validationMessage == nil else { return nil }
        let now = Date()
        guard let windowEnd = coordinator.lockingBedtimeEnd(start: startTime, end: endTime, at: now) else { return nil }
        return "Bedtime is in progress, so saving locks now until \(RuntimeTimeFormat.string(windowEnd, now: now, style: .phrase))."
    }

    private var helpText: String {
        if locked { return "Bedtime can be turned on or off after this lock ends. Time changes apply then; if the new window has already started, it starts the next night." }
        if wasOn && !isOn { return "Future nights won’t lock until you turn it back on." }
        return "Repeats every night. Lock now and Start bedtime now don’t change it."
    }

    var body: some View {
        LockboxScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LockboxRowGroup {
                    Toggle("Bedtime", isOn: $isOn)
                        .tint(LockboxTheme.accent)
                        .frame(minHeight: 44)
                        .disabled(locked || coordinator.testScheduleActive)
                }
                LockboxHelpText(helpText)
                    .padding(.horizontal, 4)
            }

            if isOn {
                VStack(alignment: .leading, spacing: 8) {
                    LockboxSectionLabel("Schedule")
                        .padding(.horizontal, 4)
                    LockboxRowGroup {
                        DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                            .frame(minHeight: 44)
                        LockboxRowDivider()
                        DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                            .frame(minHeight: 44)
                    }
                    if let validationMessage {
                        LockboxAttentionNote(validationMessage)
                            .padding(.horizontal, 4)
                    } else {
                        Text(RuntimeBedtimeSummary.summary(start: startTime, end: endTime))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LockboxTheme.primary)
                            .padding(.horizontal, 4)
                    }
                    if let inProgressNote {
                        LockboxHelpText(inProgressNote)
                            .padding(.horizontal, 4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let pending = coordinator.pendingChangesSummary {
                    LockboxHelpText(pending)
                }
                if let editBlock {
                    LockboxAttentionNote(editBlock.message)
                }
                if !coordinator.isAuthorized {
                    LockboxAttentionNote("Screen Time access is needed to save a schedule.")
                } else if coordinator.testScheduleActive {
                    LockboxAttentionNote("Finish the prototype test in Settings first.")
                } else if needsSelection {
                    NavigationLink {
                        ConfigurationEditorView(coordinator: coordinator, isInitialSetup: false, sections: .restrictions)
                    } label: {
                        HStack(spacing: 8) {
                            LockboxAttentionNote("Choose what to block first.")
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if bedtimeOffUntilSaved && !coordinator.recurringEnabledIntent {
                    LockboxAttentionNote("Bedtime is off until this saves.")
                }
                if let error = coordinator.lastError {
                    LockboxAttentionNote(error)
                }
                Text("The system decides when, and whether, apps are blocked.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .lockboxScreen()
        .navigationTitle("Bedtime")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let wasEnabled = coordinator.recurringEnabledIntent
        let outcome: RuntimeSaveOutcome = isOn
            ? coordinator.saveSchedule(start: startComponents, end: endComponents)
            : coordinator.stopSchedule()
        if outcome.closesEditor {
            dismiss()
        } else {
            // A failed registration leaves the recurring intent off.
            bedtimeOffUntilSaved = isOn && wasEnabled && !coordinator.recurringEnabledIntent
        }
    }
}

/// `BedtimeScheduleView` in its own navigation stack, for sheets.
struct BedtimeScheduleSheet: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    var turnOn = false

    var body: some View {
        NavigationStack {
            BedtimeScheduleView(coordinator: coordinator, isSheet: true, turnOn: turnOn)
        }
        .lockboxScreen()
    }
}
