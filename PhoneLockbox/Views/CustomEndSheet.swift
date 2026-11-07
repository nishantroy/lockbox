import SwiftUI

/// Picks a custom end for the one-tap Lock now. "Set end" only records the
/// choice; it never starts a lock.
struct CustomEndSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: ScreenTimeCoordinator
    /// The clock at presentation, shifted one minute so every selectable end
    /// is still valid when the Open screen checks it (see `RuntimeLockNowEnd`).
    let pickerReference: Date
    let onSet: (Date) -> Void
    @State private var selection: RuntimeCustomEndSelectionState

    init(
        coordinator: ScreenTimeCoordinator,
        referenceDate: Date,
        currentEnd: Date?,
        onSet: @escaping (Date) -> Void
    ) {
        self.coordinator = coordinator
        let reference = RuntimeLockNowEnd.pickerReference(at: referenceDate)
        self.pickerReference = reference
        self.onSet = onSet
        // A previous end that is no longer in range is dropped: seed from the
        // default with no user selection, so the picker never opens on a stale end.
        let range = coordinator.manualLockCustomRange(at: reference)
        let keepsCurrent = currentEnd.map { end in range?.contains(end) ?? false } ?? false
        let initial = keepsCurrent
            ? RuntimeCustomEndSelectionState(customEnd: currentEnd, hasUserSelection: true)
            : RuntimeCustomEndSelectionState()
        _selection = State(initialValue: RuntimeCustomEndSelectionState.transition(
            initial, event: .enteredCustom, at: reference, calendar: Calendar.current
        ))
    }

    private var range: ClosedRange<Date>? {
        coordinator.manualLockCustomRange(at: pickerReference)
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: {
                selection.customEnd
                    ?? RuntimeManualLockDecision.defaultCustomEnd(at: pickerReference, calendar: Calendar.current)
                    ?? pickerReference.addingTimeInterval(30 * 60)
            },
            set: { newEnd in
                selection = RuntimeCustomEndSelectionState.transition(
                    selection, event: .userSelected(newEnd), at: pickerReference, calendar: Calendar.current
                )
            }
        )
    }

    private var validEnd: Date? {
        guard let end = selection.customEnd, let range, range.contains(end) else { return nil }
        return end
    }

    var body: some View {
        NavigationStack {
            LockboxScrollView {
                if let range {
                    DatePicker(
                        "End",
                        selection: endBinding,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } else {
                    unavailableLabel("No finite end is available at the moment.")
                }
                if validEnd == nil { reasonLabel }
                Text("This lock ends at the time you choose. Bedtime still starts on schedule.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.textSecondary)
            }
            .navigationTitle("Lock until")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set end") {
                        guard let validEnd else { return }
                        onSet(validEnd)
                        dismiss()
                    }
                    .disabled(validEnd == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .lockboxScreen()
    }

    /// Why "Set end" is unavailable, using the same wording as the
    /// confirmation sheet. Shown only while no valid end is selected.
    @ViewBuilder
    private var reasonLabel: some View {
        if range != nil {
            switch RuntimeCustomEndAvailability.evaluate(
                selection.customEnd, at: pickerReference, calendar: Calendar.current
            ) {
            case .available:
                unavailableLabel("Choose an end inside the range shown.")
            case .unavailable:
                unavailableLabel("Choose a finite custom end before confirming.")
            case .tooSoon:
                unavailableLabel("This end is too soon. Choose one at least 15 minutes from now.")
            case .tooLate:
                unavailableLabel("This end is too late. Choose one within seven days.")
            }
        }
    }

    private func unavailableLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(LockboxTheme.attention)
    }
}
