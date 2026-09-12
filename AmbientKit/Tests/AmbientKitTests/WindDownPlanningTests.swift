import XCTest
@testable import AmbientKit

final class WindDownPlanningTests: XCTestCase {
    private func configuration(
        enabled: Bool = true,
        hour: Int = 22,
        minute: Int = 0,
        leadMinutes: Int = 30
    ) throws -> WindDownConfiguration {
        WindDownConfiguration(
            enabled: enabled,
            bedtime: try AmbientLocalTime(hour: hour, minute: minute),
            lead: try WindDownLeadOffset(minutes: leadMinutes)
        )
    }

    private func calendar(_ identifier: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func testPlannedTriggerRetainsAbsoluteInstantAfterCalendarChange() throws {
        var eastern = calendar("America/New_York")
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let occurrence = try XCTUnwrap(WindDownPlanner.plan(
            configuration: configuration(), now: now, calendar: eastern, limit: 1
        ).first)
        eastern.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNotEqual(eastern.timeZone, occurrence.triggerComponents.timeZone)
        XCTAssertEqual(occurrence.triggerComponents.calendar?.identifier, .gregorian)
        XCTAssertEqual(occurrence.triggerComponents.timeZone?.identifier, "America/New_York")
        XCTAssertEqual(occurrence.triggerComponents.date, occurrence.triggerDate)
        XCTAssertEqual(occurrence.triggerDate, ISO8601DateFormatter().date(from: "2026-01-02T02:30:00Z"))
    }

    func testDisabledConfigurationPlansNothing() throws {
        let config = try configuration(enabled: false)
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        XCTAssertTrue(try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar()).isEmpty)
    }

    func testOnlyUpcomingTriggersArePlannedAndIDsAreStable() throws {
        let config = try configuration()
        let now = ISO8601DateFormatter().date(from: "2026-01-01T21:45:00Z")!
        let planned = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 7)

        XCTAssertEqual(planned.count, 7)
        XCTAssertEqual(planned[0].triggerDate, ISO8601DateFormatter().date(from: "2026-01-02T21:30:00Z"))
        XCTAssertTrue(planned.allSatisfy { $0.triggerDate > now })
        XCTAssertEqual(planned.map(\.identifier).count, Set(planned.map(\.identifier)).count)
        XCTAssertEqual(
            planned[0].identifier,
            "com.phone-lockbox.ambient.wind-down.2026-01-02-22-00"
        )

        let again = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 7)
        XCTAssertEqual(planned, again)
    }

    func testCrossMidnightActiveSessionDoesNotGetDelayedHeadsUp() throws {
        let config = try configuration(hour: 22, minute: 0)
        let now = ISO8601DateFormatter().date(from: "2026-01-02T01:00:00Z")!
        let active = try AmbientSessionBoundary(
            start: ISO8601DateFormatter().date(from: "2026-01-01T22:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-01-02T07:00:00Z")!
        )
        let planned = try WindDownPlanner.plan(
            configuration: config,
            now: now,
            calendar: calendar(),
            activeSession: active,
            limit: 2
        )

        XCTAssertEqual(planned.first?.triggerDate, ISO8601DateFormatter().date(from: "2026-01-02T21:30:00Z"))
        XCTAssertTrue(planned.allSatisfy { $0.triggerDate > now })
    }

    func testLeadOffsetValidation() throws {
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 0))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: -1))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: .infinity))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 0.5))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 24 * 60 * 60 + 1))
        XCTAssertNoThrow(try WindDownLeadOffset(seconds: 1))
    }

    func testUTCAndDSTCalendarValuesBecomeConcreteTriggerComponents() throws {
        var eastern = calendar("America/New_York")
        let config = try configuration(hour: 2, minute: 30, leadMinutes: 30)
        let springNow = ISO8601DateFormatter().date(from: "2026-03-07T12:00:00Z")!
        let spring = try WindDownPlanner.plan(configuration: config, now: springNow, calendar: eastern, limit: 3)
        XCTAssertEqual(spring[0].triggerComponents.timeZone?.identifier, "America/New_York")
        XCTAssertEqual(spring[0].triggerComponents.hour, 3) // 02:30 normalizes through the skipped hour.
        XCTAssertEqual(spring[0].triggerDate, ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z"))

        eastern.timeZone = TimeZone(identifier: "UTC")!
        let utc = try WindDownPlanner.plan(configuration: config, now: springNow, calendar: eastern, limit: 1)
        XCTAssertEqual(utc[0].triggerComponents.timeZone?.secondsFromGMT(), 0)
        XCTAssertEqual(utc[0].triggerDate, ISO8601DateFormatter().date(from: "2026-03-08T02:00:00Z"))
    }

    func testReplacementRemovesOnlyOwnNamespaceAndDoesNotDuplicate() throws {
        let config = try configuration()
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let occurrences = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 2)
        let replacement = try WindDownNotificationReplacement(
            existingPendingIdentifiers: [
                "other.app.reminder",
                occurrences[0].identifier,
                "com.phone-lockbox.ambient.wind-down.old"
            ],
            occurrences: occurrences
        )

        XCTAssertEqual(
            replacement.removeIdentifiers,
            [occurrences[0].identifier, "com.phone-lockbox.ambient.wind-down.old"].sorted()
        )
        XCTAssertEqual(replacement.addIdentifiers, occurrences.map(\.identifier))
        XCTAssertThrowsError(
            try WindDownNotificationReplacement(existingPendingIdentifiers: [], occurrences: [occurrences[0], occurrences[0]])
        )
    }
}

