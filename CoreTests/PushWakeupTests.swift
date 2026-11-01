import XCTest
@testable import PhoneLockboxCore

@MainActor
final class PushWakeupTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "PushWakeupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private final class Recorder {
        var sent: [(String, String, String)] = []
        var failures = 0
    }

    private func makeRegistrar(defaults: UserDefaults, clock: @escaping () -> Date, identities: @escaping () -> [String],
                               environment: String = "sandbox", recorder: Recorder) -> PushRegistrar {
        PushRegistrar(ledger: PushRegistrationLedger(defaults: defaults), environment: environment, now: clock,
                      identityIDs: identities) { id, token, env in
            if recorder.failures > 0 { recorder.failures -= 1; throw URLError(.notConnectedToInternet) }
            recorder.sent.append((id, token, env))
        }
    }

    func testHexIsLowercaseAndZeroPadded() {
        XCTAssertEqual(PushRegistrar.hex(Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
    }

    func testPeopleAppearPromptPolicy() {
        XCTAssertTrue(PushPromptPolicy.shouldPromptOnPeopleAppear(permission: .notDetermined, helpingCount: 1))
        XCTAssertFalse(PushPromptPolicy.shouldPromptOnPeopleAppear(permission: .notDetermined, helpingCount: 0))
        XCTAssertFalse(PushPromptPolicy.shouldPromptOnPeopleAppear(permission: .denied, helpingCount: 2))
        XCTAssertFalse(PushPromptPolicy.shouldPromptOnPeopleAppear(permission: .allowed, helpingCount: 2))
    }

    func testDeniedRowCopyIsRoleAwareWithRealNames() {
        XCTAssertEqual(NotificationsOffRow.message(helpingNames: ["Dana"], trustedNames: []),
                       "Notifications are off, so you won't hear when Dana asks.")
        XCTAssertEqual(NotificationsOffRow.message(helpingNames: [], trustedNames: ["Ari"]),
                       "Notifications are off, so you won't hear when Ari answers.")
        XCTAssertEqual(NotificationsOffRow.message(helpingNames: ["Dana", "Lee"], trustedNames: []),
                       "Notifications are off, so you won't hear when they ask.")
        XCTAssertEqual(NotificationsOffRow.message(helpingNames: [], trustedNames: ["Ari", "Sam"]),
                       "Notifications are off, so you won't hear when they answer.")
        XCTAssertEqual(NotificationsOffRow.message(helpingNames: ["Dana"], trustedNames: ["Ari"]),
                       "Notifications are off, so you won't hear about requests or answers.")
    }

    func testNotificationCardVisibilityAndSnooze() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 0, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .denied, helpingCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .allowed, helpingCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 1,
                                                  snoozedUntil: now.addingTimeInterval(3_600), now: now))
        // Snooze over: the card returns.
        XCTAssertTrue(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 1,
                                                 snoozedUntil: now.addingTimeInterval(-1), now: now))
        // An implausibly far stamp (clock moved back) does not hide it forever.
        XCTAssertTrue(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 1,
                                                 snoozedUntil: now.addingTimeInterval(NotificationCard.snoozeInterval + 10), now: now))
    }

    func testNotificationCardSnoozePersistsSevenDays() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 5_000)
        XCTAssertNil(NotificationCard.snoozedUntil(in: defaults))
        let until = NotificationCard.snooze(in: defaults, now: now)
        XCTAssertEqual(until.timeIntervalSince(now), 7 * 24 * 3_600)
        XCTAssertEqual(NotificationCard.snoozedUntil(in: defaults), until)
    }

    func testNotificationCardVisibleForOwnerWithTrustedPerson() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 0, trustedCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 0, trustedCount: 0, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .denied, helpingCount: 0, trustedCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .allowed, helpingCount: 1, trustedCount: 1, snoozedUntil: nil, now: now))
        XCTAssertFalse(NotificationCard.isVisible(permission: .notDetermined, helpingCount: 0, trustedCount: 1,
                                                  snoozedUntil: now.addingTimeInterval(3_600), now: now))
    }

    func testNotificationCardTitleAndBody() {
        XCTAssertEqual(NotificationCard.title(helpingNames: ["Dana"], trustedNames: []), "Get notified when Dana asks")
        XCTAssertEqual(NotificationCard.title(helpingNames: [], trustedNames: ["Ari"]), "Get notified when Ari answers")
        XCTAssertEqual(NotificationCard.title(helpingNames: ["Dana", "Lee"], trustedNames: []), "Get notified when someone asks")
        XCTAssertEqual(NotificationCard.title(helpingNames: [], trustedNames: ["Ari", "Bo"]), "Get notified when someone answers")
        XCTAssertEqual(NotificationCard.title(helpingNames: ["Dana"], trustedNames: ["Ari"]), "Get notified about requests and answers")
        XCTAssertEqual(NotificationCard.body(helpingNames: ["Dana"], trustedNames: []),
                       "Otherwise you'll only see requests when you open People.")
        XCTAssertEqual(NotificationCard.body(helpingNames: [], trustedNames: ["Ari"]),
                       "Otherwise you'll only see answers when you open People.")
        XCTAssertEqual(NotificationCard.body(helpingNames: ["Dana"], trustedNames: ["Ari"]),
                       "Otherwise you'll only see updates when you open People.")
    }

    func testInvitePromptFiresOnlyForALiveLinkWithAPendingFlag() {
        XCTAssertTrue(InvitePromptTrigger.shouldFire(pending: true, linkIsLive: true))
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pending: true, linkIsLive: false))
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pending: false, linkIsLive: true))
    }

    func testInvitePromptPendingExpiresAfterTenMinutes() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(InvitePromptTrigger.shouldFire(pendingSince: t0, linkIsLive: true, now: t0.addingTimeInterval(5)))
        XCTAssertTrue(InvitePromptTrigger.shouldFire(pendingSince: t0, linkIsLive: true, now: t0.addingTimeInterval(600)))
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pendingSince: t0, linkIsLive: true, now: t0.addingTimeInterval(601)))
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pendingSince: t0, linkIsLive: false, now: t0.addingTimeInterval(5)))
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pendingSince: nil, linkIsLive: true, now: t0))
        // Clock moved back: a future stamp is treated as expired.
        XCTAssertFalse(InvitePromptTrigger.shouldFire(pendingSince: t0, linkIsLive: true, now: t0.addingTimeInterval(-5)))
    }

    func testForegroundBannerIsSkippedOnlyOnActivePeopleTab() {
        XCTAssertFalse(PushForegroundPresentation.showsBanner(peopleTabSelected: true, appIsActive: true))
        XCTAssertTrue(PushForegroundPresentation.showsBanner(peopleTabSelected: false, appIsActive: true))
        XCTAssertTrue(PushForegroundPresentation.showsBanner(peopleTabSelected: true, appIsActive: false))
    }

    func testAcceptedNoticeDetail() {
        XCTAssertEqual(AcceptedNoticeCopy.detail(ownerName: "Dana", notificationsAllowed: true),
                       "Dana can ask you to approve ending a lock early. We'll let you know when Dana asks.")
        XCTAssertEqual(AcceptedNoticeCopy.detail(ownerName: "Dana", notificationsAllowed: false),
                       "Dana can ask you to approve ending a lock early. You'll see requests here.")
    }

    func testEnvironmentSelection() {
        XCTAssertEqual(PushEnvironmentName.current(isDebug: true), "sandbox")
        XCTAssertEqual(PushEnvironmentName.current(isDebug: false), "production")
    }

    func testKindParsingIgnoresUnknownAndMalformed() {
        XCTAssertEqual(PushWakeKind.parse(userInfo: ["kind": "request"]), .request)
        XCTAssertEqual(PushWakeKind.parse(userInfo: ["kind": "answer"]), .answer)
        XCTAssertEqual(PushWakeKind.parse(userInfo: ["kind": "joined"]), .joined)
        XCTAssertNil(PushWakeKind.parse(userInfo: ["kind": "other"]))
        XCTAssertNil(PushWakeKind.parse(userInfo: ["kind": 3]))
        XCTAssertNil(PushWakeKind.parse(userInfo: ["aps": ["kind": "request"]]))
        XCTAssertNil(PushWakeKind.parse(userInfo: [:]))
    }

    func testDeniedRowVisibility() {
        XCTAssertTrue(NotificationsOffRow.isVisible(permission: .denied, pairingCount: 1))
        XCTAssertFalse(NotificationsOffRow.isVisible(permission: .denied, pairingCount: 0))
        XCTAssertFalse(NotificationsOffRow.isVisible(permission: .allowed, pairingCount: 3))
        XCTAssertFalse(NotificationsOffRow.isVisible(permission: .notDetermined, pairingCount: 3))
    }

    func testNothingIsSentWithoutAToken() async {
        let recorder = Recorder()
        let registrar = makeRegistrar(defaults: freshDefaults(), clock: { Date(timeIntervalSince1970: 1_000) },
                                      identities: { ["owner"] }, recorder: recorder)
        await registrar.sync()
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testRegistersUnderEveryIdentityOnceThenDedupes() async {
        let recorder = Recorder()
        var now = Date(timeIntervalSince1970: 1_000)
        let registrar = makeRegistrar(defaults: freshDefaults(), clock: { now }, identities: { ["owner", "approver"] }, recorder: recorder)
        registrar.updateDeviceToken(Data(repeating: 0xAA, count: 32))
        await registrar.sync()
        XCTAssertEqual(recorder.sent.map { $0.0 }, ["owner", "approver"])
        XCTAssertEqual(recorder.sent[0].1, String(repeating: "aa", count: 32))
        XCTAssertEqual(recorder.sent[0].2, "sandbox")
        now = now.addingTimeInterval(3_600)
        await registrar.sync()
        XCTAssertEqual(recorder.sent.count, 2, "unchanged registration is not re-sent")
    }

    func testResendsAfterSevenDays() async {
        let recorder = Recorder()
        var now = Date(timeIntervalSince1970: 1_000)
        let registrar = makeRegistrar(defaults: freshDefaults(), clock: { now }, identities: { ["owner"] }, recorder: recorder)
        registrar.updateDeviceToken(hex: String(repeating: "ab", count: 32))
        await registrar.sync()
        now = now.addingTimeInterval(PushRegistrationLedger.resendInterval - 1)
        await registrar.sync()
        XCTAssertEqual(recorder.sent.count, 1)
        now = now.addingTimeInterval(1)
        await registrar.sync()
        XCTAssertEqual(recorder.sent.count, 2)
    }

    func testChangedTokenAndNewIdentityAreSent() async {
        let recorder = Recorder()
        var ids = ["owner"]
        let defaults = freshDefaults()
        let registrar = makeRegistrar(defaults: defaults, clock: { Date(timeIntervalSince1970: 1_000) }, identities: { ids }, recorder: recorder)
        registrar.updateDeviceToken(hex: String(repeating: "ab", count: 32))
        await registrar.sync()
        ids.append("approver")
        await registrar.sync()
        XCTAssertEqual(recorder.sent.map { $0.0 }, ["owner", "approver"])
        registrar.updateDeviceToken(hex: String(repeating: "cd", count: 32))
        await registrar.sync()
        XCTAssertEqual(recorder.sent.map { $0.0 }, ["owner", "approver", "owner", "approver"])
    }

    func testChangedEnvironmentIsSentAndFailureRetriesNextSync() async {
        let defaults = freshDefaults()
        let recorder = Recorder()
        let sandbox = makeRegistrar(defaults: defaults, clock: { Date(timeIntervalSince1970: 1_000) }, identities: { ["owner"] }, recorder: recorder)
        sandbox.updateDeviceToken(hex: String(repeating: "ab", count: 32))
        await sandbox.sync()
        let production = makeRegistrar(defaults: defaults, clock: { Date(timeIntervalSince1970: 1_000) }, identities: { ["owner"] },
                                       environment: "production", recorder: recorder)
        production.updateDeviceToken(hex: String(repeating: "ab", count: 32))
        recorder.failures = 1
        await production.sync()
        XCTAssertEqual(recorder.sent.count, 1, "failed send is swallowed and not recorded")
        await production.sync()
        XCTAssertEqual(recorder.sent.map { $0.2 }, ["sandbox", "production"])
    }

    func testLedgerStoresOnlyAFingerprintNotTheToken() {
        let defaults = freshDefaults()
        let ledger = PushRegistrationLedger(defaults: defaults)
        let token = String(repeating: "ab", count: 32)
        ledger.recordSent(identityID: "owner", token: token, environment: "sandbox", now: Date())
        let raw = defaults.data(forKey: PushRegistrationLedger.defaultsKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(raw.contains(token))
    }
}
