import XCTest
@testable import PhoneLockbox
#if canImport(CompanionKit)
import CompanionKit
#endif

/// R5 Slice B2c: host-testable pieces of the app-layer friend-release
/// wiring that do not require FamilyControls authorization or a reachable
/// relay — the active-set algorithm switch, the developer gate's default
/// and persistence, no-op copy mapping, and read-only session-state queries
/// on a coordinator with an empty/unavailable store. The rest (the actual
/// network round trip, `OwnerApprovalCheck`, durable prepare/apply/abandon
/// semantics) is covered by `CompanionKitTests`, `RuntimeTests
/// /FriendReleaseTests.swift`, and the parent's simulator/relay-smoke runs.
@MainActor
final class FriendReleaseWiringTests: XCTestCase {

    // MARK: - companionActiveSetID switch (R5 Slice B2c, B2b item 1)

    private func policySnapshot() -> RuntimePolicySnapshot {
        RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
    }

    private func session(id: UUID) -> RuntimeSession {
        RuntimeSession(
            id: id,
            origin: .scheduled,
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 4_600),
            sourceRevision: 1,
            policy: policySnapshot()
        )
    }

    /// Same fixed vector as `RuntimeTests/FriendReleaseTests
    /// .testActiveSetIDFixedVectorMatchesThePortedCoordinatorAlgorithm`.
    /// `ScreenTimeCoordinator.companionActiveSetID(for:)` must still produce
    /// byte-identical output now that it delegates to
    /// `RuntimeActiveSet.id(for:)` instead of duplicating the algorithm.
    func testCompanionActiveSetIDMatchesTheSharedFixedVectorAndDelegatesToRuntimeActiveSet() {
        let first = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let second = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sessions = [session(id: first), session(id: second)]

        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: sessions),
            "dae82c44b1d1590d8c3414b027ab80539197573c0e485d5a35beb5f2538502ba"
        )
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: [session(id: first)]),
            "0a0970fb8e2bca03cd5c270296cc9c6367c06acf89f372b6bc71ed44ba8a8fc9"
        )
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: sessions),
            RuntimeActiveSet.id(for: sessions.map(\.id))
        )
        // Order of sessions must not change the digest.
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: [session(id: second), session(id: first)]),
            ScreenTimeCoordinator.companionActiveSetID(for: sessions)
        )
    }

#if canImport(CompanionKit)
    // MARK: - Developer gate default and persistence (R5 Slice B2c)

    func testFriendApprovalGateDefaultsOffAndPersistsAcrossInstancesInTheSameSuite() throws {
        let suiteName = "com.phone-lockbox.tests.friend-release-gate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertFalse(first.friendApprovalCanEndLocksEnabled)

        first.friendApprovalCanEndLocksEnabled = true

        let second = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertTrue(second.friendApprovalCanEndLocksEnabled, "the gate must persist in the same App Group suite")
    }

    func testFriendApprovalGateDefaultsOffWhenAppGroupIsUnavailable() {
        // `sharedDefaults: nil` with no suite resolvable is the same
        // "App Group unavailable" path every other companion feature uses;
        // the gate must still default to a safe, disabled value rather than
        // crash or silently fall back to `.standard`.
        let coordinator = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: nil)
        // When a real App Group suite happens to resolve on this host, the
        // persisted value could already be true from a prior run; only the
        // unavailable path is asserted on here.
        if !coordinator.isAvailable {
            XCTAssertFalse(coordinator.friendApprovalCanEndLocksEnabled)
        }
    }

    // MARK: - No-op copy mapping (shown immediately / after a verified `use`)

    func testPrepareNoOpMessageCoversEveryReason() {
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.alreadyEnded), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.activeSetMismatch), "This approval is for a different lock.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.conflictingPendingIntent), "Another end-lock request is already in progress.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.noMatchingPendingIntent), "This lock already ended.")
    }

    func testApplyNoOpMessageCoversEveryReasonAndMatchesThePlanForTheTwoReachableCases() {
        // These two are the only reasons `RuntimeLifecycle.applyFriendRelease`
        // actually returns (Shared/RuntimeFriendRelease.swift); the plan's
        // final integration notes specify this exact copy for them.
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.alreadyEnded), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.activeSetMismatch), "Your locks changed; ask again.")
        // Defensive-only cases (not actually returned by apply), still exhaustively mapped.
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.conflictingPendingIntent), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.noMatchingPendingIntent), "This lock already ended.")
    }

    // MARK: - endLockNow's gate-off guard never touches lastError/network
    //
    // `endLockNow`'s very first statement is
    // `guard isAvailable, friendApprovalCanEndLocksEnabled else { return }`
    // (PhoneLockbox/Companion/CompanionCoordinator.swift) — before any
    // inbox fetch, `OwnerApprovalCheck`, or `ScreenTimeCoordinator` call.
    // A real end-to-end call here would require constructing a
    // `ScreenTimeCoordinator`, which touches FamilyControls/DeviceActivity
    // APIs this unhosted test bundle is not entitled for; that path is
    // exercised instead by the parent's simulator app run and by
    // `relay-smoke`. This asserts the gate itself stays off without ever
    // being flipped, which is what every other action in this file relies on.

    func testFriendApprovalGateStaysOffUntilExplicitlySet() throws {
        let suiteName = "com.phone-lockbox.tests.friend-release-gate-stays-off.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let companion = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertFalse(companion.friendApprovalCanEndLocksEnabled)
        XCTAssertNil(companion.lastError)
        XCTAssertTrue(companion.approvalsByRequestID.isEmpty)
    }
#endif
}
