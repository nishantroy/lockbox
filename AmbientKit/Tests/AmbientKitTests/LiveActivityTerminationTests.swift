import XCTest
@testable import AmbientKit

final class LiveActivityTerminationTests: XCTestCase {
    private let fences = [
        AmbientLiveActivityTerminationFence(
            sessionID: "session-1",
            fixedEnd: Date(timeIntervalSince1970: 100),
            kind: .bedtime
        )
    ]

    func testBatchWaitRunnerReturnsImmediateSuccess() {
        let expectedFences = fences
        let result = AmbientLiveActivityBatchWaitRunner.run(fences: expectedFences) { received in
            _ = received
            return 2
        }
        XCTAssertEqual(result, .ended(count: 2))
    }

    func testBatchWaitRunnerMapsOperationThrowToFailed() {
        enum TestError: Error { case expected }
        let result = AmbientLiveActivityBatchWaitRunner.run(fences: fences) { _ in
            throw TestError.expected
        }
        XCTAssertEqual(result, .failed)
    }

    func testBatchWaitRunnerCanTimeoutWithoutWaitingForOperationToFinish() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = AmbientLiveActivityBatchWaitRunner.run(
            fences: fences,
            waitNanoseconds: 0
        ) { _ in
            started.signal()
            blockCurrentThread(on: release)
            finished.signal()
            return 1
        }

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    }

    func testBatchWaitRunnerUsesOneOperationAndDeduplicatesExactFences() {
        let second = AmbientLiveActivityTerminationFence(
            sessionID: "session-2",
            fixedEnd: Date(timeIntervalSince1970: 200),
            kind: .focus
        )
        let input = [fences[0], second, fences[0]]
        let calls = LockedValue(0)
        let received = LockedValue<[AmbientLiveActivityTerminationFence]>([])
        let result = AmbientLiveActivityBatchWaitRunner.run(fences: input) { batch in
            calls.set(calls.value + 1)
            received.set(batch)
            return 3
        }

        XCTAssertEqual(result, .ended(count: 3))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(received.value, [fences[0], second])
    }

    func testDiagnosticsNormalizeCorruptAndOversizeValues() throws {
        let (defaults, lockURL, suiteName) = try makeDiagnosticsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not-json".utf8), forKey: AmbientLiveActivityDiagnosticsStore.key)
        XCTAssertEqual(AmbientLiveActivityDiagnosticsStore.read(defaults: defaults, lockURL: lockURL), [])

        let entries = (0..<20).map {
            AmbientLiveActivityTerminationDiagnostic(
                observedAt: Date(timeIntervalSince1970: Double($0)),
                result: .ended(count: $0)
            )
        }
        defaults.set(try JSONEncoder().encode(entries), forKey: AmbientLiveActivityDiagnosticsStore.key)
        let normalized = AmbientLiveActivityDiagnosticsStore.read(defaults: defaults, lockURL: lockURL)
        XCTAssertEqual(normalized.count, AmbientLiveActivityDiagnosticsStore.maximumEntries)
        XCTAssertEqual(normalized.first?.observedAt, Date(timeIntervalSince1970: 4))
        XCTAssertEqual(normalized.last?.observedAt, Date(timeIntervalSince1970: 19))
    }

    func testDiagnosticsConcurrentAppendRetainsBoundedEntries() throws {
        let (defaults, lockURL, suiteName) = try makeDiagnosticsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedDefaults = SendableDefaults(defaults)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            AmbientLiveActivityDiagnosticsStore.append(
                .ended(count: index),
                observedAt: Date(timeIntervalSince1970: Double(index)),
                defaults: sharedDefaults.value,
                lockURL: lockURL
            )
        }

        let entries = AmbientLiveActivityDiagnosticsStore.read(defaults: defaults, lockURL: lockURL)
        XCTAssertEqual(entries.count, AmbientLiveActivityDiagnosticsStore.maximumEntries)
    }

    private func makeDiagnosticsStore() throws -> (UserDefaults, URL, String) {
        let suiteName = "phone-lockbox-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-lockbox-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, directory.appendingPathComponent("diagnostics.lock"), suiteName)
    }
}

private func blockCurrentThread(on semaphore: DispatchSemaphore) {
    semaphore.wait()
}

private final class SendableDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) { self.value = value }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) { storedValue = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
