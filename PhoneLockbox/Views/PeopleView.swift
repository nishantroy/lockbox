import SwiftUI
#if canImport(CompanionKit)
import CompanionKit
#endif

struct PeopleView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "People")
            PrototypeLabelCard()

#if canImport(CompanionKit)
            if companion.isAvailable {
                IntroCard()
                InviteSomeoneCard(companion: companion)
                AcceptInviteCard(companion: companion)
                if coordinator.companionActiveSessionIdentity != nil || !companion.trustedApprovers.isEmpty {
                    AskToEndEarlyCard(coordinator: coordinator, companion: companion)
                }
                if !companion.people.isEmpty {
                    PeopleListCard(companion: companion)
                }
                InboxCard(coordinator: coordinator, companion: companion)
                if let notice = companion.inboxDataNotice {
                    LockboxCard {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            if let error = companion.lastError {
                LockboxCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        if companion.needsRepair {
                            Text("This device's companion key needs to be re-paired: create a new invite or accept one again.")
                                .font(.footnote)
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
#else
            LockboxCard {
                Text("CompanionKit is not linked in this build.")
                    .foregroundStyle(LockboxTheme.secondary)
            }
#endif
        }
        .lockboxScreen()
#if canImport(CompanionKit)
        .task {
            await companion.refreshInbox()
            await companion.replayPendingFriendRelease(coordinator: coordinator)
        }
        .refreshable {
            await companion.refreshInbox()
            await companion.replayPendingFriendRelease(coordinator: coordinator)
        }
#endif
    }
}

private struct PrototypeLabelCard: View {
    var body: some View {
        LockboxCard {
            HStack(spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.orange)
                Text("Prototype")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Prototype feature")
        }
    }
}

#if canImport(CompanionKit)

private struct IntroCard: View {
    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    LockboxIconBadge(systemImage: "person.2.fill", color: LockboxTheme.accent)
                    Text("Set up a trusted person")
                        .font(.title3.weight(.semibold))
                }
                Text("Pairing uses device-held identities confirmed with a six-digit code — no account or email is required. A trusted person can approve ending one exact session early, but that approval isn't connected to your lock yet in this build. This does not use Screen Time, and app selections and usage are never shared.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

private struct InviteSomeoneCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var pastedAcceptance = ""
    @State private var typedCode = ""
    @State private var nickname = ""
    @State private var isCreating = false
    @State private var isConfirming = false
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Invite a trusted person", systemImage: "person.badge.plus")
                Text("Create a link and share it however you'd normally reach them (Messages, AirDrop). Possession of the link never unlocks anything by itself.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                Button {
                    isCreating = true
                    Task { await companion.createInvite(); isCreating = false }
                } label: {
                    Label(isCreating ? "Creating…" : "Create an invite to share", systemImage: "link.badge.plus")
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                .disabled(isCreating)
                .accessibilityHint("Creates a one-use invitation link")

                if let invitation = companion.pendingInvitation {
                    ShareLink(item: invitation.shareLink) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                }

                Divider().overlay(LockboxTheme.border)

                Text("Once they accept, they'll send back an acceptance code. Paste it here, then ask them to read their six-digit code aloud and type exactly what they say below — don't read it off screen yourself.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                TextField("Paste acceptance code", text: $pastedAcceptance, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if let acceptance = companion.decodeAcceptance(from: pastedAcceptance) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name for this person", text: $nickname)
                            .textFieldStyle(.roundedBorder)
                        TextField("Six-digit code they read aloud", text: $typedCode)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textContentType(.oneTimeCode)
                            .focused($codeFieldFocused)
                            .onChange(of: typedCode) { _, newValue in
                                // Number pads have no return key, and pasted
                                // codes may contain spaces: keep six digits.
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue { typedCode = digits }
                            }
                            .accessibilityLabel("Six-digit code they read aloud")
                        Button(isConfirming ? "Confirming…" : "Confirm") {
                            confirm(acceptance)
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .disabled(typedCode.count != 6 || isConfirming)
                        .accessibilityHint("Confirms this person as a trusted approver only if the typed code matches")
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            if codeFieldFocused {
                                Button("Done") { codeFieldFocused = false }
                                Spacer()
                                Button("Confirm") { confirm(acceptance) }
                                    .disabled(typedCode.count != 6 || isConfirming)
                            }
                        }
                    }
                }
            }
        }
    }

    private func confirm(_ acceptance: PairingAcceptance) {
        guard typedCode.count == 6, !isConfirming else { return }
        codeFieldFocused = false
        isConfirming = true
        Task {
            await companion.confirmAcceptance(acceptance, typedVerificationCode: typedCode, nickname: nickname)
            isConfirming = false
            if companion.pendingAcceptance == nil {
                pastedAcceptance = ""; typedCode = ""; nickname = ""
            }
        }
    }
}

