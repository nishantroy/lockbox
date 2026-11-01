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
    /// True once the first inbox load of this launch has been absorbed.
    @State private var loadedBefore = false

    /// Scroll anchor of the incoming-invite card (heading visible at the top).
    static let incomingInviteScrollID = "people.incomingInviteCard"
    /// Scroll anchor of the newest "‹Name› joined" notice.
    static let joinedNoticeScrollID = "people.joinedNotice"
    /// Scroll anchor of the friend's "You're now a trusted person" notice.
    static let acceptedNoticeScrollID = "people.acceptedNotice"
    /// Scroll anchor of the "Waiting for you" card.
    static let waitingScrollID = "people.waitingForYou"

#if canImport(CompanionKit)
    /// A link is loading or ready to accept. A failed link doesn't count: the
    /// owner name field and the paste card come back, so Create is never
    /// left disabled without its name field (UX re-check P2-A).
    private var incomingLinkIsOpen: Bool {
        switch companion.incomingInvite {
        case .loading, .ready: return true
        case .none, .failed: return false
        }
    }

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

    /// A new "‹Name› joined" notice is brought into view: the owner is usually
    /// scrolled down at the invite card when the friend accepts (pre-push UI
    /// run, 2026-10-31: the notice appeared off-screen above).
    private func scrollToJoinedNotice(_ proxy: ScrollViewProxy) {
        guard !companion.joinedNotices.isEmpty, incomingInviteKey == "none" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(Self.joinedNoticeScrollID, anchor: .top) }
        }
    }

    private func scrollToAcceptedNotice(_ proxy: ScrollViewProxy) {
        guard !companion.acceptedNotices.isEmpty, incomingInviteKey == "none" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(Self.acceptedNoticeScrollID, anchor: .top) }
        }
    }

    /// A request that needs the user is brought into view the moment it arrives.
    private func scrollToWaiting(_ proxy: ScrollViewProxy) {
        // The incoming-invite card stays at the top while it is open.
        guard incomingInviteKey == "none" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(Self.waitingScrollID, anchor: .top) }
        }
    }
