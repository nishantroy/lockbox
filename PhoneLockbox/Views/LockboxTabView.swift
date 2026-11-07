import SwiftUI
import FamilyControls

struct LockboxTabView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @Binding var navigationPath: [QuickActionRoute.Destination]
    @State private var showingManualLock = false
    @State private var requestedManualPreset: QuickActionRoute.FocusPreset?
    @State private var presentedFocusAction: ScreenTimeCoordinator.PendingQuickAction?

    init(coordinator: ScreenTimeCoordinator, companion: CompanionCoordinator,
        navigationPath: Binding<[QuickActionRoute.Destination]> = .constant([])) {
        self.coordinator = coordinator
        self.companion = companion
        _navigationPath = navigationPath
    }

    var body: some View {
        // The minute tick re-evaluates which state is shown, so the screen
        // flips from active to open at the lock's end and across midnight.
        TimelineView(.everyMinute) { context in
            if !coordinator.isConfigured {
                SetupView(coordinator: coordinator)
            } else if let display = coordinator.activeLockDisplay {
                ActiveLockView(coordinator: coordinator, display: display, now: context.date)
            } else {
                UnlockedLockboxView(coordinator: coordinator, companion: companion, showingManualLock: $showingManualLock, now: context.date)
            }
        }
        .lockboxScreen()
        .sheet(isPresented: $showingManualLock, onDismiss: {
            // A focus identity remains busy until the sheet is actually gone.
            // This prevents a rapid second URL from replacing its state while
            // SwiftUI is still presenting or dismissing the first sheet.
            if let presentedFocusAction {
                coordinator.settlePresentedQuickAction(presentedFocusAction)
            }
            requestedManualPreset = nil
            presentedFocusAction = nil
            // If a regular Lock now sheet was already visible when an external
            // route arrived, consume the queued route after that sheet closes.
            consumeQuickAction()
        }) {
            ManualLockSheet(
                coordinator: coordinator,
                requestedPreset: requestedManualPreset,
                onPresented: { pending in
                    guard let presentedFocusAction,
                          presentedFocusAction == pending else { return }
                    // Validate only the exact identity at presentation. The
                    // durable claim is retained until onDismiss settles the
                    // sheet, so a crash before dismissal can retry it.
                    _ = coordinator.acknowledgePresentedQuickAction(presentedFocusAction)
                }
            )
        }
        .onAppear {
            consumeQuickAction()
        }
        .onChange(of: coordinator.pendingQuickAction) { _, _ in
            consumeQuickAction()
        }
    }

    private func consumeQuickAction() {
        guard let pending = coordinator.pendingQuickAction else { return }
        switch pending.action {
        case .focus(let preset):
            // The sheet's onAppear is the presentation callback. Until then,
            // the claim (including its ID/token) remains durable and retryable.
            // Never replace an already-presented regular or quick-action sheet.
            guard presentedFocusAction == nil, !showingManualLock else { return }
            presentedFocusAction = pending
            requestedManualPreset = preset
            showingManualLock = true
        case .status:
            // Status has no second screen: this visible Lockbox tab is its
            // destination, and this explicit consumption handler is the ack
            // point after the tab has been selected by ContentView.
            _ = coordinator.acknowledgePresentedQuickAction(pending)
            _ = coordinator.settlePresentedQuickAction(pending)
        case .recovery:
            if !navigationPath.contains(.recovery) {
                navigationPath.append(.recovery)
            } else {
                // Recovery is already the visible destination, so its
                // presentation has already occurred and this is idempotent.
                _ = coordinator.acknowledgePresentedQuickAction(pending)
                _ = coordinator.settlePresentedQuickAction(pending)
            }
        }
    }
}

private struct SetupView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        LockboxScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LockboxPageHeader(title: "Get started")
                Text("Choose when your phone locks and which apps it affects.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.textSecondary)
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        LockboxSectionLabel("Screen Time access", systemImage: "hourglass")
                        Spacer()
                        LockboxStatusBadge(
                            title: AuthorizationStatusLabel.value(for: coordinator),
                            color: coordinator.isAuthorized ? LockboxTheme.rest : LockboxTheme.textSecondary
                        )
                    }
                    if coordinator.isAuthorized {
                        NavigationLink {
                            ConfigurationEditorView(coordinator: coordinator, isInitialSetup: true)
                        } label: {
                            Label("Set up bedtime rules", systemImage: "slider.horizontal.3")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens bedtime rules setup")
                    } else {
                        Button("Request access") {
                            Task { await coordinator.requestAuthorization() }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .accessibilityHint("Opens Apple's Screen Time authorization prompt")
                        Text("Access is used only to apply your own rules. People and Settings work without it.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                    }
                }
            }

            if let error = coordinator.lastError {
                LockboxCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LockboxTheme.attention)
                        .font(.subheadline)
                }
            }
        }
    }
}

