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
    @Environment(\.scenePhase) private var scenePhase

    /// Scroll anchor of the incoming-invite card (heading visible at the top).
    static let incomingInviteScrollID = "people.incomingInviteCard"

#if canImport(CompanionKit)
    private var incomingInviteKey: String {
        switch companion.incomingInvite {
        case .none: return "none"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    /// Opening an invite link brings its card to the top of the page so its
    /// heading is never cut off. A short wait lets the card finish laying out.
    private func scrollToIncomingInvite(_ proxy: ScrollViewProxy) {
        guard incomingInviteKey != "none" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(Self.incomingInviteScrollID, anchor: .top) }
        }
    }
#endif

    var body: some View {
#if canImport(CompanionKit)
        ScrollViewReader { proxy in
            page
                .onChange(of: incomingInviteKey) { _, _ in scrollToIncomingInvite(proxy) }
                .onAppear { scrollToIncomingInvite(proxy) }
        }
#else
        page
#endif
    }

    private var page: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "People")
            PrototypeLabelCard()

#if canImport(CompanionKit)
            if companion.isAvailable {
                // Friend side: the opened invite link, in front of the user.
                if case .none = companion.incomingInvite {} else {
                    IncomingInviteCard(companion: companion)
                        .id(Self.incomingInviteScrollID)
                }
                // Owner side: one-time, dismissable, non-blocking.
                ForEach(companion.joinedNotices) { notice in
                    JoinedNoticeCard(notice: notice) { companion.dismissJoinedNotice(id: notice.id) }
                }
                if companion.inviteStoreIsCorrupt {
                    InviteStoreResetCard(companion: companion)
                }
                // First run (nobody invited, no owner setup yet) or a link was
                // just opened: "Got an invite link?" comes before the owner copy.
                if companion.showsAcceptInviteFirst {
                    AcceptInviteCard(companion: companion)
                }
                IntroCard()
                InviteSomeoneCard(companion: companion)
                if !companion.showsAcceptInviteFirst {
                    AcceptInviteCard(companion: companion)
                }
                if coordinator.companionActiveSessionIdentity != nil || !companion.trustedApprovers.isEmpty {
                    AskToEndEarlyCard(coordinator: coordinator, companion: companion)
                }
                if !companion.trustedPeople.isEmpty || !companion.helpingPeople.isEmpty {
                    PeopleListCard(companion: companion)
                }
                if companion.hasUnverifiedOwnerPeople {
                    LockboxCard {
                        Label("Some people were added with an earlier version and can't be checked. Send them a new invite to add them again.",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("people.reinviteHint")
                    }
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
                if let notice = companion.integrityNotice {
                    LockboxCard {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("people.integrityNotice")
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
                // A bottom spacer so the last card's actionable content is
                // never left sitting directly under the translucent tab bar.
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
        // Refreshes now and then every ~5 s (invite outstanding or request
        // pending) or ~30 s, only while People is on screen and the app is
        // active: the task is cancelled when the view disappears or the
        // scene leaves `.active`, and restarts with an immediate refresh.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await companion.runAutoRefreshLoop(coordinator: coordinator)
        }
        .refreshable {
            await companion.refreshInbox()
            // Detached from the (cancellable) refresh closure; it has its
            // own single-flight guard.
            Task { await companion.replayPendingFriendRelease(coordinator: coordinator) }
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
/// Backs the "Copy link" button next to the invite `ShareLink`: a visible,
/// explicit alternative to the share sheet for a link that didn't open when
/// tapped in Messages.
@MainActor enum CompanionPasteboard {
    /// Not `.localOnly`, so Universal Clipboard can paste the link on the owner's
    /// Mac (build-22 QA). It still disappears after an hour, the invite's own lifetime.
    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [.expirationDate: now.addingTimeInterval(CompanionCoordinator.inviteLifetime)]
    }

    @MainActor static func copy(_ text: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: options())
    }
}

/// "Copy link" that visibly answers: for about two seconds it reads "Copied"
/// with a checkmark, with a light haptic and a VoiceOver announcement.
private struct CopyLinkButton: View {
    let link: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            CompanionPasteboard.copy(link)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            UIAccessibility.post(notification: .announcement, argument: "Invite link copied")
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
        .accessibilityLabel(copied ? "Copied" : "Copy link")
        .accessibilityHint("Copies the invite link to the clipboard, so you can paste it into a message")
        .accessibilityIdentifier("inviteSomeone.copyLinkButton")
        .onDisappear { resetTask?.cancel() }
    }
}
#endif

/// Owner side: the saved-invites item is damaged. Says so plainly and offers
/// the one recovery route, a confirmed reset.
private struct InviteStoreResetCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var showingConfirmation = false

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                Label(CompanionCoordinator.inviteStoreCorruptMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("people.inviteStoreCorruptMessage")
                Button("Reset saved invites", role: .destructive) { showingConfirmation = true }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    .accessibilityHint("Clears the damaged saved invites on this device")
                    .accessibilityIdentifier("people.inviteStoreResetButton")
            }
            .confirmationDialog("Reset saved invites?", isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { companion.resetUnreadableInviteStore() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Links not yet used will stop working, and people who joined earlier will need a new invite.")
            }
        }
    }
}

