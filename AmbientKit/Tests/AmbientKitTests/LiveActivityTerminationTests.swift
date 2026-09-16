import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    func testDiagnosticsInProcessConcurrentAppendRemainsBounded() throws {
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
        XCTAssertGreaterThan(entries.count, 0)
        XCTAssertLessThanOrEqual(entries.count, AmbientLiveActivityDiagnosticsStore.maximumEntries)
        XCTAssertTrue(entries.allSatisfy { diagnostic in
            if case .ended(let count) = diagnostic.result {
                return (0..<64).contains(count)
            }
            return false
        })
    }

    func testDiagnosticsDropsAppendWhenNoAppGroupProcessLockIsHeld() throws {
        let (defaults, _, suiteName) = try makeDiagnosticsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = [AmbientLiveActivityTerminationDiagnostic(
            observedAt: Date(timeIntervalSince1970: 1),
            result: .ended(count: 1)
        )]
        let initialData = try JSONEncoder().encode(initial)
        defaults.set(initialData, forKey: AmbientLiveActivityDiagnosticsStore.key)
        let sharedDefaults = SendableDefaults(defaults)
        let finished = DispatchSemaphore(value: 0)

        AmbientLiveActivityDiagnosticsStore.withProcessLockHeldForTesting {
            DispatchQueue.global().async {
                AmbientLiveActivityDiagnosticsStore.append(
                    .ended(count: 99),
                    observedAt: Date(timeIntervalSince1970: 99),
                    defaults: sharedDefaults.value,
                    lockURL: nil
                )
                finished.signal()
            }

            XCTAssertEqual(
                finished.wait(timeout: .now() + 1),
                .success,
                "nil-lockURL diagnostics writes must drop rather than wait for the process lock"
            )
            XCTAssertEqual(defaults.data(forKey: AmbientLiveActivityDiagnosticsStore.key), initialData)
        }

        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(defaults.data(forKey: AmbientLiveActivityDiagnosticsStore.key), initialData)
    }

    #if canImport(Darwin) || canImport(Glibc)
    func testDiagnosticsDropsAppendWhenAppGroupLockIsHeld() throws {
        let (defaults, lockURL, suiteName) = try makeDiagnosticsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = [AmbientLiveActivityTerminationDiagnostic(
            observedAt: Date(timeIntervalSince1970: 1),
            result: .ended(count: 1)
        )]
        let initialData = try JSONEncoder().encode(initial)
        defaults.set(initialData, forKey: AmbientLiveActivityDiagnosticsStore.key)

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            XCTFail("could not open diagnostics lock")
            return
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            XCTFail("could not hold diagnostics lock")
            return
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        AmbientLiveActivityDiagnosticsStore.append(
            .ended(count: 99),
            observedAt: Date(timeIntervalSince1970: 99),
            defaults: defaults,
            lockURL: lockURL
        )

        XCTAssertEqual(defaults.data(forKey: AmbientLiveActivityDiagnosticsStore.key), initialData)
    }
    #endif

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