private struct AcceptInviteCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var pastedInvite = ""

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Help someone else", systemImage: "hand.raised")
                Text("Paste an invite link someone shared with you to become their trusted approver.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                TextField("Paste invite link", text: $pastedInvite, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Accept invite") {
                    guard let invitation = companion.decodeInvitation(from: pastedInvite) else {
                        return
                    }
                    Task {
                        await companion.acceptInvite(invitation)
                        pastedInvite = ""
                    }
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                .disabled(companion.decodeInvitation(from: pastedInvite) == nil)

                if let acceptance = companion.pendingAcceptance {
                    VStack(alignment: .leading, spacing: 8) {
                        LockboxValueRow(label: "Your code", value: acceptance.verificationCode)
                        Text("Read this code aloud to them, or share the text below, so they can type it in to confirm.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                        ShareLink(item: companion.acceptanceShareText(acceptance)) {
                            Label("Share acceptance code", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct PeopleListCard: View {
    @ObservedObject var companion: CompanionCoordinator

    // Revoked pairings are kept in storage (so a relay that keeps reporting
    // them can never resurrect a fresh-looking entry) but never shown here.
    private var owners: [CompanionPerson] { companion.people.filter { $0.localRole == .iAmOwner && $0.pairing.state == .active } }
    private var approving: [CompanionPerson] { companion.people.filter { $0.localRole == .iAmApprover && $0.pairing.state == .active } }

    var body: some View {
        if !owners.isEmpty {
            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Your trusted people", systemImage: "person.2.badge.gearshape")
                    ForEach(owners) { person in
                        OwnerPersonRow(companion: companion, person: person)
                        if person.id != owners.last?.id { Divider().overlay(LockboxTheme.border) }
                    }
                }
            }
        }
        if !approving.isEmpty {
            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("People you're helping", systemImage: "hands.sparkles")
                    ForEach(approving) { person in
                        ApproverPersonRow(companion: companion, person: person)
                        if person.id != approving.last?.id { Divider().overlay(LockboxTheme.border) }
                    }
                }
            }
        }
    }
}

private struct OwnerPersonRow: View {
    @ObservedObject var companion: CompanionCoordinator
    let person: CompanionPerson
    @State private var isBusy = false
    @State private var showingRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(person.nickname).font(.subheadline.weight(.semibold))
                Spacer()
                LockboxStatusBadge(title: statusTitle, color: statusColor)
            }
            Toggle("Can approve early end", isOn: Binding(
                get: { person.hasGrantedApproveEarlyEnd },
                set: { enabled in run { await companion.setOwnerGrant(.approveEarlyEnd, enabled: enabled, for: person) } }
            ))
            .tint(LockboxTheme.accent)
            .disabled(isBusy)
            Toggle("Receives my requests", isOn: Binding(
                get: { person.hasGrantedReceiveRequests },
                set: { enabled in run { await companion.setOwnerGrant(.receiveRequests, enabled: enabled, for: person) } }
            ))
            .tint(LockboxTheme.accent)
            .disabled(isBusy)
            Text(statusDetail)
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            Button("Remove", role: .destructive) { showingRemoveConfirmation = true }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                .disabled(isBusy)
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Remove \(person.nickname)?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { run { await companion.revokePairing(person) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes their pairing. They will no longer be able to approve early-end requests for you.")
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        isBusy = true
        Task { await action(); isBusy = false }
    }

    private var statusTitle: String {
        if person.isFullyTrustedForEarlyEnd { return "Trusted" }
        if person.hasGrantedApproveEarlyEnd { return "Waiting on them" }
        return "Not enabled"
    }

    private var statusColor: Color {
        person.isFullyTrustedForEarlyEnd ? LockboxTheme.focus : LockboxTheme.secondary
    }

    private var statusDetail: String {
        if person.isFullyTrustedForEarlyEnd {
            return "They can approve one exact session's early end when you ask."
        }
        if person.hasGrantedApproveEarlyEnd {
            return "You've allowed this; waiting for them to accept on their device."
        }
        return "Not asked to help with early-end requests yet."
    }
}

private struct ApproverPersonRow: View {
    @ObservedObject var companion: CompanionCoordinator
    let person: CompanionPerson
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(person.nickname).font(.subheadline.weight(.semibold))
                Spacer()
                LockboxStatusBadge(title: person.isFullyTrustedForEarlyEnd ? "Accepted" : "Pending",
                                   color: person.isFullyTrustedForEarlyEnd ? LockboxTheme.focus : LockboxTheme.secondary)
            }
            Toggle("Can approve early end", isOn: Binding(
                get: { person.hasAcceptedApproveEarlyEnd },
                set: { enabled in run { await companion.setApproverAccept(.approveEarlyEnd, enabled: enabled, for: person) } }
            ))
            .tint(LockboxTheme.accent)
            .disabled(isBusy || !person.hasGrantedApproveEarlyEnd)
            Toggle("Receives their requests", isOn: Binding(
                get: { person.hasAcceptedReceiveRequests },
                set: { enabled in run { await companion.setApproverAccept(.receiveRequests, enabled: enabled, for: person) } }
            ))
            .tint(LockboxTheme.accent)
            .disabled(isBusy || !person.hasGrantedReceiveRequests)
            Text(person.isFullyTrustedForEarlyEnd
                 ? "You can approve their exact-session early-end requests."
                 : "They've asked you to help. Accept only if you understand this only approves ending one exact current session — it never starts, extends, or controls their lock.")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func run(_ action: @escaping () async -> Void) {
        isBusy = true
        Task { await action(); isBusy = false }
    }
}