final actor FakeNotificationCenter: WindDownNotificationStore {
    struct Request: Equatable, Sendable {
        let identifier: String
    }

    private var pending: [Request]
    private let failingIdentifier: String?

    init(pending: [Request], failingIdentifier: String? = nil) {
        self.pending = pending
        self.failingIdentifier = failingIdentifier
    }

    func pendingRequests() async -> [Request] { pending }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: Request) async throws {
        if request.identifier == failingIdentifier {
            throw FakeError.addFailed
        }
        pending.append(request)
    }

    func snapshot() -> [Request] { pending }

    enum FakeError: Error {
        case addFailed
    }
}

final class WindDownReplacementTransactionTests: XCTestCase {
    private let prefix = WindDownNotificationNamespace.prefix

    func testFullSystemQueueFailsBeforeRemovingOwnedRequests() async throws {
        let owned = FakeNotificationCenter.Request(identifier: prefix + "old")
        let other = (0..<63).map { FakeNotificationCenter.Request(identifier: "other.\($0)") }
        let center = FakeNotificationCenter(pending: [owned] + other)
        let requests = [
            FakeNotificationCenter.Request(identifier: prefix + "new-1"),
            FakeNotificationCenter.Request(identifier: prefix + "new-2")
        ]

        do {
            _ = try await WindDownNotificationReplacementEngine.replace(
                store: center,
                requests: requests,
                identifier: \.identifier
            )
            XCTFail("A full queue must reject replacement before mutation")
        } catch {
            XCTAssertEqual(
                error as? WindDownPlanningError,
                .insufficientQueueCapacity(available: 1, requested: 2)
            )
        }
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot, [owned] + other)
    }

    func testNthAddFailureRestoresOldOwnedRequestsAndReportsUnchanged() async throws {
        let old = [
            FakeNotificationCenter.Request(identifier: prefix + "old-1"),
            FakeNotificationCenter.Request(identifier: prefix + "old-2")
        ]
        let retained = FakeNotificationCenter.Request(identifier: "other.app")
        let center = FakeNotificationCenter(
            pending: old + [retained],
            failingIdentifier: prefix + "new-2"
        )
        let requests = [
            FakeNotificationCenter.Request(identifier: prefix + "new-1"),
            FakeNotificationCenter.Request(identifier: prefix + "new-2"),
            FakeNotificationCenter.Request(identifier: prefix + "new-3")
        ]

        let result = try await WindDownNotificationReplacementEngine.replace(
            store: center,
            requests: requests,
            identifier: \.identifier
        )

        XCTAssertEqual(
            result,
            .failed(requestedCount: 3, addedCount: 1, previousScheduleRestored: true)
        )
        let snapshot = await center.snapshot().map(\.identifier).sorted()
        XCTAssertEqual(snapshot, (old + [retained]).map(\.identifier).sorted())
    }
}

final class LiveActivityModelTests: XCTestCase {
    func testFixedEndBecomesStaleWithoutClaimingRelease() {
        let end = Date(timeIntervalSince1970: 100)
        let state = AmbientActivityContentState(fixedEnd: end, status: .plannedSession)
        XCTAssertEqual(state.staleIfNeeded(at: Date(timeIntervalSince1970: 100)), .init(fixedEnd: end, status: .stale))
        XCTAssertEqual(
            AmbientActivityContentState(fixedEnd: end, status: .releaseObserved).staleIfNeeded(at: Date(timeIntervalSince1970: 200)).status,
            .releaseObserved
        )
    }