private struct IntroCard: View {
    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    LockboxIconBadge(systemImage: "person.2.fill", color: LockboxTheme.accent)
                    Text("Set up a trusted person")
                        .font(.title3.weight(.semibold))
                }
                Text("Send a link. When they tap Accept, they can approve ending one of your locks early, only when you ask. No account, email or code is needed. This does not use Screen Time, and app selections and usage are never shared.")
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

/// Owner side: "‹Name› joined", shown once and dismissable.
private struct JoinedNoticeCard: View {
    let notice: JoinedNotice
    let onDismiss: () -> Void

    var body: some View {
        LockboxCard {
            HStack(alignment: .top, spacing: 12) {
                LockboxIconBadge(systemImage: "person.fill.checkmark", color: LockboxTheme.focus)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(notice.name) joined")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("joinedNotice.text")
                    Text("They can now approve ending a lock early when you ask.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LockboxTheme.secondary)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("joinedNotice.dismissButton")
            }
        }
    }
}

/// Friend side: shown as soon as this device opens an invite link. Looks
/// the invite up, then asks "‹Owner› invited you to be a trusted person"
/// with Accept / Not now. Opening the link never accepts by itself.
private struct IncomingInviteCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var name = ""
    @State private var isAccepting = false

    var body: some View {
        LockboxCard {
            switch companion.incomingInvite {
            case .none:
                EmptyView()
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Opening invite…").font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("incomingInvite.loading")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 13) {
                    Label(message, systemImage: "link.badge.plus")
                        .font(.subheadline)
                        .accessibilityIdentifier("incomingInvite.message")
                    Button("OK") { companion.dismissIncomingInvite() }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                        .accessibilityIdentifier("incomingInvite.dismissButton")
                }
            case .ready(let incoming):
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) {
                        LockboxIconBadge(systemImage: "person.badge.shield.checkmark.fill", color: LockboxTheme.focus)
                        Text("\(incoming.ownerName) invited you to be a trusted person")
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("incomingInvite.title")
                    }
                    Text("Accepting lets you approve ending one of their locks early, only when they ask. You can stop at any time.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    TextField("Your name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("incomingInvite.nameField")
                    Text("\(incoming.ownerName) will see this name.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    HStack(spacing: 10) {
                        Button(isAccepting ? "Accepting…" : "Accept") {
                            isAccepting = true
                            Task {
                                await companion.acceptIncomingInvite(incoming, name: name)
                                isAccepting = false
                            }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .disabled(isAccepting || CompanionCoordinator.validatedDisplayName(name) == nil)
                        .accessibilityIdentifier("incomingInvite.acceptButton")

                        Button("Not now") { companion.dismissIncomingInvite() }
                            .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                            .disabled(isAccepting)
                            .accessibilityIdentifier("incomingInvite.notNowButton")
                    }
                }
                .onAppear { if name.isEmpty { name = companion.approverDisplayName } }
            }
        }
        // Deliberately no identifier on the card itself: it can propagate
        // down and override each child's own identifier.
    }
}