#endif

    var body: some View {
#if canImport(CompanionKit)
        ScrollViewReader { proxy in
            page
                .onChange(of: incomingInviteKey) { _, _ in scrollToIncomingInvite(proxy) }
                .onAppear { loadedBefore = companion.hasLoadedInbox; scrollToIncomingInvite(proxy) }
                .onChange(of: companion.joinedNotices.map(\.id)) { old, new in
                    if new.contains(where: { !old.contains($0) }) { scrollToJoinedNotice(proxy) }
                }
                .onChange(of: companion.acceptedNotices.map(\.id)) { old, new in
                    if new.contains(where: { !old.contains($0) }) { scrollToAcceptedNotice(proxy) }
                }
                .onChange(of: companion.waitingItems(coordinator: coordinator).map(\.id)) { old, new in
                    // Items already waiting at launch (the first inbox load)
                    // are not new: only ones that appear after it scroll.
                    guard loadedBefore else { return }
                    if new.contains(where: { !old.contains($0) }) { scrollToWaiting(proxy) }
                }
                .onChange(of: companion.hasLoadedInbox) { _, loaded in
                    // Set after the waiting-ids change of the same update has run.
                    Task { @MainActor in loadedBefore = loaded }
                }
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
                // One-time, dismissable, non-blocking notices.
                ForEach(Array(companion.joinedNotices.enumerated()), id: \.element.id) { index, notice in
                    DismissibleNoticeCard(title: "\(notice.name) joined",
                                          detail: "They can now approve ending a lock early when you ask.",
                                          titleIdentifier: "joinedNotice.text",
                                          dismissIdentifier: "joinedNotice.dismissButton") {
                        companion.dismissJoinedNotice(id: notice.id)
                    }
                    .id(index == 0 ? Self.joinedNoticeScrollID : "people.joinedNotice.\(notice.id)")
                }
                ForEach(Array(companion.acceptedNotices.enumerated()), id: \.element.id) { index, notice in
                    DismissibleNoticeCard(title: "You're now a trusted person for \(notice.ownerName)",
                                          detail: "\(notice.ownerName) can ask you to approve ending a lock early. You'll see requests here.",
                                          titleIdentifier: "acceptedNotice.text",
                                          dismissIdentifier: "acceptedNotice.dismissButton") {
                        companion.dismissAcceptedNotice(id: notice.id)
                    }
                    .id(index == 0 ? Self.acceptedNoticeScrollID : "people.acceptedNotice.\(notice.id)")
                }
                // Only what needs the user now; everything else is Inbox history.
                let waiting = companion.waitingItems(coordinator: coordinator)
                if !waiting.isEmpty {
                    WaitingForYouCard(coordinator: coordinator, companion: companion, items: waiting)
                        .id(Self.waitingScrollID)
                }
                if coordinator.companionActiveSessionIdentity != nil {
                    AskToEndEarlyCard(coordinator: coordinator, companion: companion)
                }
                if !companion.trustedPeople.isEmpty || !companion.helpingPeople.isEmpty {
                    PeopleListCard(companion: companion)
                }
                if NotificationsOffRow.isVisible(permission: companion.notificationPermission,
                                                 pairingCount: companion.trustedPeople.count + companion.helpingPeople.count) {
                    NotificationsOffRowView()
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
                if companion.inviteStoreIsCorrupt, companion.ownerIdentity != nil {
                    InviteStoreResetCard(companion: companion)
                }
                // First run (nobody invited or paired) or a link was just
                // opened: "Got an invite link?" comes before the owner invite.
                // While an opened link is on screen only its own card asks for
                // a name, and an unrelated paste can't replace it.
                let linkOpen = incomingLinkIsOpen
                if companion.showsAcceptInviteFirst, !linkOpen {
                    AcceptInviteCard(companion: companion)
                }
                InviteSomeoneCard(companion: companion, hidesNameField: linkOpen)
                if !companion.showsAcceptInviteFirst, !linkOpen {
                    AcceptInviteCard(companion: companion)
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
            await companion.peopleTabAppeared()
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

#if canImport(CompanionKit)
/// One quiet row shown only when notifications are denied and the person has
/// at least one pairing. Without notifications they still see everything by
/// opening People; this just explains why nothing taps them on the shoulder.
private struct NotificationsOffRowView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(NotificationsOffRow.message, systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("people.notificationsOff.text")
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                .accessibilityLabel("Open Settings to turn notifications on")
                .accessibilityIdentifier("people.notificationsOff.openSettingsButton")
                #endif
            }
            .accessibilityElement(children: .contain)
        }
    }
}
#endif

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
    /// Mac (build-22 QA). It disappears when the invite itself expires.
    static func options(expiresAt: Date) -> [UIPasteboard.OptionsKey: Any] {
        [.expirationDate: expiresAt]
    }

    @MainActor static func copy(_ text: String, expiresAt: Date) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: options(expiresAt: expiresAt))
    }
}

/// "Copy link" that visibly answers: for about two seconds it reads "Copied"
/// with a checkmark, with a light haptic and a VoiceOver announcement.
private struct CopyLinkButton: View {
    let link: String
    let expiresAt: Date
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            CompanionPasteboard.copy(link, expiresAt: expiresAt)
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
            Label {
                Text(copied ? "Copied" : "Copy link")
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
        .animation(.snappy, value: copied)
        .accessibilityLabel(copied ? "Link copied" : "Copy link")
        .accessibilityHint("Copies the invite link to the clipboard, so you can paste it into a message")
        .accessibilityIdentifier("inviteSomeone.copyLinkButton")
        .onDisappear { resetTask?.cancel(); copied = false }
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

/// A one-time, dismissable notice ("‹Name› joined" for the owner, "You're now
/// a trusted person" for the friend).
private struct DismissibleNoticeCard: View {
    let title: String
    let detail: String
    let titleIdentifier: String
    let dismissIdentifier: String
    let onDismiss: () -> Void

    var body: some View {
        LockboxCard {
            HStack(alignment: .top, spacing: 12) {
                LockboxIconBadge(systemImage: "person.fill.checkmark", color: LockboxTheme.focus)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier(titleIdentifier)
                    Text(detail)
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
                .accessibilityIdentifier(dismissIdentifier)
            }
        }
    }
}

/// The user's name, asked for once inside whichever card is in use.
private struct InlineNameField: View {
    @Binding var text: String
    let footnote: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Your name", text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityLabel("Your name")
                .accessibilityIdentifier(identifier)
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
        }
    }
}