/// The next saved bedtime occurrence that has not started yet. While a
/// window is in progress this resolves the one after it, so "Open" never
/// shows a past start.
@MainActor
private func nextBedtimeOccurrence(_ coordinator: ScreenTimeCoordinator, now: Date) -> RuntimeOccurrenceResolver.Occurrence? {
    guard let occurrence = currentOrNextBedtime(coordinator, after: now) else { return nil }
    return occurrence.start > now ? occurrence : currentOrNextBedtime(coordinator, after: occurrence.end)
}

/// True when a saved bedtime window is in progress at `now`.
@MainActor
private func isBedtimeWindowInProgress(_ coordinator: ScreenTimeCoordinator, now: Date) -> Bool {
    guard let occurrence = currentOrNextBedtime(coordinator, after: now) else { return false }
    return occurrence.start <= now
}

@MainActor
private func currentOrNextBedtime(_ coordinator: ScreenTimeCoordinator, after date: Date) -> RuntimeOccurrenceResolver.Occurrence? {
    RuntimeOccurrenceResolver.currentOrNext(
        start: RuntimeTime(hour: coordinator.savedStartComponents.hour ?? 22, minute: coordinator.savedStartComponents.minute ?? 0),
        end: RuntimeTime(hour: coordinator.savedEndComponents.hour ?? 7, minute: coordinator.savedEndComponents.minute ?? 0),
        enabled: true,
        after: date
    )
}

