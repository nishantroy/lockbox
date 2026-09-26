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
            IntroCard()
            InviteSomeoneCard(companion: companion)
            AcceptInviteCard(companion: companion)
            if coordinator.companionActiveSessionIdentity != nil || !companion.trustedApprovers.isEmpty {
                AskToEndEarlyCard(coordinator: coordinator, companion: companion)
            }
            if !companion.people.isEmpty {
                PeopleListCard(companion: companion)
            }
            InboxCard(companion: companion)
            if let error = companion.lastError {
                LockboxCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
        .task { await companion.refreshInbox() }
        .refreshable { await companion.refreshInbox() }
#endif
    }
}

private struct PrototypeLabelCard: View {
    var body: some View {
        LockboxCard {
            HStack(spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.orange)
                Text("Prototype — local relay")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Prototype, using a local relay only")
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
                    Text("A trusted person can help you recover")
                        .font(.title3.weight(.semibold))
                }
                Text("Pairing uses device-held identities confirmed with a six-digit code — no account or email is required. This does not use Screen Time, and app selections and usage are never shared.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

private struct InviteSomeoneCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var pastedAcceptance = ""
    @State private var nickname = ""
    @State private var isCreating = false

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

                Text("Once they accept, they'll send back an acceptance code. Paste it here and compare the six digits with what they see before confirming.")
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
                        LockboxValueRow(label: "Code", value: acceptance.verificationCode)
                        TextField("Name for this person", text: $nickname)
                            .textFieldStyle(.roundedBorder)
                        Button("This matches — confirm") {
                            Task {
                                await companion.confirmAcceptance(acceptance, nickname: nickname)
                                pastedAcceptance = ""
                                nickname = ""
                            }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .accessibilityHint("Confirms this person as a trusted approver after you've verified the code matches")
                    }
                }
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
                        Text("Show them this code, or share the text below, so they can confirm it matches before pairing completes.")
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

    private var owners: [CompanionPerson] { companion.people.filter { $0.localRole == .iAmOwner } }
    private var approving: [CompanionPerson] { companion.people.filter { $0.localRole == .iAmApprover } }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(person.nickname).font(.subheadline.weight(.semibold))
                Spacer()
                LockboxStatusBadge(title: statusTitle, color: statusColor)
            }
            Text(statusDetail)
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            HStack(spacing: 10) {
                if person.hasGrantedApproveEarlyEnd {
                    Button("Turn off", role: .destructive) { run { await companion.revokeEarlyEndTrust(person) } }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                } else {
                    Button("Allow early-end requests") { run { await companion.grantEarlyEndTrust(person) } }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                }
                Button("Remove", role: .destructive) { run { await companion.revokePairing(person) } }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
            }
            .disabled(isBusy)
        }
        .accessibilityElement(children: .contain)
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
                LockboxStatusBadge(title: person.hasAcceptedApproveEarlyEnd ? "Accepted" : "Pending",
                                   color: person.hasAcceptedApproveEarlyEnd ? LockboxTheme.focus : LockboxTheme.secondary)
            }
            Text(person.hasAcceptedApproveEarlyEnd
                 ? "You can approve their exact-session early-end requests."
                 : "They've asked you to help. Accept only if you understand this only approves ending one exact current session.")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            HStack(spacing: 10) {
                if person.hasAcceptedApproveEarlyEnd {
                    Button("Turn off", role: .destructive) { run { await companion.revokeEarlyEndTrust(person) } }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                } else {
                    Button("Accept") { run { await companion.acceptEarlyEndTrust(person) } }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                }
            }
            .disabled(isBusy)
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
                    Text("This shows an approval once someone accepts. It never ends your lock by itself in this build.")
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
                        InboxRow(companion: companion, item: item)
                        if item.id != companion.inboxItems.last?.id { Divider().overlay(LockboxTheme.border) }
                    }
                }
            }
        }
    }
}

private struct InboxRow: View {
    @ObservedObject var companion: CompanionCoordinator
    let item: CompanionInboxItem
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.isMine ? "Your request" : "Request for your help")
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
        }
        .accessibilityElement(children: .contain)
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
#endif

#Preview {
    NavigationStack { PeopleView(coordinator: ScreenTimeCoordinator(), companion: CompanionCoordinator()) }
}