private struct AskToEndEarlyCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @State private var selected: Set<String> = []
    @State private var isSending = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Ask to end early", systemImage: "arrow.uturn.backward.circle")
                if let session = coordinator.companionActiveSessionIdentity {
                    Text("Ask a trusted person to approve ending your current lock early. This only asks about the session that's active right now.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    ForEach(companion.trustedApprovers) { person in
                        Toggle(person.nickname, isOn: Binding(
                            get: { selected.contains(person.id) },
                            set: { isOn in if isOn { selected.insert(person.id) } else { selected.remove(person.id) } }
                        ))
                        .tint(LockboxTheme.accent)
                    }
                    Button(isSending ? "Sending…" : "Ask now") {
                        let targets = companion.trustedApprovers.filter { selected.contains($0.id) }
                        isSending = true
                        Task {
                            await companion.requestEarlyEnd(sessionID: session.sessionID, activeSetID: session.activeSetID,
                                                            start: session.start, end: session.end, to: targets)
                            isSending = false
                        }
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(selected.isEmpty || isSending)
                    Text(companion.friendApprovalCanEndLocksEnabled
                         ? "Once someone approves, you can end your lock from this screen with a confirmation. It never ends automatically."
                         : "This shows an approval once someone accepts. It never ends your lock by itself in this build.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                } else if companion.trustedApprovers.isEmpty {
                    Text("Set up at least one fully trusted person above to enable this.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                } else {
                    Text("There's no single active lock right now, so there's nothing exact to ask about.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }
        }
    }
}

private struct InboxCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    LockboxSectionLabel("Inbox", systemImage: "tray")
                    Spacer()
                    if companion.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                if companion.inboxItems.isEmpty {
                    Text("Nothing here yet. Pull to refresh, or check again after asking or being asked for help.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                } else {
                    ForEach(companion.inboxItems) { item in
                        InboxRow(coordinator: coordinator, companion: companion, item: item)
                        if item.id != companion.inboxItems.last?.id { Divider().overlay(LockboxTheme.border) }
                    }
                }
            }
        }
    }
}

