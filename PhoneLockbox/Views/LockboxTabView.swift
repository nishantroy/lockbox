import SwiftUI
import FamilyControls

struct LockboxTabView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @Binding var navigationPath: [QuickActionRoute.Destination]
    /// One sheet slot for every sheet this tab presents, so a quick action can
    /// never be presented over (or stranded behind) the custom-end picker.
    @State private var sheet: LockboxSheet?
    @Namespace private var stateNamespace
    @State private var requestedManualPreset: QuickActionRoute.FocusPreset?
    @State private var presentedFocusAction: ScreenTimeCoordinator.PendingQuickAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            Group {
                if !coordinator.isConfigured {
                    SetupView(coordinator: coordinator)
                } else if let display = coordinator.activeLockDisplay {
                    ActiveLockView(coordinator: coordinator, display: display, now: context.date, namespace: stateNamespace)
                        .transition(.opacity)
                } else {
                    UnlockedLockboxView(
                        coordinator: coordinator,
                        companion: companion,
                        now: context.date,
                        namespace: stateNamespace,
                        onPresentCustomEnd: { sheet = .customEnd($0) }
                    )
                    .transition(.opacity)
                }
            }
            // Fires only on becoming locked, wherever the lock came from.
            .sensoryFeedback(.success, trigger: coordinator.activeLockDisplay != nil) { old, new in !old && new }
            // Open and Locked share one composition; cross-fade between them.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: coordinator.activeLockDisplay)
        }
        .lockboxScreen()
        .sheet(item: $sheet, onDismiss: {
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
        }) { presented in
            switch presented {
            case .manualLock:
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
            case .customEnd(let request):
                CustomEndSheet(
                    coordinator: coordinator,
                    referenceDate: request.referenceDate,
                    currentEnd: request.currentEnd,
                    onSet: request.onSet
                )
            }
        }
        .onChange(of: coordinator.hasActiveLock) { _, isActive in
            // The picker belongs to the Open screen; drop it if a lock starts.
            if isActive, case .customEnd = sheet { sheet = nil }
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
            // Never replace an already-presented sheet. A queued route is
            // consumed from the sheet's onDismiss.
            guard presentedFocusAction == nil, sheet == nil else { return }
            presentedFocusAction = pending
            requestedManualPreset = preset
            sheet = .manualLock
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

private enum LockboxSheet: Identifiable {
    case manualLock
    case customEnd(CustomEndRequest)

    var id: String {
        switch self {
        case .manualLock: return "manualLock"
        case .customEnd(let request): return "customEnd-\(request.id)"
        }
    }
}

/// What the Open screen asks the custom-end picker to show, and how to report
/// the chosen end back.
struct CustomEndRequest: Identifiable {
    let id = UUID()
    let referenceDate: Date
    let currentEnd: Date?
    let onSet: (Date) -> Void
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
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let namespace: Namespace.ID
    let onPresentCustomEnd: (CustomEndRequest) -> Void
    // Each appearance of the Open screen starts on 30 min (no persistence).
    @State private var choice: LockDurationChoice = .thirtyMinutes
    @State private var customSelection = RuntimeCustomEndSelectionState()
    @State private var customRangeUnavailable = false
    @State private var attempted = false

    /// The end shown on the circle. It is also the exact end submitted on tap,
    /// so what the user saw is what is frozen. Nil when unavailable or when it
    /// would already be rejected a minute from now.
    private var displayedEnd: Date? {
        let preset: RuntimeLockNowEnd.Preset?
        switch choice {
        case .thirtyMinutes: preset = .thirtyMinutes
        case .oneHour: preset = .oneHour
        case .custom: preset = nil
        }
        return RuntimeLockNowEnd.displayedEnd(
            preset: preset,
            customEnd: choice == .custom ? customSelection.customEnd : nil,
            now: now
        )
    }

    /// One calm line when a saved bedtime begins during the lock and keeps the
    /// phone locked past the shown end.
    private var overlapNote: String? {
        guard coordinator.isAuthorized, let end = displayedEnd else { return nil }
        let schedule = (
            start: RuntimeTime(hour: coordinator.savedStartComponents.hour ?? 22, minute: coordinator.savedStartComponents.minute ?? 0),
            end: RuntimeTime(hour: coordinator.savedEndComponents.hour ?? 7, minute: coordinator.savedEndComponents.minute ?? 0)
        )
        guard let overlap = RuntimeLockNowEnd.bedtimeOverlap(
            schedule: schedule,
            enabled: coordinator.recurringEnabledIntent,
            lockEnd: end,
            now: now
        ) else { return nil }
        return "Bedtime starts \(RuntimeTimeFormat.string(overlap.bedtimeStart, now: now, style: .atPhrase)), so this stays locked until \(RuntimeTimeFormat.string(overlap.effectiveEnd, now: now))."
    }

    private func lockNow(until end: Date) {
        attempted = true
        coordinator.startManualLock(expectedEnd: end)
    }

    private func openCustomEnd() {
        let reference = Date()
        guard coordinator.manualLockCustomRange(at: RuntimeLockNowEnd.pickerReference(at: reference)) != nil else {
            customRangeUnavailable = true
            return
        }
        customRangeUnavailable = false
        onPresentCustomEnd(CustomEndRequest(referenceDate: reference, currentEnd: customSelection.customEnd) { end in
            customSelection = RuntimeCustomEndSelectionState.transition(
                customSelection, event: .userSelected(end), at: now, calendar: Calendar.current
            )
            select(.custom)
        })
    }

    private func select(_ newChoice: LockDurationChoice) {
        customRangeUnavailable = false
        attempted = false // a stale error must not outlive a new choice
        choice = newChoice
    }

    private var customChipTitle: String {
        if choice == .custom, let end = customSelection.customEnd {
            return "Until \(RuntimeLockNowEnd.chipTime(end, now: now))"
        }
        return "Until…"
    }

    private var chip30: some View {
        LockboxDurationChip(title: "30 min", isSelected: choice == .thirtyMinutes) { select(.thirtyMinutes) }
    }

    private var chip1h: some View {
        LockboxDurationChip(title: "1 hour", isSelected: choice == .oneHour) { select(.oneHour) }
    }

    private var chipUntil: some View {
        LockboxDurationChip(title: customChipTitle, isSelected: choice == .custom, hint: "Opens a time picker") { openCustomEnd() }
    }

    /// Three chips in a row; if they don't fit, 30 min and 1 hour on one row
    /// with Until… below; at the largest sizes, one per row.
    private var durationChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chip30; chip1h; chipUntil }
            VStack(spacing: 8) {
                HStack(spacing: 8) { chip30; chip1h }
                chipUntil
            }
            VStack(spacing: 8) { chip30; chip1h; chipUntil }
        }
    }

    @ViewBuilder
    private var lockControl: some View {
        let end = coordinator.isAuthorized ? displayedEnd : nil
        let endLine = end.map { "until \(RuntimeTimeFormat.string($0, now: now))" }
        let spokenEnd = end.map { RuntimeTimeFormat.string($0, now: now, style: .phrase) }
        let note = overlapNote
        if dynamicTypeSize >= .accessibility1 {
            Button {
                if let end { lockNow(until: end) }
            } label: {
                Label(endLine.map { "Lock now · \($0)" } ?? "Lock now", systemImage: "lock.fill")
            }
            .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
            .disabled(end == nil)
            .accessibilityLabel(spokenEnd.map { "Lock now until \($0)" } ?? "Lock now")
            .accessibilityHint(end == nil ? "Needs Screen Time access or an available end" : "Locks right away. \(note ?? "")")
        } else {
            LockboxLockNowButton(endLine: endLine, spokenEnd: spokenEnd, note: note) {
                if let end { lockNow(until: end) }
            }
            .disabled(end == nil)
            .padding(.vertical, 12)
            .matchedGeometryEffect(id: "stateCircle", in: namespace)
        }
    }

    private func attentionLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(LockboxTheme.attention)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

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
                if coordinator.isAuthorized {
                    durationChips
                }
                lockControl
                if coordinator.isAuthorized {
                    if let note = overlapNote {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    if customRangeUnavailable {
                        attentionLine("No finite end is available at the moment.")
                    } else if displayedEnd == nil {
                        attentionLine("This end is no longer available. Pick another.")
                    }
                    if attempted, let error = coordinator.lastError {
                        attentionLine(error)
                    }
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

            if !attempted {
                OperationalWarning(coordinator: coordinator)
            }
        }
    }
}

