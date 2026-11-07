import SwiftUI

struct RecoveryView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var showingConfirmation = false
    @State private var presentedQuickAction: ScreenTimeCoordinator.PendingQuickAction?
    private let onPresented: (ScreenTimeCoordinator.PendingQuickAction?) -> Void
    private let onDismissed: (ScreenTimeCoordinator.PendingQuickAction?) -> Void

    init(
        coordinator: ScreenTimeCoordinator,
        onPresented: @escaping (ScreenTimeCoordinator.PendingQuickAction?) -> Void = { _ in },
        onDismissed: @escaping (ScreenTimeCoordinator.PendingQuickAction?) -> Void = { _ in }
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.onPresented = onPresented
        self.onDismissed = onDismissed
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
                        Label("Screen Time access is off. Lock protection isn’t confirmed.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.destructive)
                    }
                }

                if coordinator.hasActiveLock {
                    LockboxCard {
                        VStack(alignment: .leading, spacing: 14) {
                            LockboxSectionLabel("Current lock", systemImage: "lock.fill")
                            Text("Recovery ends this lock only. Future nights are unchanged.")
                                .font(.subheadline)
                                .foregroundStyle(LockboxTheme.textSecondary)
                            if let end = coordinator.activeLockEnd {
                                LockboxValueRow(label: "Opens", value: LockboxTimeFormat.string(end))
                            }
                        }
                    }

                    if coordinator.hasRecoveryRequest {
                        recoveryRequestCard(at: context.date)
                    } else {
                        LockboxCard {
                            VStack(alignment: .leading, spacing: 13) {
                                LockboxSectionLabel("Recovery", systemImage: "arrow.uturn.backward.circle")
                                Text("Recovery starts a 15-minute wait. You can leave the app. Your apps stay locked until you confirm or the lock ends.")
                                    .font(.subheadline)
                                    .foregroundStyle(LockboxTheme.textSecondary)
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
                            Text("If apps are still restricted, check Settings. Future nights are unchanged.")
                                .font(.subheadline)
                                .foregroundStyle(LockboxTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .lockboxScreen()
        .onAppear {
            // Capture the exact identity at presentation time. A later route
            // must not be able to settle this destination's old callback.
            let pending = coordinator.pendingQuickAction
            if let pending, case .recovery = pending.action {
                presentedQuickAction = pending
                onPresented(pending)
            }
        }
        .onDisappear {
            if let presentedQuickAction {
                onDismissed(presentedQuickAction)
                self.presentedQuickAction = nil
            }
        }
        .alert("End this lock?", isPresented: $showingConfirmation) {
            Button("End this lock", role: .destructive) {
                coordinator.confirmRecovery()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the current lock. Future nights are unchanged.")
        }
    }

    private func recoveryRequestCard(at date: Date) -> some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Recovery requested", systemImage: "hourglass")
                Text("Your apps stay locked until you confirm or the lock ends.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.textSecondary)
                if let eligibleAt = coordinator.recoveryEligibleAt {
                    LockboxValueRow(label: "You can confirm at", value: LockboxTimeFormat.string(eligibleAt))
                    if coordinator.isAuthorized && coordinator.canConfirmRecovery(at: date) {
                        Button("End this lock") {
                            guard coordinator.canConfirmRecovery(at: .now) else { return }
                            showingConfirmation = true
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    } else if date < eligibleAt {
                        Text("The 15-minute wait is still running. Waiting alone never unlocks your phone.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                    } else {
                        Text("This request can’t end the lock. Cancel it and request recovery again.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                    }
                } else {
                    Text("Checking your request. Your apps may stay locked meanwhile.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.textSecondary)
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
