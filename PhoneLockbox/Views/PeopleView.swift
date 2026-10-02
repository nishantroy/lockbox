import SwiftUI
#if canImport(CompanionKit)
import CompanionKit
#endif
#if os(iOS)
import UIKit
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
                // R5 pairing v2 UX fix item 7, and the owner-review
                // follow-up: both placed first, directly under the
                // Prototype label, so each is visible without scrolling —
                // the incoming-invite prompt the moment a friend opens a
                // link, and a pending acceptance the moment the owner
                // learns someone accepted theirs.
                if let invitation = companion.incomingInvite {
                    IncomingInviteCard(companion: companion, invitation: invitation)
                }
                ForEach(companion.pendingOwnerAcceptances) { item in
                    PendingAcceptanceCard(companion: companion, item: item)
                }
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
            if companion.isAvailable {
                // R5 pairing v2 UX fix item 7 ("Layout"): a bottom spacer so
                // the last card's actionable content (Confirm/Not them,
                // Accept/Decline, End lock now, …) is never left sitting
                // directly under the translucent tab bar.
                Color.clear.frame(height: 24).accessibilityHidden(true)
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
        .scrollDismissesKeyboard(.interactively)
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

#if os(iOS)
/// Backs the "Copy link"/"Copy" buttons next to the invite and acceptance
/// `ShareLink`s (item d): a visible, explicit alternative to the share
/// sheet for a link that didn't open when tapped in Messages.
private func copyCompanionTextToPasteboard(_ text: String) {
    UIPasteboard.general.string = text
}
#endif

private struct IntroCard: View {
    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    LockboxIconBadge(systemImage: "person.2.fill", color: LockboxTheme.accent)
                    Text("Set up a trusted person")
                        .font(.title3.weight(.semibold))
                }
                Text("Pairing uses device-held identities — no account or email is required. When someone accepts your invite, confirm them here with one tap; there's no code to read aloud or type. This does not use Screen Time, and app selections and usage are never shared.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

/// R5 pairing v2 UX fix item 7 ("Incoming invite"): shown as soon as this
/// device opens a decodable, not-yet-expired invite link
/// (`CompanionCoordinator.incomingInvite`), directly under the page header
/// so it's in front of the friend without scrolling. Accepting still
/// requires this explicit tap — opening the link never accepts by itself.
private struct IncomingInviteCard: View {
    @ObservedObject var companion: CompanionCoordinator
    let invitation: Invitation
    @State private var isAccepting = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    LockboxIconBadge(systemImage: "person.badge.shield.checkmark.fill", color: LockboxTheme.focus)
                    Text("You've been invited to be a trusted person")
                        .font(.title3.weight(.semibold))
                }
                Text("Accepting lets you approve ending one of their locks early, only when they ask.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                HStack(spacing: 10) {
                    Button(isAccepting ? "Accepting…" : "Accept") {
                        isAccepting = true
                        Task {
                            await companion.acceptInvite(invitation)
                            isAccepting = false
                            companion.incomingInvite = nil
                        }
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(isAccepting)
                    .accessibilityIdentifier("incomingInvite.acceptButton")

                    Button("Not now") {
                        companion.incomingInvite = nil
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                    .disabled(isAccepting)
                    .accessibilityIdentifier("incomingInvite.notNowButton")
                }
            }
        }
        // Deliberately no identifier on the card itself: SwiftUI's
        // accessibility identifier can otherwise propagate down and
        // override each child's own identifier (observed empirically — the
        // buttons' own `incomingInvite.acceptButton`/`notNowButton`
        // identifiers were overwritten by a card-level one here until this
        // was removed). The two buttons above carry the identifiers tests
        // actually need.
    }
}

private struct InviteSomeoneCard: View {
    @ObservedObject var companion: CompanionCoordinator
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
                .accessibilityIdentifier("inviteSomeone.createInviteButton")

                if let invitation = companion.pendingInvitation {
                    // R5 pairing v2 UX fix item 7 ("Invite link display"):
                    // the visible text is a short, truncated line, not the
                    // raw base64 blob — but the full link stays reachable
                    // under the same accessibility identifier, via the
                    // accessibility *value* rather than the label, so the
                    // UI test can still read it exactly.
                    Text("Invite link ready")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LockboxTheme.secondary)
                        .accessibilityIdentifier("inviteSomeone.inviteLinkText")
                        .accessibilityLabel("Invite link ready")
                        .accessibilityValue(invitation.shareLink)
                    ShareLink(item: invitation.shareLink) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    #if os(iOS)
                    Button {
                        copyCompanionTextToPasteboard(invitation.shareLink)
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                    .accessibilityHint("Copies the invite link to the clipboard")
                    .accessibilityIdentifier("inviteSomeone.copyLinkButton")
                    #endif
                    Text("Once they accept, you'll see a card below to confirm them — no code to type or read aloud.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }
        }
    }
}

