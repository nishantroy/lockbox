import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    func testEncodedNamesValuesAndQueryOrderAreNotCanonical() {
        let variants = [
            "phonelockbox://quick-action/v1/status?%69ssued=1000000&expires=1000300&nonce=\(nonce)",
            "phonelockbox://quick-action/v1/status?issued=%31%30%30%30%30%30%30&expires=1000300&nonce=\(nonce)",
            "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=123e4567%2De89b%2D12d3%2Da456%2D426614174000",
            "phonelockbox://quick-action/v1/status?expires=1000300&issued=1000000&nonce=\(nonce)"
        ]
        for value in variants {
            XCTAssertNil(QuickActionRoute.parse(URL(string: value)!, now: now), value)
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

final class QuickActionDeliveryGateTests: XCTestCase {
    func testFocusPresentationKeepsMixedRoutesBusyUntilDismissal() {
        let focusA = QuickActionDeliveryGate.Identity(id: "focus-a", action: .focus(.thirtyMinutes))
        let focusB = QuickActionDeliveryGate.Identity(id: "focus-b", action: .focus(.oneHour))
        let status = QuickActionDeliveryGate.Identity(id: "status", action: .status)
        let recovery = QuickActionDeliveryGate.Identity(id: "recovery", action: .recovery)
        var gate = QuickActionDeliveryGate()

        XCTAssertTrue(gate.begin(focusA))
        XCTAssertFalse(gate.begin(focusB))
        XCTAssertFalse(gate.begin(status))
        XCTAssertFalse(gate.begin(recovery))
        XCTAssertTrue(gate.accepts(focusA))
        XCTAssertFalse(gate.accepts(focusB))
        XCTAssertFalse(gate.accepts(status))
        XCTAssertFalse(gate.settle(status))

        XCTAssertTrue(gate.settle(focusA))
        XCTAssertFalse(gate.accepts(focusA), "Callback after dismissal must be harmless")
        XCTAssertTrue(gate.begin(status))
        XCTAssertFalse(gate.begin(recovery))
        XCTAssertTrue(gate.settle(status))
        XCTAssertTrue(gate.begin(recovery))
        XCTAssertTrue(gate.settle(recovery))
    }

    func testOnlyExactIdentityCanSettleAfterAReclaimedDelivery() {
        let oldFocus = QuickActionDeliveryGate.Identity(id: "same-route", action: .focus(.thirtyMinutes))
        let newStatus = QuickActionDeliveryGate.Identity(id: "same-route", action: .status)
        var gate = QuickActionDeliveryGate()

        XCTAssertTrue(gate.begin(oldFocus))
        XCTAssertTrue(gate.settle(oldFocus))
        XCTAssertTrue(gate.begin(newStatus))
        XCTAssertFalse(gate.accepts(oldFocus))
        XCTAssertFalse(gate.settle(oldFocus))
        XCTAssertTrue(gate.settle(newStatus))
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

    func testSettledNonceIsDeduplicatedAfterAcknowledgement() throws {
        let store = try makeStore()
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertTrue(store.enqueue(url, now: now))
        let claim = try XCTUnwrap(store.claim(now: now))
        XCTAssertTrue(try store.acknowledge(claim))
        // The duplicate callback has the same nonce, but it cannot create a
        // second presentation after the original identity settled.
        XCTAssertTrue(store.enqueue(url, now: now.addingTimeInterval(1)))
        XCTAssertNil(try store.claim(now: now.addingTimeInterval(1)))
    }

    func testMixedFocusStatusRecoveryRoutesProgressAfterExactDismissal() throws {
        let store = try makeStore()
        let focus = try XCTUnwrap(QuickActionRoute.url(for: .focus(.thirtyMinutes), now: now))
        let status = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let recovery = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        XCTAssertTrue(store.enqueue(focus, now: now))
        XCTAssertTrue(store.enqueue(status, now: now))
        XCTAssertTrue(store.enqueue(recovery, now: now))

        // A is presenting: later callbacks remain queued behind its exact
        // claim until the destination settles.
        let focusClaim = try XCTUnwrap(store.claim(now: now))
        XCTAssertEqual(focusClaim.url, focus)
        XCTAssertNil(try store.claim(now: now.addingTimeInterval(30)))
        XCTAssertTrue(try store.acknowledge(focusClaim))

        let statusClaim = try XCTUnwrap(store.claim(now: now.addingTimeInterval(30)))
        XCTAssertEqual(statusClaim.url, status)
        XCTAssertTrue(try store.acknowledge(statusClaim))
        let recoveryClaim = try XCTUnwrap(store.claim(now: now.addingTimeInterval(30)))
        XCTAssertEqual(recoveryClaim.url, recovery)
        XCTAssertTrue(try store.acknowledge(recoveryClaim))
    }

    func testClaimRemainsRetryableAcrossCrashBeforeSettlement() throws {
        let store = try makeStore()
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertTrue(store.enqueue(url, now: now))
        let first = try XCTUnwrap(store.claim(now: now))
        // Presentation is not settlement. Simulate a process death after the
        // destination callback but before dismissal: no durable acknowledgement
        // is written, so the route remains retryable.
        XCTAssertNil(try store.claim(now: now.addingTimeInterval(59)))
        let retry = try XCTUnwrap(store.claim(now: now.addingTimeInterval(60)))
        XCTAssertEqual(retry.url, first.url)
        XCTAssertFalse(try store.acknowledge(first))
        XCTAssertTrue(try store.acknowledge(retry))
    }

    func testOversizedQueueFileIsRejectedBeforeDecode() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        let oversized = Data(repeating: 0x20, count: QuickActionPendingRouteStore.maximumQueueBytes + 1)
        try oversized.write(to: queueURL)
        let store = try QuickActionPendingRouteStore(directoryURL: directory)
        XCTAssertThrowsError(try store.claim(now: now))
        XCTAssertEqual(try Data(contentsOf: queueURL), oversized)
    }

    func testHugeEntryCountAndStringAreRejected() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        let entry: [String: Any] = [
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "url": "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&nonce=123e4567-e89b-12d3-a456-426614174000",
            "enqueuedAt": 1_000_000,
            "claimToken": NSNull(),
            "claimUntil": NSNull()
        ]
        let tooMany = ["schemaVersion": 1, "entries": Array(repeating: entry, count: QuickActionPendingRouteStore.maximumEntries + 1)] as [String: Any]
        try JSONSerialization.data(withJSONObject: tooMany).write(to: queueURL)
        let countStore = try QuickActionPendingRouteStore(directoryURL: directory)
        XCTAssertThrowsError(try countStore.claim(now: now))

        let stringDirectory = try temporaryDirectory()
        let stringURL = stringDirectory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        var hugeEntry = entry
        hugeEntry["url"] = String(repeating: "x", count: QuickActionPendingRouteStore.maximumURLBytes + 1)
        let tooLong = ["schemaVersion": 1, "entries": [hugeEntry]] as [String: Any]
        try JSONSerialization.data(withJSONObject: tooLong).write(to: stringURL)
        let stringStore = try QuickActionPendingRouteStore(directoryURL: stringDirectory)
        XCTAssertThrowsError(try stringStore.claim(now: now))
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

    func testWallClockRollbackDropsFutureLeasesAndUnwedgesCapacity() throws {
        let store = try makeStore()
        let original = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        XCTAssertTrue(store.enqueue(original, now: now))
        XCTAssertNotNil(try store.claim(now: now))

        let rolledBack = now.addingTimeInterval(-3_600)
        XCTAssertNil(try store.claim(now: rolledBack))
        let replacement = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: rolledBack))
        XCTAssertTrue(store.enqueue(replacement, now: rolledBack))
        XCTAssertEqual(try store.claim(now: rolledBack)?.url, replacement)
    }

    func testStrictFIFODoesNotOvertakeLeasedHead() throws {
        let store = try makeStore()
        let firstURL = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let secondURL = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        XCTAssertTrue(store.enqueue(firstURL, now: now))
        XCTAssertTrue(store.enqueue(secondURL, now: now))
        let first = try XCTUnwrap(store.claim(now: now))
        XCTAssertNil(try store.claim(now: now.addingTimeInterval(30)))
        let retry = try XCTUnwrap(store.claim(now: now.addingTimeInterval(60)))
        XCTAssertEqual(retry.url, firstURL)
        XCTAssertFalse(try store.acknowledge(first))
        XCTAssertTrue(try store.acknowledge(retry))
        XCTAssertEqual(try store.claim(now: now.addingTimeInterval(60))?.url, secondURL)
    }

#if canImport(Darwin) || canImport(Glibc)
    func testDirectSymlinkIsRejectedWithoutFollowingItsTarget() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        let targetURL = directory.appendingPathComponent("outside.json")
        try Data("not the queue".utf8).write(to: targetURL)
        XCTAssertEqual(targetURL.path.withCString { target in
            queueURL.path.withCString { link in symlink(target, link) }
        }, 0)
        defer { _ = unlink(queueURL.path) }

        let store = try QuickActionPendingRouteStore(directoryURL: directory)
        XCTAssertThrowsError(try store.claim(now: now))
    }

    func testFIFOAndDirectoryQueueReplacementsAreRejectedWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        XCTAssertEqual(queueURL.path.withCString { mkfifo($0, 0o600) }, 0)
        defer { _ = unlink(queueURL.path) }
        let store = try QuickActionPendingRouteStore(directoryURL: directory)
        let started = Date()
        XCTAssertThrowsError(try store.claim(now: now))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)

        _ = unlink(queueURL.path)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: queueURL) }
        XCTAssertThrowsError(try store.claim(now: now))
    }

    func testReplacementRaceNeverReadsSymlinkTargetAndReturnsPromptly() throws {
        let directory = try temporaryDirectory()
        let queueURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.json")
        let outsideURL = directory.appendingPathComponent("outside.json")
        let statusURL = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let recoveryURL = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        let statusEntry: [String: Any] = [
            "id": QuickActionRoute.parse(statusURL, now: now)!.id,
            "url": statusURL.absoluteString,
            "enqueuedAt": 1_000_000,
            "claimToken": NSNull(),
            "claimUntil": NSNull()
        ]
        let recoveryEntry: [String: Any] = [
            "id": QuickActionRoute.parse(recoveryURL, now: now)!.id,
            "url": recoveryURL.absoluteString,
            "enqueuedAt": 1_000_000,
            "claimToken": NSNull(),
            "claimUntil": NSNull()
        ]
        let statusData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [statusEntry]])
        let recoveryData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [recoveryEntry]])
        try statusData.write(to: queueURL)
        try recoveryData.write(to: outsideURL)
        let store = try QuickActionPendingRouteStore(directoryURL: directory)
        let stop = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { finished.signal() }
            for _ in 0..<250 {
                if stop.wait(timeout: .now()) == .success { return }
                _ = unlink(queueURL.path)
                _ = queueURL.path.withCString { link in symlink(outsideURL.path, link) }
                usleep(100)
                _ = unlink(queueURL.path)
                try? statusData.write(to: queueURL)
            }
        }

        var unexpectedRoutes: [URL] = []
        for _ in 0..<250 {
            do {
                if let claim = try store.claim(now: now), claim.url != statusURL {
                    unexpectedRoutes.append(claim.url)
                }
            } catch {
                // Symlink/nonregular replacement is expected to fail closed.
            }
        }
        stop.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(unexpectedRoutes.isEmpty, "Opened a replacement target: \(unexpectedRoutes)")
    }

    func testPreRenameWriteFailuresLeaveNoQueueMutation() throws {
        let failures: [QuickActionPendingRouteStore.WriteFailureInjection] = [.write, .fileSync, .close, .rename]
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        for failure in failures {
            let directory = try temporaryDirectory()
            let store = try QuickActionPendingRouteStore(directoryURL: directory, failureInjection: failure)
            XCTAssertFalse(store.enqueue(url, now: now), "Unexpected success for \(failure)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("phone-lockbox.quick-action-queue.json").path))
        }
    }

    func testDirectorySyncFailureReportsCommittedMutationAndDoesNotDuplicate() throws {
        let directory = try temporaryDirectory()
        let url = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let failingStore = try QuickActionPendingRouteStore(directoryURL: directory, failureInjection: .directorySync)
        XCTAssertTrue(failingStore.enqueue(url, now: now))
        let claim = try XCTUnwrap(failingStore.claim(now: now))
        XCTAssertTrue(try failingStore.acknowledge(claim))

        let relaunchedStore = try QuickActionPendingRouteStore(directoryURL: directory)
        XCTAssertNil(try relaunchedStore.claim(now: now))
        XCTAssertTrue(relaunchedStore.enqueue(url, now: now))
        XCTAssertNil(try relaunchedStore.claim(now: now))
    }
#endif

    func testQueueAndLockFilesUseTheDocumentedProtectionContract() throws {
        let directory = try temporaryDirectory()
        _ = try QuickActionPendingRouteStore(directoryURL: directory)
        let fileManager = FileManager.default
        let lockURL = directory.appendingPathComponent("phone-lockbox.quick-action-queue.lock")
        XCTAssertTrue(fileManager.fileExists(atPath: lockURL.path))
#if os(iOS)
        let protection = try fileManager.attributesOfItem(atPath: lockURL.path)[.protectionKey] as? FileProtectionType
        if let protection {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        } else {
            // The simulator does not expose Data Protection metadata; the
            // signed-device gate must inspect this attribute on real storage.
            throw XCTSkip("Simulator does not expose NSFileProtection metadata")
        }
#endif
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