private struct InviteSomeoneCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var isCreating = false
    @State private var nameDraft = ""
    @State private var isEditingName = false

    private var needsName: Bool { companion.ownerDisplayName.isEmpty }

    /// The raw link (a bearer secret) is exposed to accessibility only in
    /// DEBUG builds, where UI tests read it; release builds expose a non-secret value.
    private static func linkAccessibilityValue(_ link: String) -> String {
        #if DEBUG
        return link
        #else
        return "Ready to share"
        #endif
    }

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Invite a trusted person", systemImage: "person.badge.plus")
                Text("Create a link and share it however you'd normally reach them (Messages, AirDrop). It works once, for one hour. Having the link never unlocks anything by itself.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)

                if needsName || isEditingName {
                    TextField("Your name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("inviteSomeone.nameField")
                    Text("They'll see this name on your invite.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    if isEditingName {
                        HStack(spacing: 10) {
                            Button("Save name") {
                                if companion.setOwnerDisplayName(nameDraft) { isEditingName = false }
                            }
                            .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                            .disabled(CompanionCoordinator.validatedDisplayName(nameDraft) == nil)
                            .accessibilityIdentifier("inviteSomeone.saveNameButton")
                            Button("Cancel") { isEditingName = false }
                                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                        }
                    }
                } else {
                    HStack {
                        Text("Invites are sent as \(companion.ownerDisplayName)")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityIdentifier("inviteSomeone.nameLabel")
                        Spacer()
                        Button("Edit") {
                            nameDraft = companion.ownerDisplayName
                            isEditingName = true
                        }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("inviteSomeone.editNameButton")
                        .accessibilityHint("Changes the name shown on new invites")
                    }
                }

                if let issued = companion.pendingInvite {
                    // The link stops being offered the moment it expires, even
                    // if nothing else on screen changes.
                    TimelineView(.explicit([issued.invitation.payload.expiresAt])) { _ in
                        inviteActions(issued: issued, expired: Date() >= issued.invitation.payload.expiresAt)
                    }
                } else {
                    inviteActions(issued: nil, expired: false)
                }
            }
        }
    }

    @ViewBuilder
    private func inviteActions(issued: IssuedInvite?, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                if needsName, !companion.setOwnerDisplayName(nameDraft) { return }
                isCreating = true
                Task { await companion.createInvite(); isCreating = false }
            } label: {
                Label(isCreating ? "Creating…" : (expired ? "Create a new invite" : "Create an invite to share"),
                      systemImage: "link.badge.plus")
            }
            .buttonStyle(LockboxActionButtonStyle(emphasis: expired ? .primary : .secondary))
            .disabled(isCreating || isEditingName || (needsName && CompanionCoordinator.validatedDisplayName(nameDraft) == nil))
            .accessibilityHint("Creates a one-use invitation link")
            .accessibilityIdentifier("inviteSomeone.createInviteButton")

            if let issued, expired {
                Label("This link expired. Create a new one.", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                    .accessibilityIdentifier("inviteSomeone.expiredNotice")
                    .accessibilityHint("The old link no longer works")
                    .id(issued.invitation.payload.inviteID)
            } else if let issued {
                // The visible text is a short line; the full link stays
                // reachable under the same identifier via the
                // accessibility *value* so UI tests can read it exactly.
                Text("Invite link ready")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LockboxTheme.secondary)
                    .accessibilityIdentifier("inviteSomeone.inviteLinkText")
                    .accessibilityLabel("Invite link ready")
                    .accessibilityValue(Self.linkAccessibilityValue(issued.shareLink))
                ShareLink(item: issued.shareLink) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                .accessibilityIdentifier("inviteSomeone.shareLinkButton")
                #if os(iOS)
                CopyLinkButton(link: issued.shareLink)
                #endif
                Text("When they tap Accept, they appear under your trusted people. There's nothing for you to confirm.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

/// Manual fallback for a link that didn't open the app when tapped.
private struct AcceptInviteCard: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var pastedInvite = ""

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Got an invite link?", systemImage: "hand.raised")
                Text("Tapping the link opens it here. If that didn't work, paste it below.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                TextField("Paste invite link", text: $pastedInvite, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("acceptInvite.pastedInviteField")
                Button("Open invite") {
                    companion.openInviteLink(pastedInvite)
                    pastedInvite = ""
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                .disabled(InviteToken.token(fromShareLink: pastedInvite) == nil)
                .accessibilityIdentifier("acceptInvite.openButton")
            }
        }
    }
}

private struct PeopleListCard: View {
    @ObservedObject var companion: CompanionCoordinator