private struct InboxRow: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    let item: CompanionInboxItem
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.isMine ? "Your request" : title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                LockboxStatusBadge(title: item.status.rawValue.capitalized, color: color(for: item.status))
            }
            Text("Created \(item.request.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            if !item.isMine, item.status == .pending, item.myDecision == .pending {
                HStack(spacing: 10) {
                    Button("Approve") { respond(.approved) }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    Button("Decline", role: .destructive) { respond(.declined) }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                }
                .disabled(isBusy)
            }
            // R5 Slice B2c, gate on: an owner's own approved request can end
            // the lock from here. With the gate off, the row looks exactly
            // as it did in B1 — except a "Finishing…" status still shows if
            // an intent for this exact request is durably pending, since the
            // gate was necessarily on when that intent was started (review
            // P2-12: never hide in-flight work, even if the gate changed).
            if item.isMine, item.status == .approved,
               CompanionCoordinator.shouldShowFriendReleaseAction(for: item, gateEnabled: companion.friendApprovalCanEndLocksEnabled)
                || companion.friendReleaseRequestState(for: item, coordinator: coordinator) == .finishing {
                FriendReleaseActionView(coordinator: coordinator, companion: companion, item: item)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Who is asking" for a friend inbox row: the requesting owner's known
    /// nickname when this device has paired with them, otherwise a neutral
    /// fallback rather than a raw identifier.
    private var title: String {
        let name = companion.personName(forIdentityID: item.request.owner.identityID) ?? "Someone you're paired with"
        return "\(name) is asking for help"
    }

    private func respond(_ decision: CompanionKit.ApproverDecision) {
        isBusy = true
        Task { await companion.respond(item, decision: decision); isBusy = false }
    }

    private func color(for status: CompanionKit.TrustedRequestStatus) -> Color {
        switch status {
        case .approved: return LockboxTheme.focus
        case .pending: return LockboxTheme.accent
        case .declined, .cancelled, .expired: return LockboxTheme.secondary
        }
    }
}

/// R5 Slice B2c. The action/status for an owner's own approved request:
/// "End lock now" with a confirmation, "Finishing…" while the durable
/// intent for *this exact request* is pending, or a final "Used to end
/// lock"/"Lock already ended" once resolved. State is per-request (review
/// P2-6), and `.finishing` renders regardless of the developer gate (review
/// P2-12) — every other state only renders while the gate is on, since
/// `InboxRow` only instantiates this view at all when the gate is on or the
/// state is `.finishing`.
private struct FriendReleaseActionView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    let item: CompanionInboxItem
    @State private var isBusy = false
    @State private var showingConfirmation = false

    private var state: CompanionCoordinator.FriendReleaseRequestState {
        companion.friendReleaseRequestState(for: item, coordinator: coordinator)
    }

    private var approverName: String {
        guard let approval = companion.approvalsByRequestID[item.request.requestID] else { return "This person" }
        return companion.personName(forIdentityID: approval.approver.identityID) ?? "This person"
    }

    private var lockEndText: String {
        guard let end = coordinator.sessionEnd(forSessionID: item.request.sessionID) else { return "its scheduled end" }
        return end.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        switch state {
        case .finishing:
            Label("Finishing…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Finishing: ending this lock using the approval")
        case .eligible where companion.friendApprovalCanEndLocksEnabled:
            Button {
                showingConfirmation = true
            } label: {
                Label("End lock now", systemImage: "lock.open")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
            .disabled(isBusy || companion.approvalsByRequestID[item.request.requestID] == nil)
            .accessibilityHint("Ends your current lock now, using \(approverName)'s approval, after a confirmation")
            .confirmationDialog(
                "End your lock now?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("End lock now", role: .destructive) { run() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(approverName) approved ending this lock, which would otherwise run until \(lockEndText).")
            }
        case .usedToEnd where companion.friendApprovalCanEndLocksEnabled:
            Label("Used to end lock", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.focus)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
        case .alreadyEnded where companion.friendApprovalCanEndLocksEnabled:
            Label("Lock already ended", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
        default:
            EmptyView()
        }
    }

    private func run() {
        isBusy = true
        Task {
            await companion.endLockNow(item, coordinator: coordinator)
            isBusy = false
        }
    }
}
#endif

#Preview {
    NavigationStack { PeopleView(coordinator: ScreenTimeCoordinator(), companion: CompanionCoordinator()) }
}
