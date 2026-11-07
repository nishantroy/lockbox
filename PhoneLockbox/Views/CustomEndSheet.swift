import SwiftUI

/// Picks a custom end for the one-tap Lock now. "Set end" only records the
/// choice; it never starts a lock.
struct CustomEndSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: ScreenTimeCoordinator
    /// Fixed at presentation so the picker range does not shift while open.
    let referenceDate: Date
    let onSet: (Date) -> Void
    @State private var selection: RuntimeCustomEndSelectionState

    init(
        coordinator: ScreenTimeCoordinator,
        referenceDate: Date,
        currentEnd: Date?,
        onSet: @escaping (Date) -> Void
    ) {
        self.coordinator = coordinator
        self.referenceDate = referenceDate
        self.onSet = onSet
        let initial = RuntimeCustomEndSelectionState(customEnd: currentEnd, hasUserSelection: currentEnd != nil)
        _selection = State(initialValue: RuntimeCustomEndSelectionState.transition(
            initial, event: .enteredCustom, at: referenceDate, calendar: Calendar.current
        ))
    }

    private var range: ClosedRange<Date>? {
        coordinator.manualLockCustomRange(at: referenceDate)
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: {
                selection.customEnd
                    ?? RuntimeManualLockDecision.defaultCustomEnd(at: referenceDate, calendar: Calendar.current)
                    ?? referenceDate.addingTimeInterval(30 * 60)
            },
            set: { newEnd in
                selection = RuntimeCustomEndSelectionState.transition(
                    selection, event: .userSelected(newEnd), at: referenceDate, calendar: Calendar.current
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
                    Label("No finite end is available at the moment.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LockboxTheme.attention)
                }
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
}