    var body: some View {
        let owners = companion.trustedPeople
        let helping = companion.helpingPeople
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
        if !helping.isEmpty {
            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("People you're helping", systemImage: "hands.sparkles")
                    ForEach(helping) { person in
                        ApproverPersonRow(companion: companion, person: person)
                        if person.id != helping.last?.id { Divider().overlay(LockboxTheme.border) }
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
                LockboxStatusBadge(title: statusTitle, color: person.isFullyTrustedForEarlyEnd ? LockboxTheme.focus : LockboxTheme.secondary)
            }
            Text(statusDetail)
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            Button("Remove \(person.nickname)", role: .destructive) { showingRemoveConfirmation = true }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                .disabled(isBusy)
                .accessibilityIdentifier("person.removeButton")
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Remove \(person.nickname)?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                isBusy = true
                Task { await companion.revokePairing(person); isBusy = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(person.nickname) will no longer be able to approve early-end requests for you.")
        }
    }

    private var statusTitle: String {
        if person.isFullyTrustedForEarlyEnd { return "Trusted" }
        return person.consent == nil ? "Joined" : "Not active"
    }

    private var statusDetail: String {
        if person.isFullyTrustedForEarlyEnd {
            return "\(person.nickname) can approve ending one exact lock early when you ask."
        }
        if person.consent == nil {
            return "\(person.nickname) just joined. Finishing setup."
        }
        return "\(person.nickname) has stopped being a trusted person. You can remove them or send a new invite."
    }
}

private struct ApproverPersonRow: View {
    @ObservedObject var companion: CompanionCoordinator
    let person: CompanionPerson
    @State private var isBusy = false
    @State private var showingStopConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if person.approverStoppedHelping {
                Text("You stopped being a trusted person for \(person.nickname)")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("helping.statusText")
            } else {
                Text("You're a trusted person for \(person.nickname)")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("helping.statusText")
                Text("You can approve ending one exact lock early, only when \(person.nickname) asks. It never starts, extends or controls their lock.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                Button("Stop being a trusted person", role: .destructive) { showingStopConfirmation = true }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
                    .disabled(isBusy)
                    .accessibilityIdentifier("helping.stopButton")
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog("Stop being a trusted person for \(person.nickname)?",
                            isPresented: $showingStopConfirmation, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                isBusy = true
                Task { await companion.stopBeingTrustedPerson(for: person); isBusy = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(person.nickname) will no longer be able to ask you to approve ending a lock.")
        }
    }
}

private struct AskToEndEarlyCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    @State private var selected: Set<String> = []
    @State private var isSending = false

    var body: some View {
        let trusted = companion.trustedApprovers
        // Exactly one trusted person is always the selection.
        let chosen = trusted.count == 1 ? trusted : trusted.filter { selected.contains($0.id) }
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Ask to end early", systemImage: "arrow.uturn.backward.circle")
                if let session = coordinator.companionActiveSessionIdentity {
                    if trusted.isEmpty && !companion.trustedPeople.isEmpty {
                        Text("Nobody can be asked right now. Check Your trusted people below.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityIdentifier("askToEnd.noneAvailableHint")
                    } else if trusted.isEmpty {
                        Text("No one is a trusted person yet. Invite someone above; once they tap Accept, you can ask them to end this lock early.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                            .accessibilityIdentifier("askToEnd.noTrustedHint")
                    } else {
                        Text("Ask a trusted person to approve ending your current lock early. This only asks about the session that's active right now.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                        ForEach(trusted) { person in
                            personRow(person, isSelected: chosen.contains { $0.id == person.id }, interactive: trusted.count > 1)
                        }
                        Button(isSending ? "Sending…" : askTitle(chosen)) {
                            isSending = true
                            Task {
                                await companion.requestEarlyEnd(sessionID: session.sessionID, activeSetID: session.activeSetID,
                                                                start: session.start, end: session.end, to: chosen)
                                isSending = false
                            }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .disabled(chosen.isEmpty || isSending)
                        .accessibilityIdentifier("askToEnd.askButton")
                        Text(companion.friendApprovalCanEndLocksEnabled
                             ? "Once someone approves, you can end your lock from this screen with a confirmation. It never ends automatically."
                             : "This shows an approval once someone accepts. It never ends your lock by itself in this build.")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                } else {
                    Text("There's no single active lock right now, so there's nothing exact to ask about.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }
        }
    }

    private func askTitle(_ chosen: [CompanionPerson]) -> String {
        switch chosen.count {
        case 0: return "Choose who to ask"
        case 1: return "Ask \(chosen[0].nickname)"
        default: return "Ask \(chosen.count) people"
        }
    }

    @ViewBuilder
    private func personRow(_ person: CompanionPerson, isSelected: Bool, interactive: Bool) -> some View {
        let row = HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? LockboxTheme.accent : LockboxTheme.secondary)
                .accessibilityHidden(true)
            Text(person.nickname).font(.subheadline)
            Spacer()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        if interactive {
            Button {
                if isSelected { selected.remove(person.id) } else { selected.insert(person.id) }
            } label: { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("askToEnd.person.\(person.nickname)")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("askToEnd.person.\(person.nickname)")
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
                        // Owner-review follow-up (P2-8): gives
                        // `PhoneLockboxUITests` a concrete "a refresh is
                        // actually in flight right now" marker to wait on,
                        // rather than only inferring completion from a
                        // fixed timeout after the pull gesture.
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier("inboxCard.refreshingIndicator")
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
        let name = companion.personName(forIdentityID: item.request.owner.identityID) ?? "Someone"
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
