import SwiftUI

/// Focused editor for the recurring bedtime: on/off, Starts, Ends and Save.
///
/// Save is the confirmation. It goes through the same coordinator path as
/// `ConfigurationEditorView` (`saveConfiguration`, which validates, registers
/// with the OS, and queues the change while a lock is committed). On/off maps
/// to the existing `recurringEnabledIntent`: on registers the schedule, off
/// calls `stopSchedule()`. No new runtime state.
struct BedtimeScheduleView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    /// Sheet presentations also get a Cancel button.
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var isOn: Bool
    @State private var start: Date
    @State private var end: Date

    /// - Parameter turnOn: opens with bedtime switched on (the "Set bedtime" entry).
    init(coordinator: ScreenTimeCoordinator, isSheet: Bool = false, turnOn: Bool = false) {
        self.coordinator = coordinator
        self.isSheet = isSheet
        _isOn = State(initialValue: coordinator.recurringEnabledIntent || (turnOn && !coordinator.hasActiveLock))
        _start = State(initialValue: LockboxClockTime.date(from: coordinator.savedStartComponents))
        _end = State(initialValue: LockboxClockTime.date(from: coordinator.savedEndComponents))
    }

    private var startComponents: DateComponents { LockboxClockTime.components(from: start) }
    private var endComponents: DateComponents { LockboxClockTime.components(from: end) }
    private var startTime: RuntimeTime { LockboxClockTime.runtimeTime(from: startComponents) }
    private var endTime: RuntimeTime { LockboxClockTime.runtimeTime(from: endComponents) }

    private var validationMessage: String? {
        isOn ? RuntimeBedtimeSummary.validationMessage(start: startTime, end: endTime) : nil
    }

    private var timesChanged: Bool {
        startComponents != coordinator.savedStartComponents || endComponents != coordinator.savedEndComponents
    }

    private var hasChanges: Bool {
        isOn != coordinator.recurringEnabledIntent || (isOn && timesChanged)
    }

    private var needsSelection: Bool { isOn && !coordinator.canApplySelection }

    private var canSave: Bool {
        guard hasChanges, validationMessage == nil else { return false }
        guard isOn else { return !coordinator.testScheduleActive }
        return coordinator.canEditDraft && coordinator.canApplySelection
    }

    var body: some View {
        LockboxScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LockboxRowGroup {
                    Toggle("Bedtime", isOn: $isOn)
                        .tint(LockboxTheme.accent)
                        .frame(minHeight: 44)
                        .disabled(coordinator.hasActiveLock || coordinator.testScheduleActive)
                }
                LockboxHelpText("Repeats every night. Lock now and Start bedtime now don’t change it.")
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
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if coordinator.hasActiveLock {
                    LockboxHelpText("Changes apply after this lock ends.")
                }
                if !coordinator.isAuthorized {
                    LockboxAttentionNote("Screen Time access is needed to save a schedule.")
                } else if coordinator.testScheduleActive {
                    LockboxAttentionNote("Finish the prototype test in Settings first.")
                } else if needsSelection {
                    LockboxAttentionNote("Choose what to block first, under What gets blocked.")
                }
                if let error = coordinator.lastError {
                    LockboxAttentionNote(error)
                }
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
        let lockedAtSave = coordinator.hasActiveLock
        let requestedStart = startComponents
        let requestedEnd = endComponents
        if isOn {
            coordinator.saveConfiguration(start: requestedStart, end: requestedEnd)
        } else {
            coordinator.stopSchedule()
        }
        // Dismiss only when the state we asked for is actually in place; an
        // error stays visible inline instead.
        let succeeded: Bool
        if !isOn {
            succeeded = !coordinator.recurringEnabledIntent
        } else if lockedAtSave {
            succeeded = coordinator.hasPendingConfiguration
        } else {
            succeeded = coordinator.recurringEnabledIntent
                && coordinator.savedStartComponents == requestedStart
                && coordinator.savedEndComponents == requestedEnd
        }
        if succeeded { dismiss() }
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
