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

        let linkText = (linkTextElement.label.isEmpty ? (linkTextElement.value as? String) : linkTextElement.label) ?? ""
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

    /// A second, independently scripted owner identity creates its own
    /// invite directly against the local relay (not through the app's own
    /// UI at all — this mirrors another person's device). Opening the
    /// resulting `phone-lockbox-companion://invite/...` link makes *this*
    /// app instance act as the friend being invited: `ContentView.onOpenURL`
    /// should route to the People tab with the "Paste invite link" field
    /// already filled in, without accepting anything automatically.
    func testOpeningScriptedInviteLinkRoutesToPeopleWithAcceptCardPrefilled() async throws {
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

        let pastedInviteField = app.textFields["acceptInvite.pastedInviteField"]
        XCTAssertTrue(pastedInviteField.waitForExistence(timeout: 15), "People tab's 'Paste invite link' field never appeared after opening the invite link")
        attachScreenshot(named: "02-accept-card-prefilled-from-link")

        // Review P2-5: confirm the routing itself, not just its effect.
        XCTAssertTrue(app.tabBars.buttons["People"].isSelected, "the People tab should be selected after opening the invite link")

        let prefilled = (pastedInviteField.value as? String) ?? ""
        XCTAssertEqual(prefilled, link, "the accept card's pasted-invite field should be prefilled with exactly the opened link")

        // Opening the link must never itself accept anything. A single
        // instantaneous check only proves it hadn't happened yet at that
        // exact moment; give auto-accept a real ~3s window to show up
        // before concluding it didn't, via an inverted predicate
        // expectation (review P2-5) rather than one `exists` snapshot.
        let autoAccepted = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.staticTexts["Your code"])
        autoAccepted.isInverted = true
        await fulfillment(of: [autoAccepted], timeout: 3)
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
