import SwiftUI

struct RecoveryView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var showingConfirmation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Form {
                if let error = coordinator.lastError {
                    Section("Needs attention") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if !coordinator.isAuthorized {
                    Section {
                        Label("Screen Time access is unavailable. Protection is not confirmed.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if coordinator.hasActiveLock {
                    Section("Current lock") {
                        Text("Recovery ends the current lock only. It does not disable future bedtime sessions.")
                            .foregroundStyle(.secondary)
                        if let end = coordinator.activeLockEnd {
                            LabeledContent("Fixed end", value: end.formatted(date: .abbreviated, time: .shortened))
                        }
                    }

                    if coordinator.hasRecoveryRequest {
                        recoveryRequestSection(at: context.date)
                    } else {
                        Section("Recovery") {
                            Text("Requesting recovery starts a fixed 15-minute wait. You can leave the app; restrictions remain until you confirm release or the lock ends naturally.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Request recovery") {
                                coordinator.requestRecovery()
                            }
                            .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                            .disabled(!coordinator.isAuthorized)
                        }
                    }
                } else {
                    Section {
                        Label("No active session", systemImage: "info.circle")
                        Text("Recovery does not extend the normal end. If apps remain restricted, check operational status. Future scheduled sessions are unchanged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recovery")
        .alert("End this lock?", isPresented: $showingConfirmation) {
            Button("End this lock", role: .destructive) {
                coordinator.confirmRecovery()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This releases the targeted active sessions after a final eligibility check. Future bedtime sessions remain enabled.")
        }
    }

    private func recoveryRequestSection(at date: Date) -> some View {
        Section("Recovery requested") {
            Text("Restrictions remain until you confirm release or the lock ends naturally.")
                .foregroundStyle(.secondary)
            if let eligibleAt = coordinator.recoveryEligibleAt {
                LabeledContent("Earliest confirmation", value: eligibleAt.formatted(date: .abbreviated, time: .shortened))
                if coordinator.isAuthorized && coordinator.canConfirmRecovery(at: date) {
                    Button("End this lock") {
                        guard coordinator.canConfirmRecovery(at: .now) else { return }
                        showingConfirmation = true
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                } else if date < eligibleAt {
                    Text("The 15-minute wait is still in progress. Waiting alone never unlocks the phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This request cannot release the current lock. Review its status, or cancel and request recovery again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Recovery is being reconciled. Restrictions may remain while the request is checked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel recovery request", role: .destructive) {
                coordinator.cancelRecovery()
            }
            .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
        }
    }
}

#Preview {
    NavigationStack {
        RecoveryView(coordinator: ScreenTimeCoordinator())
    }
}
