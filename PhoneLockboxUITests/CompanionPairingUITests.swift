import XCTest
import UIKit
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
        app.launchArguments += ["-relayBaseURL", Self.localRelayBaseURLString]
        app.launch()
        self.app = app
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Create an invite in the app, use the new "Copy link" button to get
    /// its text onto the pasteboard, decode it exactly as a friend's device
    /// would (`Invitation.fromShareLink`), and have a fresh, in-memory-only
    /// friend identity accept it over HTTP against the local relay —
    /// mirroring `tools/relay-smoke`'s "owner creates an invite" /
    /// "helper accepts the invite" steps, but with the invite coming from
    /// the real app's pasteboard rather than another in-process client.
    func testCreateInviteCopyLinkAndFriendAcceptsOverRelay() async throws {
        app.tabBars.buttons["People"].tap()

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

        let copyButton = app.buttons["inviteSomeone.copyLinkButton"]
        guard copyButton.waitForExistence(timeout: 30) else {
            XCTFail("'Copy link' button never appeared after creating an invite")
            return
        }
        attachScreenshot(named: "01-invite-created-copy-link-visible")

        copyButton.tap()

        let linkText = try waitForPasteboardString(timeout: 15)
        XCTAssertTrue(linkText.hasPrefix("\(CompanionCoordinatorScheme.companionLinkScheme)://invite/"),
                      "Copied pasteboard text does not look like an invite link: \(linkText)")

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

        let prefilled = (pastedInviteField.value as? String) ?? ""
        XCTAssertEqual(prefilled, link, "the accept card's pasted-invite field should be prefilled with exactly the opened link")

        // Opening the link must never itself accept anything.
        XCTAssertFalse(app.staticTexts["Your code"].exists, "opening an invite link must not auto-accept it")
    }

    // MARK: - Helpers

    private func localRelayURL() throws -> URL {
        guard let url = URL(string: Self.localRelayBaseURLString) else {
            throw CompanionUITestError(description: "invalid local relay base URL")
        }
        return url
    }

    private func waitForPasteboardString(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = UIPasteboard.general.string, !value.isEmpty {
                return value
            }
            usleep(100_000)
        }
        throw CompanionUITestError(description: "pasteboard never contained a copied string within \(timeout)s")
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
