import SwiftUI

struct RecoveryView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var showingConfirmation = false
    private let onPresented: (ScreenTimeCoordinator.PendingQuickAction?) -> Void

    init(
        coordinator: ScreenTimeCoordinator,
        onPresented: @escaping (ScreenTimeCoordinator.PendingQuickAction?) -> Void = { _ in }
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.onPresented = onPresented
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            LockboxScrollView {
                LockboxPageHeader(title: "Recovery")

                if let error = coordinator.lastError {
                    LockboxCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.destructive)
                    }
                }

                if !coordinator.isAuthorized {
                    LockboxCard {
                        Label("Screen Time access is unavailable. Protection is not confirmed.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.destructive)
                    }
                }

                if coordinator.hasActiveLock {
                    LockboxCard {
                        VStack(alignment: .leading, spacing: 14) {
                            LockboxSectionLabel("Current lock", systemImage: "lock.fill")
                            Text("Recovery ends the current lock only. It does not disable future bedtime sessions.")
                                .font(.subheadline)
                                .foregroundStyle(LockboxTheme.secondary)
                            if let end = coordinator.activeLockEnd {
                                LockboxValueRow(label: "Fixed end", value: end.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }

                    if coordinator.hasRecoveryRequest {
                        recoveryRequestCard(at: context.date)
                    } else {
                        LockboxCard {
                            VStack(alignment: .leading, spacing: 13) {
                                LockboxSectionLabel("Recovery", systemImage: "arrow.uturn.backward.circle")
                                Text("Requesting recovery starts a fixed 15-minute wait. You can leave the app; restrictions remain until you confirm release or the lock ends naturally.")
                                    .font(.footnote)
                                    .foregroundStyle(LockboxTheme.secondary)
                                Button("Request recovery") {
                                    coordinator.requestRecovery()
                                }
                                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                                .disabled(!coordinator.isAuthorized)
                            }
                        }
                    }
                } else {
                    LockboxCard {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("No active session", systemImage: "info.circle")
                                .font(.headline)
                            Text("Recovery does not extend the normal end. If apps remain restricted, check operational status. Future scheduled sessions are unchanged.")
                                .font(.footnote)
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                    }
                }
            }
        }
        .lockboxScreen()
        .onAppear {
            // Recovery is acknowledged only once this destination is actually
            // presented, not when NavigationStack state is merely appended.
            onPresented(coordinator.pendingQuickAction)
        }
        .alert("End this lock?", isPresented: $showingConfirmation) {
            Button("End this lock", role: .destructive) {
                coordinator.confirmRecovery()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This releases the targeted active sessions after a final eligibility check. Future bedtime sessions remain enabled.")
        }
    }

    private func recoveryRequestCard(at date: Date) -> some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Recovery requested", systemImage: "hourglass")
                Text("Restrictions remain until you confirm release or the lock ends naturally.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.secondary)
                if let eligibleAt = coordinator.recoveryEligibleAt {
                    LockboxValueRow(label: "Earliest confirmation", value: eligibleAt.formatted(date: .abbreviated, time: .shortened))
                    if coordinator.isAuthorized && coordinator.canConfirmRecovery(at: date) {
                        Button("End this lock") {
                            guard coordinator.canConfirmRecovery(at: .now) else { return }
                            showingConfirmation = true
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    } else if date < eligibleAt {
                        Text("The 15-minute wait is still in progress. Waiting alone never unlocks the phone.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    } else {
                        Text("This request cannot release the current lock. Review its status, or cancel and request recovery again.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                } else {
                    Text("Recovery is being reconciled. Restrictions may remain while the request is checked.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
                Button("Cancel recovery request", role: .destructive) {
                    coordinator.cancelRecovery()
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecoveryView(coordinator: ScreenTimeCoordinator())
    }
}