private enum LockDurationChoice {
    case thirtyMinutes, oneHour, custom
}

/// One option in a single-selection row: filled and bordered in the rest
/// colour when selected, surface and hairline otherwise.
private struct LockboxDurationChip: View {
    let title: String
    let isSelected: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? LockboxTheme.primary : LockboxTheme.textSecondary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(isSelected ? LockboxTheme.rest.opacity(0.2) : LockboxTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? LockboxTheme.rest : LockboxTheme.border.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint ?? "")
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
    let namespace: Namespace.ID

    private var semanticColor: Color { display.isBedtime ? LockboxTheme.rest : LockboxTheme.focus }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LockboxScrollView {
            // Same header, position and size as the Open screen.
            VStack(alignment: .center, spacing: 4) {
                LockboxPageHeader(title: "Locked")
                Text(display.originCopy)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(LockboxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Locked, \(display.spokenOriginCopy)")
            .accessibilityAddTraits(.isHeader)
            .zIndex(1) // keep the halo behind the header text

            VStack(spacing: 16) {
                // Keeps the circle where it sits on the Open screen, under
                // the duration chips (one 44 pt row).
                Color.clear
                    .frame(height: 44)
                    .accessibilityHidden(true)
                if dynamicTypeSize >= .accessibility1 {
                    endText
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(activeSummary)
                } else {
                    LockboxStateCircle(color: semanticColor) { diameter in
                        endCircleContent(diameter: diameter)
                    }
                    .padding(.vertical, 12)
                    .matchedGeometryEffect(id: "stateCircle", in: namespace)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(activeSummary)
                }
            }

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

    @ViewBuilder
    private func endCircleContent(diameter: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: diameter * 0.16, weight: .semibold))
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            if let end = coordinator.activeLockEnd {
                let parts = RuntimeTimeFormat.parts(end, now: now)
                Text("until").font(.subheadline)
                if let day = parts.day {
                    Text(day)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(parts.time)
                    .lockboxTimeHero()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("Opening time unavailable")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Accessibility-size fallback for the circle: the same content as plain text.
    @ViewBuilder
    private var endText: some View {
        if let end = coordinator.activeLockEnd {
            VStack(spacing: 4) {
                Text("until").font(.subheadline).foregroundStyle(LockboxTheme.textSecondary)
                Text(RuntimeTimeFormat.string(end, now: now))
                    .lockboxTimeHero()
                    .foregroundStyle(semanticColor)
                    .multilineTextAlignment(.center)
            }
        } else {
            Text("Opening time unavailable")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(semanticColor)
        }
    }

    private var activeSummary: String {
        if let end = coordinator.activeLockEnd {
            return "Locked until \(RuntimeTimeFormat.string(end, now: now, style: .phrase))"
        }
        return "Opening time unavailable"
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
