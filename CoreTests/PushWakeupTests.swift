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