/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", item 2): one
/// verified, relay-delivered acceptance of an invite this device created.
/// Only ever instantiated for an entry in `companion.pendingOwnerAcceptances`
/// — a `VerifiedPendingAcceptance` already checked with `OwnerAcceptanceCheck`
/// against this device's own stored invite.
private struct PendingAcceptanceCard: View {
    @ObservedObject var companion: CompanionCoordinator
    let item: VerifiedPendingAcceptance
    @State private var nickname = ""
    /// Owner-review follow-up (2026-10-02): on by default. If still on when
    /// Confirm is tapped, `confirmPendingAcceptance` grants this device's
    /// own `approveEarlyEnd`/`receiveRequests` scopes immediately after the
    /// pairing confirms — the same grant the person row's own toggles
    /// perform, just without an extra trip back to this screen. The friend
    /// still has to accept those scopes themselves (consent stays
    /// bilateral); this never grants anything on their behalf.
    @State private var grantEarlyEndTrust = true
    @State private var isBusy = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Someone accepted your invite", systemImage: "person.fill.checkmark")
                Text("Sent \(item.acceptance.issuedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                TextField("Name for this person", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pendingAcceptance.nameField")
                Toggle("Let them approve ending my locks early", isOn: $grantEarlyEndTrust)
                    .tint(LockboxTheme.accent)
                    .accessibilityIdentifier("pendingAcceptance.grantEarlyEndToggle")
                HStack(spacing: 10) {
                    Button(isBusy ? "Confirming…" : "Confirm") {
                        isBusy = true
                        Task {
                            await companion.confirmPendingAcceptance(item, nickname: nickname, grantEarlyEndTrust: grantEarlyEndTrust)
                            isBusy = false
                        }
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(isBusy)
                    .accessibilityHint("Confirms this person as a trusted approver")
                    .accessibilityIdentifier("pendingAcceptance.confirmButton")

                    Button("Not them", role: .destructive) {
                        companion.dismissPendingAcceptance(item)
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    .disabled(isBusy)
                    .accessibilityIdentifier("pendingAcceptance.notThemButton")
                }
            }
        }
        // Deliberately no identifier on the card itself — see the matching
        // comment on `IncomingInviteCard`: it overwrote this card's own
        // buttons'/field's identifiers when present.
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
                    .accessibilityIdentifier("acceptInvite.pastedInviteField")
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

                if companion.pendingAcceptance != nil {
                    // R5 pairing v2 (Slice P2b, item 5): the friend never
                    // types or shares anything back — the owner's device
                    // confirms from the relay-delivered acceptance alone.
                    // The owner's name isn't known to this device, hence
                    // "the person who invited you" rather than a name.
                    //
                    // Deliberately a plain `Text`, not a `Label` — a plain
                    // `Text` registers as a `staticText` accessibility
                    // element with no further composition, which is what
                    // `PhoneLockboxUITests` queries by this identifier.
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityHidden(true)
                        Text("Waiting for the person who invited you to confirm")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityIdentifier("acceptInvite.waitingLabel")
                    }
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

    /// Owner-review follow-up (2026-10-02): names the person once this
    /// device has granted its own side (whether from the person row's own
    /// toggles, or from the pending-acceptance card's "Let them approve
    /// ending my locks early" toggle at confirm time) — reusing the same
    /// `hasGrantedApproveEarlyEnd`/`isFullyTrustedForEarlyEnd` state either
    /// path already produces, not a new tracking mechanism. Still names
    /// only the *owner's own* grant; the friend's acceptance remains a
    /// separate, bilateral step this device cannot see or perform for them.
    private var statusDetail: String {
        if person.isFullyTrustedForEarlyEnd {
            return "They can approve one exact session's early end when you ask."
        }
        if person.hasGrantedApproveEarlyEnd {
            return "Waiting for \(person.nickname) to agree before they can approve early ends."
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