struct UnlockedLockboxView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @Binding var showingManualLock: Bool
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var windDownStatusMessage: String {
        if let error = coordinator.ambientError { return error }
        guard coordinator.windDownEnabled else { return "Off" }
        guard coordinator.windDownAuthorizationStatus != "Not requested" else {
            return "Allow notifications in Settings to turn this on."
        }
        guard coordinator.windDownAuthorizationStatus != "Denied" else {
            return "Notifications are off. Allow them in Settings."
        }
        return "\(coordinator.windDownLeadMinutes) minutes before bedtime"
    }

    private func bedtimeLine(now: Date) -> String {
        guard coordinator.recurringEnabledIntent else { return "Bedtime is off" }
        guard let occurrence = nextBedtimeOccurrence(coordinator, now: now) else { return "No bedtime set" }
        return "Bedtime \(RuntimeTimeFormat.string(occurrence.start, now: now, style: .atPhrase))"
    }

    var body: some View {
        LockboxScrollView {
            VStack(alignment: .center, spacing: 4) {
                LockboxPageHeader(title: "Open")
                Text(bedtimeLine(now: now))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(LockboxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .zIndex(1) // keep the halo behind the header text

            VStack(spacing: 16) {
                if dynamicTypeSize >= .accessibility1 {
                    Button {
                        showingManualLock = true
                    } label: {
                        Label("Lock now", systemImage: "lock.fill")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(!coordinator.isAuthorized)
                    .accessibilityHint(coordinator.isAuthorized ? "Choose a finite focus lock duration" : "Needs Screen Time access")
                } else {
                    LockboxLockNowButton { showingManualLock = true }
                        .disabled(!coordinator.isAuthorized)
                        .padding(.vertical, 12)
                }
                if coordinator.isAuthorized {
                    Text("30 minutes, 1 hour, or until a time you choose.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else if coordinator.authorizationStatus == .denied {
                    Text("Screen Time access is off. Turn it on in iOS Settings to start a lock.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.attention)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Screen Time access is needed to start a lock.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.attention)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Button("Allow Screen Time access") {
                        Task { await coordinator.requestAuthorization() }
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                }
            }

            TonightCard(coordinator: coordinator, now: now)

            VStack(alignment: .leading, spacing: 8) {
                LockboxSectionLabel("Your rhythm")
                    .padding(.horizontal, 4)
                VStack(alignment: .leading, spacing: 0) {
                    LockboxValueRow(label: "Mode", value: coordinator.savedModeTitle)
                        .frame(minHeight: 44)
                    Divider().overlay(LockboxTheme.border.opacity(0.6))
                    LockboxValueRow(label: "Apps & categories", value: "\(coordinator.savedSelectedItemCount) selected")
                        .frame(minHeight: 44)
                    Divider().overlay(LockboxTheme.border.opacity(0.6))
                    NavigationLink {
                        SettingsView(coordinator: coordinator, companion: companion)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: coordinator.windDownEnabled ? "bell.badge" : "bell.slash")
                                .foregroundStyle(coordinator.ambientError == nil ? LockboxTheme.accent : LockboxTheme.attention)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Wind-down")
                                    .font(.subheadline.weight(.semibold))
                                Text(windDownStatusMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(coordinator.ambientError == nil ? LockboxTheme.textSecondary : LockboxTheme.attention)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(LockboxTheme.surface, in: RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous))
            }

            OperationalWarning(coordinator: coordinator)
        }
    }
}

private struct TonightCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @State private var proposedBedtimeEnd: Date?
    @State private var showingBedtimeConfirmation = false
    let now: Date

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 12) {
                LockboxSectionLabel(isBedtimeWindowInProgress(coordinator, now: now) ? "Next bedtime" : "Tonight", systemImage: "moon.fill")
                if coordinator.recurringEnabledIntent, let occurrence = nextOccurrence {
                    LockboxValueRow(label: "Locks", value: RuntimeTimeFormat.string(occurrence.start, now: now))
                    LockboxValueRow(label: "Opens", value: RuntimeTimeFormat.string(occurrence.end, now: now))
                    Button {
                        // Freeze the absolute boundary at preview time. The
                        // confirmation submits this same Date unchanged;
                        // runtime rejects it if the saved occurrence is stale.
                        let previewedAt = Date()
                        guard let end = coordinator.bedtimeNowProposedEnd(at: previewedAt) else { return }
                        proposedBedtimeEnd = end
                        showingBedtimeConfirmation = true
                    } label: {
                        Label("Start bedtime now", systemImage: "moon.fill")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                    .disabled(!coordinator.canStartBedtimeNow)
                    .accessibilityLabel("Start bedtime now")
                    .accessibilityHint("Uses your saved bedtime rules and opens at the configured morning time")
                } else {
                    Label("Bedtime schedule is off", systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    Text("Save a schedule in Settings to turn it on.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.textSecondary)
                }
            }
        }
        .alert("Start bedtime now?", isPresented: $showingBedtimeConfirmation) {
            Button("Start bedtime now") {
                guard let proposedBedtimeEnd else { return }
                coordinator.startBedtimeNow(expectedEnd: proposedBedtimeEnd)
                self.proposedBedtimeEnd = nil
            }
            Button("Cancel", role: .cancel) {
                proposedBedtimeEnd = nil
            }
        } message: {
            if let proposedBedtimeEnd {
                Text("Your apps will open \(RuntimeTimeFormat.string(proposedBedtimeEnd, now: now, style: .atPhrase)). Future nights stay scheduled.")
            } else {
                Text("Future nights stay scheduled.")
            }
        }
    }

    private var nextOccurrence: RuntimeOccurrenceResolver.Occurrence? {
        nextBedtimeOccurrence(coordinator, now: now)
    }
}

struct ActiveLockView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    let display: RuntimeActiveLockDisplay
    let now: Date

    private var semanticColor: Color { display.isBedtime ? LockboxTheme.rest : LockboxTheme.focus }

    private var heroTime: String {
        guard let end = coordinator.activeLockEnd else { return "Opening time unavailable" }
        return "Locked until \(RuntimeTimeFormat.string(end, now: now, style: .phrase))"
    }

    var body: some View {
        LockboxScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(display.label, systemImage: display.isBedtime ? "moon.fill" : "scope")
                    .font(.subheadline.weight(.semibold))
                Text(heroTime)
                    .lockboxTimeHero()
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").accessibilityHidden(true)
                    Text(display.originCopy)
                        .font(.subheadline)
                }
                .opacity(0.85)
            }
            .foregroundStyle(LockboxTheme.onAccent)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(semanticColor, in: RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(activeSummary)

            if let pending = coordinator.pendingChangesSummary {
                LockboxCard {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(semanticColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Changes after this lock")
                                .font(.subheadline.weight(.semibold))
                            Text(pending)
                                .font(.subheadline)
                                .foregroundStyle(LockboxTheme.textSecondary)
                        }
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Need to end early?", systemImage: "arrow.uturn.backward.circle")
                    Text("Recovery waits 15 minutes, then asks you to confirm.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.textSecondary)
                    NavigationLink {
                        RecoveryView(coordinator: coordinator)
                    } label: {
                        HStack {
                            Text("Start recovery")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            OperationalWarning(coordinator: coordinator)
        }
    }

    private var activeSummary: String {
        "\(display.label). \(heroTime). \(display.originCopy)."
    }
}

struct OperationalWarning: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    @ViewBuilder
    var body: some View {
        if let error = coordinator.lastError {
            LockboxCard {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.attention)
            }
        }
    }
}

@MainActor
private enum AuthorizationStatusLabel {
    static func value(for coordinator: ScreenTimeCoordinator) -> String {
        if coordinator.isAuthorized { return "Authorized" }
        switch coordinator.authorizationStatus {
        case .approved: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        default: return "Unknown"
        }
    }
}

@MainActor
private enum SavedWindowFormatter {
    static func value(for coordinator: ScreenTimeCoordinator) -> String {
        let start = coordinator.savedStartComponents
        let end = coordinator.savedEndComponents
        return "\(String(format: "%02d:%02d", start.hour ?? 0, start.minute ?? 0)) – \(String(format: "%02d:%02d", end.hour ?? 0, end.minute ?? 0))"
    }
}
