import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @State private var showingDeveloperUnlock = false
    @State private var showingEmergencyReset = false
    @State private var showingDesignGallery = false

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "Settings")

            LockboxCard {
                VStack(alignment: .leading, spacing: 13) {
                    LockboxSectionLabel("Bedtime schedule", systemImage: "calendar.badge.clock")
                    if coordinator.isConfigured {
                        NavigationLink {
                            ConfigurationEditorView(coordinator: coordinator, isInitialSetup: false)
                        } label: {
                            HStack {
                                Label("Schedule and restrictions", systemImage: "slider.horizontal.3")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(LockboxTheme.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("Edits made during a committed lock are queued and cannot weaken that lock.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    } else {
                        Label("Finish setup from the Lockbox tab", systemImage: "info.circle")
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Safety review", systemImage: "checkmark.shield")
                    NavigationLink {
                        SafetyAssistantView(coordinator: coordinator)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "list.clipboard")
                                .foregroundStyle(LockboxTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Review essentials and coverage")
                                    .font(.subheadline.weight(.semibold))
                                Text("A local, non-authoritative checklist before stricter policies.")
                                    .font(.footnote)
                                    .foregroundStyle(LockboxTheme.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens a local checklist. It does not change restrictions or test emergency services.")
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Recovery", systemImage: "arrow.uturn.backward.circle")
                    LockboxValueRow(label: "Wait", value: "15 minutes")
                    Text("Recovery always requires this fixed wait and an explicit confirmation. Waiting alone never unlocks the phone. It does not disable future bedtime sessions.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Wind-down", systemImage: "bell.badge")
                    Toggle("Wind-down reminders", isOn: Binding(
                        get: { coordinator.windDownEnabled },
                        set: { coordinator.setWindDownEnabled($0) }
                    ))
                    .tint(LockboxTheme.accent)
                    Stepper(value: Binding(
                        get: { coordinator.windDownLeadMinutes },
                        set: { coordinator.setWindDownLeadMinutes($0) }
                    ), in: coordinator.windDownLeadChoices, step: 5) {
                        Text("Lead time: \(coordinator.windDownLeadMinutes) minutes")
                    }
                    .disabled(!coordinator.windDownEnabled)
                    Text("Wind-down derives its reminder time from the saved bedtime start. There is no second bedtime clock.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    switch NotificationAccessPresentation(state: coordinator.windDownAuthorizationStatus) {
                    case .request:
                        Button("Allow notifications") {
                            Task { await coordinator.requestWindDownNotificationAuthorization() }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                        .accessibilityHint("Requests notification permission for wind-down reminders")
                    case .granted:
                        Label("Notifications are enabled for wind-down reminders.", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.focus)
                            .accessibilityElement(children: .combine)
                    case .denied:
                        Text("Notifications are denied for Phone Lockbox. Enable them in the iOS Settings app to receive wind-down reminders.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityElement(children: .combine)
                    case .unavailable:
                        Text("Notification access is unavailable. Wind-down reminders cannot be scheduled.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityElement(children: .combine)
                    }
                    LockboxValueRow(label: "Notification access", value: coordinator.windDownAuthorizationStatus)
                    if coordinator.windDownEnabled {
                        Text(coordinator.pendingWindDownNotificationCount == 0
                             ? "No reminder is currently scheduled."
                             : "You’ll be reminded \(coordinator.windDownLeadMinutes) minutes before bedtime.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                    if let error = coordinator.ambientError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Live Activity", systemImage: "rectangle.inset.filled.and.person.filled")
                    Toggle("Show lock status when available", isOn: Binding(
                        get: { coordinator.liveActivityEnabled },
                        set: { coordinator.setLiveActivityEnabled($0) }
                    ))
                    .tint(LockboxTheme.accent)
                    Text("Local Live Activities are optional and best-effort. They never enforce, release, or prove that restrictions changed. If Phone Lockbox is force-closed, iOS may leave one stale until you reopen it; the monitor extension cannot dismiss the host-created activity. Reliable host-closed ending requires ActivityKit push infrastructure, which is not provisioned.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            DeveloperToolsSection(
                coordinator: coordinator,
                companion: companion,
                showingDeveloperUnlock: $showingDeveloperUnlock,
                showingEmergencyReset: $showingEmergencyReset,
                showingDesignGallery: $showingDesignGallery
            )
        }
        .lockboxScreen()
        .fullScreenCover(isPresented: $showingDesignGallery) {
            DesignGalleryView()
        }
        .confirmationDialog(
            "Unlock current Phone Lockbox sessions?",
            isPresented: $showingDeveloperUnlock,
            titleVisibility: .visible
        ) {
            Button("Developer unlock now", role: .destructive) {
                coordinator.developerUnlockNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Developer-only escape hatch. This releases current Phone Lockbox sessions immediately and does not prove that other owners or system restrictions are cleared.")
        }
        .confirmationDialog(
            "Reset Phone Lockbox state?",
            isPresented: $showingEmergencyReset,
            titleVisibility: .visible
        ) {
            Button("Emergency reset", role: .destructive) {
                coordinator.emergencyReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops Phone Lockbox monitoring and clears this app's named Managed Settings and shared state. Use only when ordinary cleanup is unavailable.")
        }
    }
}

private enum NotificationAccessPresentation {
    case request
    case granted
    case denied
    case unavailable

    init(state: String) {
        switch state {
        case "Not requested": self = .request
        case "Authorized", "Provisional", "Ephemeral": self = .granted
        case "Denied": self = .denied
        default: self = .unavailable
        }
    }
}

private struct DeveloperToolsSection: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @Binding var showingDeveloperUnlock: Bool
    @Binding var showingEmergencyReset: Bool
    @Binding var showingDesignGallery: Bool
    @State private var relayURLDraft = ""
    @State private var showingResetAnchorsConfirmation = false
    @State private var showingDiscardFriendReleaseConfirmation = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 14) {
                LockboxSectionLabel("Developer", systemImage: "wrench.and.screwdriver")

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Friend approval can end locks (prototype)", isOn: $companion.friendApprovalCanEndLocksEnabled)
                        .tint(LockboxTheme.accent)
                    Text("Off by default. When on, the People tab lets you end your own lock from a trusted person's approval, with a confirmation. When off, the People tab behaves exactly as before: approvals are shown, but never end the lock.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    if coordinator.pendingFriendReleaseIntent != nil {
                        Button("Discard pending friend release", role: .destructive) {
                            showingDiscardFriendReleaseConfirmation = true
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                        Text("Clears a durably pending end-lock request without ever using it. Use only if it stays stuck (for example the request or approval disappeared from the inbox).")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                }

                Divider().overlay(LockboxTheme.border)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Companion relay address")
                        .font(.subheadline.weight(.semibold))
                    TextField(CompanionCoordinator.defaultRelayBaseURLString, text: $relayURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onAppear { relayURLDraft = companion.relayBaseURLString }
                        .onSubmit { applyRelayURL() }
                        .accessibilityLabel("Companion relay address")
                        .accessibilityHint("Defaults to the local relay at 127.0.0.1 port 8002")
                    Button("Save relay address") { applyRelayURL() }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                    Text("Prototype — local relay only. On a device, set this to your Mac's LAN address so the People tab can reach it.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    Button("Reset relay anchors", role: .destructive) {
                        showingResetAnchorsConfirmation = true
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    Text("Clears the on-device rollback/fork protection checkpoints. Development use only — after a reset, a real regression or fork from the relay would no longer be detected until a new checkpoint is established.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    NavigationLink {
                        CompanionPrototypeView()
                    } label: {
                        HStack {
                            Label("Companion protocol demo", systemImage: "network")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens a low-level, simulated-relay protocol demo. It is separate from the real People tab and does not use the relay address above.")
                    Text("A low-level protocol demo against a simulated, in-memory relay — separate from the real People tab above.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }

                Divider().overlay(LockboxTheme.border)

                Button {
                    showingDesignGallery = true
                } label: {
                    HStack {
                        Label("Open design gallery", systemImage: "paintpalette")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens static theme and Lockbox fixture previews. It does not change restrictions.")
                Text("Static design gallery — does not change restrictions.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                Divider().overlay(LockboxTheme.border)

                NavigationLink {
                    AmbientPrototypeView()
                } label: {
                    HStack {
                        Label("Ambient standalone screen", systemImage: "waveform.path.ecg")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Prototype wind-down and Live Activity controls are intentionally separate from the saved lock. They never apply or release restrictions.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                Button {
                    coordinator.startImmediateTestLock()
                } label: {
                    Label(
                        coordinator.testScheduleActive ? "Prototype test is active" : "Start prototype test",
                        systemImage: coordinator.testScheduleActive ? "checkmark.circle.fill" : "bolt.fill"
                    )
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                .disabled(!coordinator.canApplySelection || coordinator.testScheduleActive || coordinator.hasOSRegistration || coordinator.recurringEnabledIntent || !coordinator.isAuthorized)
                Text(coordinator.testScheduleActive
                     ? "This developer restriction remains until Developer unlock now is used."
                     : "The prototype test is not part of normal Lockbox operation and is mutually exclusive with recurring monitoring.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                if coordinator.recurringEnabledIntent || coordinator.hasOSRegistration {
                    Button("Disable recurring schedule", role: .destructive) {
                        coordinator.stopSchedule()
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                }
                Button("Developer unlock now", role: .destructive) {
                    showingDeveloperUnlock = true
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                Button("Emergency reset shared state", role: .destructive) {
                    showingEmergencyReset = true
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                Text("Use these controls only for development cleanup. Manual cleanup is not proof of automatic release.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                if coordinator.legacyRegistrationNeedsReview {
                    Label("Legacy monitoring ownership needs explicit cleanup; do not assume the phone is unlocked.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                DiagnosticsSection(coordinator: coordinator)
            }
        }
        .confirmationDialog(
            "Reset relay anchors?",
            isPresented: $showingResetAnchorsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset relay anchors", role: .destructive) {
                companion.resetRelayAnchors()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Development-only. This clears rollback/fork protection checkpoints; a real regression or fork from the relay would go undetected until a new checkpoint is established.")
        }
        .confirmationDialog(
            "Discard the pending friend release?",
            isPresented: $showingDiscardFriendReleaseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard pending friend release", role: .destructive) {
                companion.discardPendingFriendRelease(coordinator: coordinator)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the pending request locally without ever using it. The lock stays on until it ends some other way.")
        }
    }

    private func applyRelayURL() {
        let trimmed = relayURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            relayURLDraft = companion.relayBaseURLString
            return
        }
        companion.relayBaseURLString = trimmed
    }
}
