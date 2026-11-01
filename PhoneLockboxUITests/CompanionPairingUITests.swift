import XCTest
import CompanionKit

/// End-to-end UI coverage for pairing v3 (`docs/r5-pairing-v3-plan.md`, P3b):
/// the owner sends a link, the friend taps Accept, and that is all.
///
/// Requires a local relay started with `cd relay && npm run dev:test`
/// (`http://127.0.0.1:8002`, high local rate limits). The app is launched with
/// DEBUG-only `-relayBaseURL` and `-resetCompanionStateForUITests` arguments.
/// "The other person" is scripted in this test process over HTTP, exactly like
/// `tools/relay-smoke`; no second simulator is used. Asking to end a lock early
/// needs a real active lock (Screen Time), which a UI test cannot start, so the
/// owner-asks step is covered by `CompanionLocalRelayFlowTests`; here the
/// scripted owner sends the request to the app acting as the friend.
@MainActor
final class CompanionPairingUITests: XCTestCase {
    private static let localRelayBaseURLString = "http://127.0.0.1:8002"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-relayBaseURL", Self.localRelayBaseURLString,
            // A fresh owner/approver identity, invite store and rollback
            // anchor on every launch. DEBUG-only; see
            // `CompanionCoordinator.resetCompanionStateForUITests`.
            "-resetCompanionStateForUITests",
        ]
        // DEBUG-only: forces the notification permission to "denied" so the
        // quiet "Notifications are off" row can be captured.
        if name.contains("NotificationsOffRow") { app.launchArguments += ["-forceNotificationPermissionDenied"] }
        app.launch()
        // A previous test can leave the simulator in the App Switcher.
        if !app.wait(for: .runningForeground, timeout: 15) { app.activate() }
        self.app = app
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Owner side

    /// Owner creates an invite (typing their name once), a scripted friend
    /// looks it up and accepts over HTTP, and the app shows "Ari joined" and
    /// lists Ari under trusted people without any manual refresh (People
    /// auto-refreshes every ~5 s while an invite is outstanding).
    func testOwnerInviteScriptedFriendAcceptsJoinedNoticeAndPersonAppearWithoutRefresh() async throws {
        guard navigateToPeopleTab() else { return XCTFail("'People' tab never stayed selected") }

        let link = try await createInviteInApp(ownerName: "Nishant")
        XCTAssertTrue(link.hasPrefix("\(CompanionCoordinatorScheme.companionLinkScheme)://i/"), "unexpected link shape: \(link.prefix(40))")
        XCTAssertEqual(link.count, "\(CompanionCoordinatorScheme.companionLinkScheme)://i/".count + 22, "the link is token-sized, not a long blob")
        let token = try XCTUnwrap(InviteToken.token(fromShareLink: link))
        attachScreenshot(named: "01-owner-invite-created")

        // The scripted friend: a throwaway in-memory identity.
        let friend = try scriptedClient(role: .trustedApprover)
        let invitation = try await friend.client.lookupInvite(token: token)
        XCTAssertEqual(invitation.payload.ownerDisplayName, "Nishant")
        _ = try await friend.client.acceptInvite(invitation, token: token, approverDisplayName: "Ari",
                                                 acceptanceID: UUID().uuidString, now: Date())

        // No pull-to-refresh: the 5 s poll surfaces the join by itself.
        let joinedText = app.staticTexts["joinedNotice.text"]
        XCTAssertTrue(joinedText.waitForExistence(timeout: 40), "the 'Ari joined' notice never appeared without a manual refresh")
        XCTAssertEqual(joinedText.label, "Ari joined")
        XCTAssertTrue(waitUntilHittable(joinedText), "the notice must be visible without scrolling")
        XCTAssertTrue(app.staticTexts["Ari"].waitForExistence(timeout: 5), "Ari is listed under trusted people immediately")
        XCTAssertTrue(app.staticTexts["Ari can approve ending one exact lock early when you ask."].waitForExistence(timeout: 10),
                      "both scopes are active from the single Accept")
        attachScreenshot(named: "02-owner-sees-ari-joined")

        // There is nothing to confirm and no switches.
        XCTAssertFalse(app.buttons["pendingAcceptance.confirmButton"].exists)
        XCTAssertEqual(app.switches.count, 0, "consent switches are gone from the default flow")

        // The notice is dismissable and stays gone while Ari stays listed.
        app.buttons["joinedNotice.dismissButton"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: joinedText)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["Ari"].exists)
        attachScreenshot(named: "03-owner-notice-dismissed")

        // Bottom of the page (P3-9): the last card must clear the tab bar.
        for _ in 0..<6 { app.swipeUp() }
        attachScreenshot(named: "03b-people-bottom-scrolled")
    }

    /// With notifications denied (forced by launch argument) and one trusted
    /// person, People shows one quiet row with the person's name and a small
    /// "Turn On" button. The screenshot lets the UX review see it.
    func testNotificationsOffRowIsQuietAndNamesTheTrustedPerson() async throws {
        guard navigateToPeopleTab() else { return XCTFail("'People' tab never stayed selected") }

        let link = try await createInviteInApp(ownerName: "Nishant")
        let token = try XCTUnwrap(InviteToken.token(fromShareLink: link))
        let friend = try scriptedClient(role: .trustedApprover)
        let invitation = try await friend.client.lookupInvite(token: token)
        _ = try await friend.client.acceptInvite(invitation, token: token, approverDisplayName: "Ari",
                                                 acceptanceID: UUID().uuidString, now: Date())

        XCTAssertTrue(app.staticTexts["joinedNotice.text"].waitForExistence(timeout: 40), "the 'Ari joined' notice never appeared")
        let row = app.staticTexts["people.notificationsOff.text"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the notifications-off row never appeared")
        XCTAssertEqual(row.label, "Notifications are off, so you won't hear when Ari answers.")
        let turnOn = app.buttons["people.notificationsOff.openSettingsButton"]
        XCTAssertTrue(turnOn.exists)
        XCTAssertEqual(turnOn.label, "Open Settings to turn notifications on")
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        attachScreenshot(named: "09-notifications-off-row")
    }

    // MARK: - Friend side

    /// A scripted owner creates an invite; opening its token link in the app
    /// shows "‹Owner› invited you to be a trusted person", Accept pairs
    /// immediately ("You're a trusted person for ‹Owner›"), and a request the
    /// scripted owner then sends appears with the owner's name.
    func testFriendOpensTokenLinkAcceptsAndSeesAnIncomingRequestWithTheOwnersName() async throws {
        let owner = try scriptedClient(role: .owner)
        let issued = try await owner.client.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date(),
                                                         ownerDisplayName: "Dana")
        guard let url = URL(string: issued.shareLink) else { return XCTFail("unparseable link") }
        openURLInApp(url)

        let title = app.staticTexts["incomingInvite.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the invite prompt never appeared after opening the token link")
        XCTAssertEqual(title.label, "Dana invited you to be a trusted person")
        XCTAssertTrue(app.tabBars.buttons["People"].isSelected, "opening the link should land on People")
        let accept = app.buttons["incomingInvite.acceptButton"]
        XCTAssertTrue(waitUntilHittable(accept), "Accept must be visible without scrolling")

        // Opening the link never accepts by itself, and Accept needs a name.
        XCTAssertFalse(accept.isEnabled, "Accept stays off until the friend's name is entered")
        let nameField = app.textFields["incomingInvite.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(nameField), "the name field never took keyboard focus")
        nameField.typeText("Sam")
        attachScreenshot(named: "04-friend-invite-prompt")
        accept.tap()

        // The friend gets a one-time confirmation where the invite was.
        let acceptedNotice = app.staticTexts["acceptedNotice.text"]
        XCTAssertTrue(acceptedNotice.waitForExistence(timeout: 30), "no confirmation notice after Accept")
        XCTAssertEqual(acceptedNotice.label, "You're now a trusted person for Dana")
        XCTAssertTrue(waitUntilHittable(acceptedNotice), "the notice must be visible without scrolling")
        attachScreenshot(named: "05a-friend-accepted-notice")

        let paired = app.staticTexts["helping.statusText"]
        XCTAssertTrue(paired.waitForExistence(timeout: 30), "the paired state never appeared after Accept")
        XCTAssertEqual(paired.label, "You're a trusted person for Dana")
        XCTAssertFalse(app.buttons["incomingInvite.acceptButton"].exists, "no waiting state: the prompt is gone")
        attachScreenshot(named: "05-friend-paired")

        // The scripted owner sends a request to the app (a real lock is not
        // needed on the scripted side).
        let inbox = try await owner.client.fetchInboxResponse()
        let pairing = try XCTUnwrap(inbox.pairings?.first)
        let consent = try XCTUnwrap(inbox.consents?.first)
        let now = Date()
        let session = try ActiveSession(owner: owner.signer.identity, sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                        startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(3_600))
        _ = try await owner.client.publishSession(session)
        _ = try await owner.client.requestUnlock(requestID: UUID().uuidString, pairings: [pairing], consents: [consent],
                                                 session: session, targets: [pairing.approver.identityID], validFor: 600)

        // The idle poll (~30 s) brings it in without a manual refresh.
        let askTitle = app.staticTexts["Dana asks to end their lock early"]
        XCTAssertTrue(askTitle.waitForExistence(timeout: 60), "the friend never saw the request with the owner's name")
        XCTAssertTrue(app.buttons["Approve"].exists)
        XCTAssertTrue(app.staticTexts["Waiting for you"].exists, "the pending request sits in the Waiting for you card")
        XCTAssertTrue(waitUntilHittable(askTitle), "the request must be visible without scrolling")
        attachScreenshot(named: "06-friend-sees-request")
    }

    /// An invite that was already used reads as a calm, final message.
    func testOpeningAnAlreadyUsedInviteShowsAClearMessage() async throws {
        let owner = try scriptedClient(role: .owner)
        let issued = try await owner.client.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date(),
                                                         ownerDisplayName: "Dana")
        let other = try scriptedClient(role: .trustedApprover)
        let invitation = try await other.client.lookupInvite(token: issued.token)
        _ = try await other.client.acceptInvite(invitation, token: issued.token, approverDisplayName: "Someone",
                                                acceptanceID: UUID().uuidString, now: Date())
        openURLInApp(try XCTUnwrap(URL(string: issued.shareLink)))

        let message = app.staticTexts["incomingInvite.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 20), "no message for a used invite")
        XCTAssertEqual(message.label, "This invite was already used or has expired. Ask for a new link.")
        XCTAssertFalse(app.buttons["incomingInvite.acceptButton"].exists)
        attachScreenshot(named: "07-used-invite-message")
    }

    /// Regression: returning from Messages/Settings must not throw the user
    /// back to the Lockbox tab (see `ContentView.onChange(of: scenePhase)`).
    func testPeopleTabStaysSelectedAcrossBackgroundForeground() throws {
        guard navigateToPeopleTab() else { return XCTFail("'People' tab never became selected") }
        let peopleTabButton = app.tabBars.buttons["People"]

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "app never reported .runningBackground after pressing Home")

        app.activate()
        let stillSelected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: peopleTabButton)
        let result = XCTWaiter().wait(for: [stillSelected], timeout: 15)
        attachScreenshot(named: "08-people-tab-stays-selected-after-foreground")
        XCTAssertEqual(result, .completed, "'People' tab was not still selected after backgrounding and foregrounding the app")
    }

    // MARK: - Helpers

    /// Waits for the field to be hittable, taps it, and waits for the keyboard;
    /// retries the tap once if no keyboard appeared.
    private func focus(_ field: XCUIElement) -> Bool {
        guard waitUntilHittable(field) else { return false }
        for _ in 0..<2 {
            field.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { return true }
        }
        return false
    }

    /// Waits for `isHittable`: a delayed scroll-to animation may still be running.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private struct ScriptedDevice {
        let signer: DeviceSigner
        let client: AsyncCompanionClient
    }

    /// A throwaway in-memory identity acting over HTTP against the local relay.
    private func scriptedClient(role: CompanionRole) throws -> ScriptedDevice {
        let signer = try DeviceSigner.create(role: role, keyStore: InMemoryDeviceKeyStore())
        let transport = HTTPCompanionTransport(baseURL: try localRelayURL(), session: URLSession(configuration: .ephemeral))
        return ScriptedDevice(signer: signer, client: AsyncCompanionClient(signer: signer, transport: transport))
    }

    private func openURLInApp(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        // Some iOS versions show a one-time "Open in app?" prompt for a
        // custom-scheme URL; tap through it if present.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openConfirmation = springboard.buttons["Open"]
        if openConfirmation.waitForExistence(timeout: 3) { openConfirmation.tap() }
    }

    /// Taps the People tab once and waits for it to be selected (deliberately
    /// not a retry loop, so a tab-reset regression is not masked).
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

    /// Types the owner's name (asked once), taps "Create an invite to share"
    /// and returns the link read from the app's own accessibility value (the
    /// system pasteboard cannot be read across apps without a prompt).
    private func createInviteInApp(ownerName: String) async throws -> String {
        let nameField = app.textFields["inviteSomeone.nameField"]
        guard nameField.waitForExistence(timeout: 30) else {
            throw CompanionUITestError(description: "owner name field never appeared")
        }
        guard focus(nameField) else { throw CompanionUITestError(description: "owner name field never took keyboard focus") }
        // "\n" submits the field. The return key has no "Return" label on
        // current keyboards, and a tap that only dismisses the keyboard never
        // reaches the button underneath (pre-push run, 2026-10-31).
        nameField.typeText(ownerName + "\n")
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        _ = await XCTWaiter.fulfillment(of: [keyboardGone], timeout: 10)

        let createButton = app.buttons["inviteSomeone.createInviteButton"]
        guard createButton.waitForExistence(timeout: 30) else {
            throw CompanionUITestError(description: "'Create an invite to share' button never appeared")
        }
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true AND isEnabled == true"), object: createButton)
        _ = await XCTWaiter.fulfillment(of: [hittable], timeout: 10)
        createButton.tap()

        let linkTextElement = app.staticTexts["inviteSomeone.inviteLinkText"]
        guard linkTextElement.waitForExistence(timeout: 30) else {
            throw CompanionUITestError(description: "invite link text never appeared after creating an invite")
        }
        let link = (linkTextElement.value as? String) ?? ""

        // Copy link answers visibly: the button reads "Copied" for about two seconds.
        let copyButton = app.buttons["inviteSomeone.copyLinkButton"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 10), "Copy link button never appeared")
        copyButton.tap()
        XCTAssertEqual(copyButton.label, "Link copied")
        return link
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
/// exported by `CompanionKit`).
private enum CompanionCoordinatorScheme {
    static let companionLinkScheme = "phone-lockbox-companion"
}

private struct CompanionUITestError: Error, CustomStringConvertible {
    let description: String
}
