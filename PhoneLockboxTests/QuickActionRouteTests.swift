import XCTest
@testable import PhoneLockbox

final class QuickActionRouteTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let nonce = "123e4567-e89b-12d3-a456-426614174000"

    func testBoundedFocusRoutesRoundTripToRequestedPreset() throws {
        for preset in [QuickActionRoute.FocusPreset.thirtyMinutes, .oneHour] {
            let url = try XCTUnwrap(QuickActionRoute.url(for: .focus(preset), now: now))
            let route = try XCTUnwrap(QuickActionRoute.parse(url, now: now))
            XCTAssertEqual(route.action, .focus(preset))
            XCTAssertEqual(route.expiresAt, now.addingTimeInterval(TimeInterval(QuickActionRoute.lifetime)))
            XCTAssertEqual(route.id.count, 36)
            XCTAssertTrue(url.absoluteString.contains("issued=1000000&expires=1000300&nonce="))
        }
    }

    func testStatusAndRecoveryRoutesRoundTripWithoutEnforcementMeaning() throws {
        let statusURL = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let recoveryURL = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        XCTAssertEqual(QuickActionRoute.parse(statusURL, now: now)?.action, .status)
        XCTAssertEqual(QuickActionRoute.parse(recoveryURL, now: now)?.action, .recovery)
    }

    func testExpiredFutureAndStaleRoutesFailClosed() throws {
        let url = try XCTUnwrap(QuickActionRoute.url(for: .focus(.thirtyMinutes), now: now))
        let route = try XCTUnwrap(QuickActionRoute.parse(url, now: now))
        XCTAssertNil(QuickActionRoute.parse(url, now: route.expiresAt))
        XCTAssertNil(QuickActionRoute.parse(url, now: now.addingTimeInterval(-60)))
        XCTAssertNil(QuickActionRoute.parse(url, now: now.addingTimeInterval(331)))
    }

    func testExactLifetimeSkewAndCanonicalTimestampRules() {
        let valid = "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=\(nonce)"
        XCTAssertNotNil(QuickActionRoute.parse(URL(string: valid)!, now: now))
        XCTAssertNotNil(QuickActionRoute.parse(URL(string: valid)!, now: now.addingTimeInterval(-30)))
        XCTAssertNil(QuickActionRoute.parse(URL(string: valid)!, now: now.addingTimeInterval(-31)))
        XCTAssertNil(QuickActionRoute.parse(URL(string: valid)!, now: now.addingTimeInterval(330.1)))

        let invalid = [
            valid.replacingOccurrences(of: "expires=1000300", with: "expires=1000301"),
            valid.replacingOccurrences(of: "issued=1000000", with: "issued=1e6"),
            valid.replacingOccurrences(of: "issued=1000000", with: "issued=1000000.0"),
            valid.replacingOccurrences(of: "issued=1000000", with: "issued=01000000"),
            valid.replacingOccurrences(of: "issued=1000000", with: "issued=+1000000")
        ]
        for value in invalid {
            XCTAssertNil(QuickActionRoute.parse(URL(string: value)!, now: now), value)
        }
    }

    func testCanonicalAbsolutePathRejectsSlashAndEscapedVariants() {
        let paths = [
            "/v1/status/",
            "//v1/status",
            "/v1//status",
            "/v1/status%2F",
            "/v1/%73tatus"
        ]
        for path in paths {
            let url = URL(string: "phonelockbox://quick-action\(path)?issued=1000000&expires=1000300&nonce=\(nonce)")!
            XCTAssertNil(QuickActionRoute.parse(url, now: now), path)
        }
    }

    func testUnknownVersionQueryDuplicatesAndNonceVariantsFailClosed() {
        let urls = [
            URL(string: "phonelockbox://quick-action/v2/status?issued=1000000&expires=1000300&nonce=\(nonce)")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=\(nonce)&extra=yes")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=\(nonce)&expires=1000301")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=123E4567-E89B-12D3-A456-426614174000")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=not-a-uuid")!
        ]
        for url in urls {
            XCTAssertNil(QuickActionRoute.parse(url, now: now), "Unexpectedly accepted \(url)")
        }
    }

    func testWrongSchemeHostAndMalformedTimestampFailClosed() {
        let urls = [
            URL(string: "https://quick-action/v1/status?issued=1000000&expires=1000300&nonce=\(nonce)")!,
            URL(string: "phonelockbox://other/v1/status?issued=1000000&expires=1000300&nonce=\(nonce)")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=not-a-date&expires=1000300&nonce=\(nonce)")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000000&nonce=\(nonce)")!
        ]
        for url in urls {
            XCTAssertNil(QuickActionRoute.parse(url, now: now))
        }
    }
}

final class QuickActionPendingRouteStoreTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testReplayIsDeduplicatedAndAcknowledgedOnce() throws {
        let store = try makeStore()
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertTrue(store.enqueue(url, now: now))
        XCTAssertTrue(store.enqueue(url, now: now))
        let claim = try XCTUnwrap(store.claim(now: now))
        XCTAssertEqual(claim.url, url)
        XCTAssertTrue(try store.acknowledge(claim))
        XCTAssertFalse(try store.acknowledge(claim))
        XCTAssertNil(try store.claim(now: now))
    }

    func testClaimAckDoesNotDeleteRouteEnqueuedBetweenOperations() throws {
        let store = try makeStore()
        let first = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let second = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        XCTAssertTrue(store.enqueue(first, now: now))
        let claim = try XCTUnwrap(store.claim(now: now))
        XCTAssertTrue(store.enqueue(second, now: now))
        XCTAssertTrue(try store.acknowledge(claim))
        XCTAssertEqual(try store.claim(now: now)?.url, second)
    }

    func testExpiredClaimLeaseCanRetryAfterHostCrash() throws {
        let store = try makeStore()
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertTrue(store.enqueue(url, now: now))
        let first = try XCTUnwrap(store.claim(now: now))
        XCTAssertNil(try store.claim(now: now.addingTimeInterval(59)))
        let retry = try XCTUnwrap(store.claim(now: now.addingTimeInterval(60)))
        XCTAssertEqual(retry.url, first.url)
        XCTAssertFalse(try store.acknowledge(first))
        XCTAssertTrue(try store.acknowledge(retry))
    }

    func testCorruptQueueFailsClosedWithoutOverwritingBytes() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: queueURL)
        let store = try QuickActionPendingRouteStore(directoryURL: directory)
        let route = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertFalse(store.enqueue(route, now: now))
        XCTAssertThrowsError(try store.claim(now: now))
        XCTAssertEqual(try Data(contentsOf: queueURL), corrupt)
    }

    func testStaleEntriesAreBoundedByAgeAndQueuePreservesOrder() throws {
        let store = try makeStore()
        let old = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let current = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now.addingTimeInterval(601)))
        XCTAssertTrue(store.enqueue(old, now: now))
        XCTAssertTrue(store.enqueue(current, now: now.addingTimeInterval(601)))
        XCTAssertEqual(try store.claim(now: now.addingTimeInterval(601))?.url, current)
    }

    func testConcurrentEnqueueAndClaimUseOneOrderedFileQueue() throws {
        let store = try makeStore()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let action: QuickActionRoute.Action = index.isMultiple(of: 2) ? .status : .recovery
            XCTAssertTrue(store.enqueue(action, now: now))
        }
        var claimed: [URL] = []
        while let claim = try store.claim(now: now) {
            claimed.append(claim.url)
            XCTAssertTrue(try store.acknowledge(claim))
        }
        XCTAssertEqual(claimed.count, 8)
    }

    private func makeStore() throws -> QuickActionPendingRouteStore {
        try QuickActionPendingRouteStore(directoryURL: temporaryDirectory())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-lockbox-quick-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
