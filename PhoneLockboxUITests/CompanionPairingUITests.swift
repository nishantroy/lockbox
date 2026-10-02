import XCTest
import CompanionKit

/// End-to-end UI coverage for the owner's two reported pairing problems
/// (owner QA on a device, 2026-10-02):
///
/// 1. The invite link did nothing when tapped because `project.yml` only
///    registered `phonelockbox`, not `phone-lockbox-companion`
///    (`CompanionKit.Invitation.shareLink`'s scheme). Fixed by registering
///    the scheme in `project.yml` and adding `ContentView.onOpenURL`
///    routing (`CompanionCoordinator.handleIncomingCompanionLink`).
/// 2. There was no way to get the raw link text off the device other than
///    the system share sheet. Fixed by adding a visible "Copy link" button
///    next to the invite `ShareLink` (`PeopleView.InviteSomeoneCard`).
///
/// The first test reads the invite link from a visible, selectable `Text`
/// in the app's own UI (`inviteSomeone.inviteLinkText`) rather than the
/// system pasteboard: a cross-app pasteboard *read* (this test process is
/// a different app from `com.phone-lockbox.app`) triggers iOS's "Allow
/// Paste" confirmation, which an automated run cannot answer and which is
/// reliably denied (`PBErrorDomain` code 13). The "Copy link" button is
/// still tapped (exercising the pasteboard write), just not read back.
///
/// This target runs against a local relay (`relay/`, `npm run dev`,
/// `http://127.0.0.1:8002`); the app is launched with a `-relayBaseURL`
/// launch argument read only in DEBUG builds
/// (`CompanionCoordinator.relayBaseURLLaunchArgumentOverride`), so no
/// Developer-settings UI interaction is needed to point it at the local
/// relay.
///
/// Per the owner's 2026-10-02 scope change, this does not exercise the
/// six-digit verification-code field or its keyboard; that is covered
/// separately. Both tests here act as "the friend" in-process, mirroring
/// `tools/relay-smoke`, rather than driving a second simulator.
///
/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b") replaced the
/// typed six-digit code with a relay-delivered, locally verified acceptance
/// and one-tap Confirm/Not them. The tests below cover that flow end to
/// end — `testOwnerConfirmsAPendingAcceptanceAndThePersonShowsAsPaired` and
/// `testOwnerDismissesAPendingAcceptanceAsNotThem` script "the friend" over
/// HTTP exactly as `testCreateInviteCopyLinkAndFriendAcceptsOverRelay` does,
/// then drive the owner side's new pending-acceptance card —
/// and `testOpeningScriptedInviteLinkShowsIncomingInvitePromptThenWaitingState`
/// (renamed from an earlier version that asserted a prefilled paste field,
/// since UX fix item 7 replaced that with a top-of-page prompt) covers the
/// friend side: opening an invite link now shows an "accept in front of the
/// user" prompt rather than silently prefilling a field below the fold.
@MainActor
final class CompanionPairingUITests: XCTestCase {
    private static let localRelayBaseURLString = "http://127.0.0.1:8002"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-relayBaseURL", Self.localRelayBaseURLString,
            // Makes each test independent of whatever a previous run (or
            // another process sharing the same local relay's Postgres)
            // left behind: a fresh owner/approver identity and a clean
            // rollback anchor every launch, rather than one that can
            // legitimately — but unhelpfully, for a test — trip
            // `CompanionError.relayRollback` against stale local state.
            // DEBUG-only; see `CompanionCoordinator.resetCompanionStateForUITests`.
            "-resetCompanionStateForUITests",
        ]
        app.launch()
        self.app = app
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Create an invite in the app, read its link text directly from the
    /// app's own UI (`inviteSomeone.inviteLinkText`, a selectable `Text`
    /// showing `invitation.shareLink`), decode it exactly as a friend's
    /// device would (`Invitation.fromShareLink`), and have a fresh,
    /// in-memory-only friend identity accept it over HTTP against the local
    /// relay — mirroring `tools/relay-smoke`'s "owner creates an invite" /
    /// "helper accepts the invite" steps. Also taps "Copy link" (exercising
    /// the `UIPasteboard` write), but deliberately does not assert the
    /// pasteboard's contents: reading the system pasteboard back from this
    /// test's own process is a *different app* (the XCTest runner) from the
    /// one that wrote it (`com.phone-lockbox.app`), which triggers iOS's
    /// "Allow Paste" cross-app confirmation — unanswerable, and reliably
    /// denied (`PBErrorDomain` code 13, "Operation not authorized"), in an
    /// automated run. Reading the link from the app's own accessibility
    /// tree instead sidesteps that entirely.
    func testCreateInviteCopyLinkAndFriendAcceptsOverRelay() async throws {
        guard navigateToPeopleTab() else {
            XCTFail("'People' tab never stayed selected")
            return
        }

        // Generous timeouts: creating an invite is a real signed network
        // round trip to the relay, and `continueAfterFailure = false` does
        // not reliably hard-stop an `async throws` test method on a failed
        // `XCTAssert*` — so each wait below explicitly `return`s on failure
        // rather than falling through to tap a button that was never found.
        let createButton = app.buttons["inviteSomeone.createInviteButton"]
        guard createButton.waitForExistence(timeout: 30) else {
            XCTFail("'Create an invite to share' button never appeared")
            return
        }
        createButton.tap()

        let linkTextElement = app.staticTexts["inviteSomeone.inviteLinkText"]
        guard linkTextElement.waitForExistence(timeout: 30) else {
            XCTFail("invite link text never appeared after creating an invite")
            return
        }
        let copyButton = app.buttons["inviteSomeone.copyLinkButton"]
        guard copyButton.waitForExistence(timeout: 5) else {
            XCTFail("'Copy link' button never appeared alongside the invite link text")
            return
        }
        attachScreenshot(named: "01-invite-created-copy-link-visible")

        // R5 pairing v2 UX fix item 7 ("Invite link display"): the visible
        // label is now a short, truncated line ("Invite link ready"), not
        // the raw link — the full value lives in the accessibility *value*
        // instead, so this reads `.value`, not `.label`.
        let linkText = (linkTextElement.value as? String) ?? ""
        XCTAssertTrue(linkText.hasPrefix("\(CompanionCoordinatorScheme.companionLinkScheme)://invite/"),
                      "Invite link text does not look like an invite link: \(linkText)")

        // Still exercises the Copy button's pasteboard write (item d); its
        // *contents* are deliberately not asserted here — see the doc
        // comment above.
        copyButton.tap()

        let invitation = try Invitation.fromShareLink(linkText)

        // Act as the friend in this test process: a fresh, throwaway,
        // in-memory-only identity — nothing here touches the app's own
        // Keychain/App Group storage.
        let friendKeyStore = InMemoryDeviceKeyStore()
        let friendSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: friendKeyStore)
        let transport = HTTPCompanionTransport(baseURL: try localRelayURL(), session: URLSession(configuration: .ephemeral))
        let friendClient = AsyncCompanionClient(signer: friendSigner, transport: transport)

        let acceptance = try await friendClient.accept(invitation, acceptanceID: UUID().uuidString, now: Date())

        XCTAssertEqual(acceptance.verificationCode.count, 6, "acceptance verification code should be six digits")
        XCTAssertTrue(acceptance.verificationCode.allSatisfy(\.isNumber), "acceptance verification code should be all digits")
        XCTAssertEqual(acceptance.inviteID, invitation.payload.inviteID)
    }

    /// R5 pairing v2 (Slice P2b) end-to-end owner flow: create an invite in
    /// the app, have a scripted friend accept it over HTTP (mirroring the
    /// test above), pull to refresh, and confirm the resulting
    /// "Someone accepted your invite" card with a name. The person must then
    /// show up as paired, and the card itself must be gone.
    func testOwnerConfirmsAPendingAcceptanceAndThePersonShowsAsPaired() async throws {
        guard navigateToPeopleTab() else {
            XCTFail("'People' tab never stayed selected")
            return
        }

        let invitation = try await createInviteInAppAndReadLink()

        let friendKeyStore = InMemoryDeviceKeyStore()
        let friendSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: friendKeyStore)
        let transport = HTTPCompanionTransport(baseURL: try localRelayURL(), session: URLSession(configuration: .ephemeral))
        let friendClient = AsyncCompanionClient(signer: friendSigner, transport: transport)
        _ = try await friendClient.accept(invitation, acceptanceID: UUID().uuidString, now: Date())

        let confirmButton = app.buttons["pendingAcceptance.confirmButton"]
        guard waitForElementAfterRepeatedRefresh(confirmButton) else {
            XCTFail("'Someone accepted your invite' card never appeared after the friend accepted and a refresh")
            return
        }
        // Owner-review follow-up: the pending-acceptance card is placed
        // directly under the Prototype label (same priority as the
        // incoming-invite prompt), so it must be visible without scrolling —
        // not merely present in the hierarchy.
        XCTAssertTrue(confirmButton.isHittable, "the pending-acceptance card's Confirm button must be visible without scrolling")
        attachScreenshot(named: "04-pending-acceptance-card-visible")

        let nameField = app.textFields["pendingAcceptance.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Ari")

        // "Let them approve ending my locks early" defaults on; leave it
        // alone so Confirm exercises the owner-side grant-at-confirm path.
        let grantToggle = app.switches["pendingAcceptance.grantEarlyEndToggle"]
        XCTAssertTrue(grantToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(grantToggle.value as? String, "1", "the early-end grant toggle should default on")

        confirmButton.tap()

        let pairedName = app.staticTexts["Ari"]
        XCTAssertTrue(pairedName.waitForExistence(timeout: 30), "confirmed person 'Ari' never appeared in 'Your trusted people'")

        // Owner-review follow-up: confirming with the toggle left on must
        // immediately grant this device's own early-end scopes — surfaced
        // as the person row's "waiting on the friend" state, which is only
        // reachable once `hasGrantedApproveEarlyEnd` is true. The friend
        // still has to accept separately (consent stays bilateral), so this
        // is the furthest state reachable from the owner side alone.
        let waitingForFriend = app.staticTexts["Waiting for Ari to agree before they can approve early ends."]
        XCTAssertTrue(waitingForFriend.waitForExistence(timeout: 15),
                      "the owner-side grant-at-confirm never took effect — person row should read 'Waiting for Ari to agree…'")
        attachScreenshot(named: "05-person-confirmed-as-paired")

        // The card is removed immediately on a successful confirm — not
        // merely until the next refresh.
        XCTAssertFalse(confirmButton.exists, "the pending-acceptance card should be gone once confirmed")
    }

    /// R5 pairing v2 (Slice P2b): the **Not them** case. The card must
    /// disappear immediately, and the underlying invite is discarded so
    /// nothing can confirm from it afterward (there is no relay cancel-
    /// invite endpoint in this protocol version — see
    /// `CompanionCoordinator.discardStoredInvite`'s doc comment).
    func testOwnerDismissesAPendingAcceptanceAsNotThem() async throws {
        guard navigateToPeopleTab() else {
            XCTFail("'People' tab never stayed selected")
            return
        }

        let invitation = try await createInviteInAppAndReadLink()

        let friendKeyStore = InMemoryDeviceKeyStore()
        let friendSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: friendKeyStore)
        let transport = HTTPCompanionTransport(baseURL: try localRelayURL(), session: URLSession(configuration: .ephemeral))
        let friendClient = AsyncCompanionClient(signer: friendSigner, transport: transport)
        _ = try await friendClient.accept(invitation, acceptanceID: UUID().uuidString, now: Date())

        let notThemButton = app.buttons["pendingAcceptance.notThemButton"]
        guard waitForElementAfterRepeatedRefresh(notThemButton) else {
            XCTFail("'Someone accepted your invite' card never appeared after the friend accepted and a refresh")
            return
        }
        XCTAssertTrue(notThemButton.isHittable, "the pending-acceptance card's Not them button must be visible without scrolling")
        attachScreenshot(named: "06-pending-acceptance-before-not-them")

        notThemButton.tap()

        let cardGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notThemButton)
        XCTAssertEqual(XCTWaiter().wait(for: [cardGone], timeout: 10), .completed,
                       "the pending-acceptance card should disappear immediately after 'Not them'")
        attachScreenshot(named: "07-pending-acceptance-dismissed")

        // A pull-to-refresh afterward must not resurrect the card: the
        // underlying invite was discarded, so the same acceptance can never
        // verify again on this device.
        pullToRefresh()
        let stillGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["pendingAcceptance.confirmButton"])
        XCTAssertEqual(XCTWaiter().wait(for: [stillGone], timeout: 10), .completed,
                       "a dismissed pending acceptance must never reappear after another refresh")
    }

    /// A second, independently scripted owner identity creates its own
    /// invite directly against the local relay (not through the app's own
    /// UI at all — this mirrors another person's device). Opening the
    /// resulting `phone-lockbox-companion://invite/...` link makes *this*
    /// app instance act as the friend being invited: `ContentView.onOpenURL`
    /// should show the "You've been invited" prompt in front of the user —
    /// visible without scrolling (R5 pairing v2 UX fix item 7) — rather than
    /// silently prefilling a field below the fold, and must not accept
    /// anything until Accept is tapped, after which the friend side shows
    /// "Waiting for the person who invited you to confirm".
    func testOpeningScriptedInviteLinkShowsIncomingInvitePromptThenWaitingState() async throws {
        let ownerKeyStore = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeyStore)
        let transport = HTTPCompanionTransport(baseURL: try localRelayURL(), session: URLSession(configuration: .ephemeral))
        let scriptedOwnerClient = AsyncCompanionClient(signer: ownerSigner, transport: transport)

        let invitation = try await scriptedOwnerClient.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date())
        let link = invitation.shareLink
        guard let url = URL(string: link) else {
            XCTFail("scripted invite produced an unparseable link: \(link)")
            return
        }

        XCUIDevice.shared.system.open(url)

        // Some iOS versions show a one-time system "Open in app?" prompt for
        // a custom-scheme URL opened this way; tap through it if present,
        // but don't fail if it never appears (a single registered claimant
        // usually opens directly).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openConfirmation = springboard.buttons["Open"]
        if openConfirmation.waitForExistence(timeout: 3) {
            openConfirmation.tap()
        }

        let acceptButton = app.buttons["incomingInvite.acceptButton"]
        XCTAssertTrue(acceptButton.waitForExistence(timeout: 15), "the 'You've been invited' prompt never appeared after opening the invite link")

        // Review P2-5: confirm the routing itself, not just its effect.
        XCTAssertTrue(app.tabBars.buttons["People"].isSelected, "the People tab should be selected after opening the invite link")

        // R5 pairing v2 UX fix item 7: the prompt must be visible without
        // scrolling — `isHittable` requires the element to actually be
        // on-screen and not obscured, not merely present in the hierarchy.
        XCTAssertTrue(acceptButton.isHittable, "the incoming-invite Accept button must be visible without scrolling")
        attachScreenshot(named: "02-incoming-invite-prompt-visible-without-scrolling")

        // Opening the link must never itself accept anything. A single
        // instantaneous check only proves it hadn't happened yet at that
        // exact moment; give auto-accept a real ~3s window to show up
        // before concluding it didn't, via an inverted predicate
        // expectation (review P2-5) rather than one `exists` snapshot.
        let autoAccepted = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.staticTexts["acceptInvite.waitingLabel"])
        autoAccepted.isInverted = true
        await fulfillment(of: [autoAccepted], timeout: 3)

        // Now tap Accept explicitly and confirm the friend side shows the
        // new waiting state (R5 pairing v2, Slice P2b item 5) — no code to
        // read aloud or share back.
        acceptButton.tap()

        let waitingLabel = app.staticTexts["acceptInvite.waitingLabel"]
        XCTAssertTrue(waitingLabel.waitForExistence(timeout: 30), "'Waiting for the person who invited you to confirm' never appeared after tapping Accept")
        attachScreenshot(named: "03-friend-side-waiting-for-confirmation")

        // The prompt itself is dismissed once accepted.
        XCTAssertFalse(app.buttons["incomingInvite.acceptButton"].exists, "the incoming-invite prompt should be gone once accepted")
    }

    /// Regression test for the real product bug this uncovered and fixed in
    /// `ContentView.swift`: its `.onChange(of: scenePhase)` used to reset
    /// `selectedTab`/`lockboxPath` to the Lockbox tab on *every* transition
    /// to `.active`, even when no Quick Action route was pending — found
    /// from `UITests3.xcresult`'s captured UI hierarchy on a failure of
    /// `testCreateInviteCopyLinkAndFriendAcceptsOverRelay`, which showed the
    /// Lockbox tab's setup screen (with its tab bar button marked
    /// `Selected`) immediately after tapping "People". That meant a user
    /// returning to the app from Messages or Settings — or from opening a
    /// companion invite link — was thrown back to Lockbox. A first fix
    /// gated the reset on `coordinator.pendingQuickAction` becoming non-nil
    /// via `ContentView`'s own `onChange` of that value; an Opus review
    /// (P1) found that this raced `LockboxTabView`'s *separate* `onChange`
    /// of the same value (which appends `.recovery` to the nav path) with
    /// undefined ordering, risking an appended-then-immediately-cleared
    /// destination that would leave `pendingQuickAction` permanently
    /// wedged. The actual fix is `ScreenTimeCoordinator.onWillPresentQuickAction`,
    /// a hook `ContentView` sets once and the coordinator calls strictly
    /// *before* publishing `pendingQuickAction`, removing the ordering
    /// question entirely. This test simulates "returning from Messages":
    /// select People, background the app, then foreground it again, and
    /// confirm People is still selected.
    func testPeopleTabStaysSelectedAcrossBackgroundForeground() throws {
        guard navigateToPeopleTab() else {
            XCTFail("'People' tab never became selected")
            return
        }
        let peopleTabButton = app.tabBars.buttons["People"]

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "app never reported .runningBackground after pressing Home")

        app.activate()
        let stillSelected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: peopleTabButton)
        let result = XCTWaiter().wait(for: [stillSelected], timeout: 15)
        attachScreenshot(named: "03-people-tab-stays-selected-after-foreground")
        XCTAssertEqual(result, .completed, "'People' tab was not still selected after backgrounding and foregrounding the app")
    }

    // MARK: - Helpers

    /// Taps the People tab exactly once and waits, via a predicate
    /// expectation, for it to actually become selected. Deliberately not a
    /// retry loop (review P2-6): retrying a failed tap could mask a real
    /// regression of the review-P1 tab-reset bug this is meant to catch —
    /// see `testPeopleTabStaysSelectedAcrossBackgroundForeground`, which
    /// exercises that regression directly.
    @discardableResult
    private func navigateToPeopleTab() -> Bool {
        let peopleTabButton = app.tabBars.buttons["People"]
        guard peopleTabButton.waitForExistence(timeout: 15) else { return false }
        peopleTabButton.tap()
        let becameSelected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: peopleTabButton)
        return XCTWaiter().wait(for: [becameSelected], timeout: 15) == .completed
    }

    private func localRelayURL() throws -> URL {
        guard let url = URL(string: Self.localRelayBaseURLString) else {
            throw CompanionUITestError(description: "invalid local relay base URL")
        }
        return url
    }

    /// Taps "Create an invite to share" in the app and reads the resulting
    /// link back from the app's own accessibility value (R5 pairing v2 UX
    /// fix item 7 — the visible label is now a short, truncated line; see
    /// the doc comment on `testCreateInviteCopyLinkAndFriendAcceptsOverRelay`).
    /// Shared by the owner-side pending-acceptance tests.
    private func createInviteInAppAndReadLink() async throws -> Invitation {
        let createButton = app.buttons["inviteSomeone.createInviteButton"]
        guard createButton.waitForExistence(timeout: 30) else {
            throw CompanionUITestError(description: "'Create an invite to share' button never appeared")
        }
        createButton.tap()

        let linkTextElement = app.staticTexts["inviteSomeone.inviteLinkText"]
        guard linkTextElement.waitForExistence(timeout: 30) else {
            throw CompanionUITestError(description: "invite link text never appeared after creating an invite")
        }
        let linkText = (linkTextElement.value as? String) ?? ""
        return try Invitation.fromShareLink(linkText)
    }

    /// Simulates "pull to refresh" over the People tab's scroll content
    /// (`.refreshable` on `LockboxScrollView`), which is how the app learns
    /// about a relay-delivered pending acceptance outside of the one
    /// automatic fetch on first appearance. Deliberately a slow, held
    /// press-and-drag rather than `XCUIElement.swipeDown()`: a plain
    /// `swipeDown()` is a fast flick (high velocity, short duration), which
    /// SwiftUI's `.refreshable` can register as an ordinary scroll/bounce
    /// rather than crossing its pull-to-refresh activation threshold — that
    /// threshold depends on the touch dwelling past a distance, not on
    /// gesture velocity. A held drag from the upper part of the screen to
    /// well past the middle reliably crosses it.
    private func pullToRefresh() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Pulls to refresh repeatedly until `element` appears or `timeout`
    /// elapses. A single pull-to-refresh gesture is occasionally missed by
    /// the simulator under load (observed empirically as an intermittent
    /// flake); retrying the gesture itself, not just the existence check,
    /// is what makes this reliable — a pure `waitForExistence` after one
    /// gesture only re-polls the hierarchy, it never repeats the gesture.
    @discardableResult
    private func waitForElementAfterRepeatedRefresh(_ element: XCUIElement, timeout: TimeInterval = 40) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.waitForExistence(timeout: 6) { return true }
            pullToRefresh()
        }
        return element.waitForExistence(timeout: 2)
    }

    private func attachScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Mirrors `CompanionCoordinator.companionLinkScheme` (app-side, not
/// exported by `CompanionKit`) so this test can sanity-check the copied
/// link's scheme without depending on an app-target import.
private enum CompanionCoordinatorScheme {
    static let companionLinkScheme = "phone-lockbox-companion"
}

private struct CompanionUITestError: Error, CustomStringConvertible {
    let description: String
}