/// Two buttons side by side, stacking at accessibility text sizes.
private struct AdaptiveButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(spacing: 10) { content }
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

    /// No name saved yet: ask once, inline. Otherwise Accept uses the saved name.
    private var needsName: Bool { companion.displayName.isEmpty }

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
                    Label(message, systemImage: "exclamationmark.circle")
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
                    if needsName {
                        InlineNameField(text: $name,
                                        footnote: "\(incoming.ownerName) will see this name. You can change it in Settings.",
                                        identifier: "incomingInvite.nameField")
                    }
                    AdaptiveButtonRow {
                        Button(isAccepting ? "Accepting…" : "Accept") {
                            isAccepting = true
                            let chosen = needsName ? name : companion.displayName
                            Task {
                                await companion.acceptIncomingInvite(incoming, name: chosen)
                                isAccepting = false
                            }
                        }
                        .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                        .disabled(isAccepting || (needsName && CompanionCoordinator.validatedDisplayName(name) == nil))
                        .accessibilityHint(needsName ? "Enter your name first" : "Becomes a trusted person for \(incoming.ownerName)")
                        .accessibilityIdentifier("incomingInvite.acceptButton")

                        Button("Not now") { companion.dismissIncomingInvite() }
                            .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                            .disabled(isAccepting)
                            .accessibilityIdentifier("incomingInvite.notNowButton")
                    }
                }
            }
        }
        // Deliberately no identifier on the card itself: it can propagate
        // down and override each child's own identifier.
    }
}

private struct InviteSomeoneCard: View {
    @ObservedObject var companion: CompanionCoordinator
    var hidesNameField = false
    @State private var isCreating = false
    @State private var nameDraft = ""

    private var needsName: Bool { companion.displayName.isEmpty }
    private var isFirstRun: Bool { companion.trustedPeople.isEmpty }

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
                if isFirstRun {
                    HStack(spacing: 12) {
                        LockboxIconBadge(systemImage: "person.2.fill", color: LockboxTheme.accent)
                        Text("Set up a trusted person")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text("Send a link to someone you trust. Once they accept, they can approve ending a lock early, only when you ask. Your apps and usage are never shared.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                } else {
                    LockboxSectionLabel("Invite a trusted person", systemImage: "person.badge.plus")
                }

                if needsName && !companion.inviteStoreIsCorrupt && !hidesNameField {
                    InlineNameField(text: $nameDraft,
                                    footnote: "People you invite will see this name. You can change it in Settings.",
                                    identifier: "inviteSomeone.nameField")
                }

                if let issued = companion.pendingInvite {
                    // The link stops being offered the moment it expires, even
                    // if nothing else on screen changes.
                    // Judge expiry by the real clock only: for a future
                    // `.explicit` entry SwiftUI may hand the first render that
                    // entry's (future) date, which made a fresh link look
                    // expired (pre-push UI run, 2026-10-31). The second entry
                    // covers an update delivered slightly early.
                    let expiresAt = issued.invitation.payload.expiresAt
                    TimelineView(.explicit([expiresAt, expiresAt.addingTimeInterval(1)])) { _ in
                        inviteActions(issued: issued, expired: Date() >= expiresAt)
                    }
                } else {
                    inviteActions(issued: nil, expired: false)
                }
            }
        }
    }

    private func create() {
        if needsName, !companion.setDisplayName(nameDraft) { return }
        isCreating = true
        Task { await companion.createInvite(); isCreating = false }
    }

    @ViewBuilder
    private func inviteActions(issued: IssuedInvite?, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if let issued, !expired {
                ShareLink(item: issued.shareLink) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                .accessibilityIdentifier("inviteSomeone.shareLinkButton")
                #if os(iOS)
                CopyLinkButton(link: issued.shareLink, expiresAt: issued.invitation.payload.expiresAt)
                    .id(issued.invitation.payload.inviteID)
                #endif
                // The full link stays reachable under this identifier via the
                // accessibility *value* so UI tests can read it exactly.
                Text("The link works once, for one hour.")
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                    .accessibilityIdentifier("inviteSomeone.inviteLinkText")
                    .accessibilityValue(Self.linkAccessibilityValue(issued.shareLink))
                Button(isCreating ? "Creating…" : "Make a new link") { create() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LockboxTheme.accent)
                    .frame(minHeight: 44)
                    .disabled(isCreating)
                    .accessibilityHint("Creates another one-use invitation link")
                    .accessibilityIdentifier("inviteSomeone.createInviteButton")
            } else if !companion.inviteStoreIsCorrupt {
                if let issued, expired {
                    Label("This link expired. Create a new one.", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                        .accessibilityIdentifier("inviteSomeone.expiredNotice")
                        .accessibilityHint("The old link no longer works")
                        .id(issued.invitation.payload.inviteID)
                }
                Button {
                    create()
                } label: {
                    Label(isCreating ? "Creating…" : (expired ? "Create a new invite" : "Create invite link"),
                          systemImage: "link.badge.plus")
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                .disabled(isCreating || (needsName && CompanionCoordinator.validatedDisplayName(nameDraft) == nil))
                .accessibilityHint(needsName ? "Enter your name first, then creates a one-use invitation link"
                                             : "Creates a one-use invitation link")
                .accessibilityIdentifier("inviteSomeone.createInviteButton")
            }
        }
    }
}