    func testLongSessionIsReportedAsPotentiallyStale() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AmbientLiveActivityPolicy.lifetime(for: Date(timeIntervalSince1970: 8 * 60 * 60 + 1), now: now),
            .mayBecomeStaleAfterEightHours
        )
    }

    func testNotificationCopyUsesConcreteLeadAndPlannedLocalBedtime() throws {
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let config = WindDownConfiguration(
            enabled: true,
            bedtime: try AmbientLocalTime(hour: 22, minute: 0),
            lead: try WindDownLeadOffset(minutes: 30)
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_US_POSIX")
        let occurrence = try XCTUnwrap(WindDownPlanner.plan(
            configuration: config,
            now: now,
            calendar: utc,
            limit: 1
        ).first)
        let copy = try WindDownNotificationContent(occurrence: occurrence, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(copy.title, "Bedtime in 30 minutes")
        XCTAssertEqual(
            copy.body.replacingOccurrences(of: "\u{202F}", with: " "),
            "Lockbox starts at 10:00 PM."
        )
    }

    func testLiveActivityPresentationUsesOriginIconsAndConciseStates() {
        let bedtime = AmbientLiveActivityPresentation(kind: .bedtime, status: .plannedSession, isStale: false)
        XCTAssertEqual(bedtime.title, "Get some rest")
        XCTAssertEqual(bedtime.compactIconName, "moon.fill")
        XCTAssertNil(bedtime.demoIndicator)
        XCTAssertNil(bedtime.recoveryText)

        let focusRecovery = AmbientLiveActivityPresentation(kind: .focus, status: .recoveryPending, isStale: false)
        XCTAssertEqual(focusRecovery.title, "Focus time")
        XCTAssertEqual(focusRecovery.compactIconName, "lock.fill")
        XCTAssertEqual(focusRecovery.recoveryText, "Recovery requested")
        XCTAssertFalse(focusRecovery.accessibilityLabel.contains("PLAN"))
        XCTAssertFalse(focusRecovery.accessibilityLabel.contains("REC"))

        let demo = AmbientLiveActivityPresentation(kind: .demo, status: .plannedSession, isStale: false)
        XCTAssertEqual(demo.compactIconName, "testtube.2")
        XCTAssertEqual(demo.demoIndicator, "Demo")
        let stale = AmbientLiveActivityPresentation(kind: .bedtime, status: .recoveryPending, isStale: true)
        XCTAssertEqual(stale.title, "Status may be out of date")
        XCTAssertEqual(stale.staleActionText, "Open Phone Lockbox")
        XCTAssertNil(stale.recoveryText)
        XCTAssertFalse(stale.accessibilityLabel.contains("PLAN"))
        XCTAssertFalse(stale.accessibilityLabel.contains("STALE"))
    }

    func testActivityAttributesCarryImmutableValidatedKind() throws {
        let end = Date(timeIntervalSince1970: 100)
        let attributes = AmbientLiveActivityAttributes(sessionID: "session", fixedEnd: end, kind: .bedtime)
        XCTAssertEqual(attributes.origin, .bedtime)
        let encoded = try JSONEncoder().encode(attributes)
        XCTAssertEqual(try JSONDecoder().decode(AmbientLiveActivityAttributes.self, from: encoded), attributes)
        XCTAssertThrowsError(try JSONDecoder().decode(
            AmbientLiveActivityAttributes.self,
            from: Data(#"{"sessionID":"session","fixedEnd":100,"kind":"unknown"}"#.utf8)
        ))
        XCTAssertEqual(
            AmbientLiveActivityPolicy.updateRejection(
                attributes: attributes,
                requestedFixedEnd: end,
                status: .plannedSession,
                requestedKind: .focus
            ),
            .kindMismatch
        )
    }

    func testLiveActivityUpdatesCannotMoveEndOrClaimUnobservedRelease() {
        let end = Date(timeIntervalSince1970: 100)
        let attributes = AmbientLiveActivityAttributes(sessionID: "session", fixedEnd: end, kind: .focus)
        XCTAssertEqual(
            AmbientLiveActivityPolicy.updateRejection(
                attributes: attributes,
                requestedFixedEnd: Date(timeIntervalSince1970: 101),
                status: .plannedSession
            ),
            .fixedEndMismatch
        )
        XCTAssertEqual(
            AmbientLiveActivityPolicy.updateRejection(
                attributes: attributes,
                requestedFixedEnd: end,
                status: .releaseObserved
            ),
            .releaseObservationRequired
        )
        XCTAssertEqual(
            AmbientLiveActivityPolicy.startRejection(status: .releaseObserved),
            .releaseObservationRequired
        )
    }
}