/// Fallback for a link that didn't open the app when tapped. `PasteButton`
/// reads the clipboard only on the user's tap, with no system prompt.
private struct AcceptInviteCard: View {
    @ObservedObject var companion: CompanionCoordinator

    private var hasPeople: Bool { !companion.trustedPeople.isEmpty || !companion.helpingPeople.isEmpty }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in _ = companion.openInviteLink(text) }
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Paste invite link")
        .accessibilityHint("Opens the invite link on your clipboard")
        .accessibilityIdentifier("acceptInvite.pasteButton")
    }

    var body: some View {
        LockboxCard {
            if hasPeople {
                // Compact once the user is set up: a single row.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label("Got an invite link?", systemImage: "hand.raised")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        pasteButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Got an invite link?", systemImage: "hand.raised")
                            .font(.subheadline.weight(.semibold))
                        pasteButton
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    LockboxSectionLabel("Got an invite link?", systemImage: "hand.raised")
                    Text("Tapping the link opens it here. If it didn't, paste it.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    pasteButton
                }
            }
        }
    }
}

/// Requests that need the user right now. History stays in the Inbox.
private struct WaitingForYouCard: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    @ObservedObject var companion: CompanionCoordinator
    let items: [CompanionInboxItem]

    var body: some View {
        LockboxCard {
            VStack(alignment: .leading, spacing: 13) {
                LockboxSectionLabel("Waiting for you", systemImage: "bell.badge")
                ForEach(items) { item in
                    InboxRow(coordinator: coordinator, companion: companion, item: item)
                    if item.id != items.last?.id { Divider().overlay(LockboxTheme.border) }
                }
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
                        Text("None of your trusted people can be asked right now. Their status is shown below; you can send a new invite from there.")
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
        // When everything in the Inbox is already in "Waiting for you", the
        // empty history card would only repeat itself.
        if !(companion.historyItems(coordinator: coordinator).isEmpty && !companion.waitingItems(coordinator: coordinator).isEmpty) {
            card
        }
    }

    private var card: some View {
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
                let history = companion.historyItems(coordinator: coordinator)
                if history.isEmpty {
                    Text("Nothing here yet. Requests appear here automatically.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                } else {
                    ForEach(history) { item in
                        InboxRow(coordinator: coordinator, companion: companion, item: item)
                        if item.id != history.last?.id { Divider().overlay(LockboxTheme.border) }
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
                LockboxStatusBadge(title: CompanionCoordinator.statusBadgeTitle(item.status), color: color(for: item.status))
            }
            Text("Created \(item.request.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
            if !item.isMine, item.status == .pending, item.myDecision == .pending {
                AdaptiveButtonRow {
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
