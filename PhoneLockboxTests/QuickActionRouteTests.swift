import XCTest
@testable import PhoneLockbox

final class QuickActionRouteTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testBoundedFocusRoutesRoundTripToRequestedPreset() throws {
        for preset in [QuickActionRoute.FocusPreset.thirtyMinutes, .oneHour] {
            let url = try XCTUnwrap(QuickActionRoute.url(for: .focus(preset), now: now))
            let route = try XCTUnwrap(QuickActionRoute.parse(url, now: now))
            XCTAssertEqual(route.action, .focus(preset))
            XCTAssertGreaterThan(route.expiresAt, now)
        }
    }

    func testStatusAndRecoveryRoutesRoundTripWithoutEnforcementMeaning() throws {
        let statusURL = try XCTUnwrap(QuickActionRoute.url(for: .status, now: now))
        let recoveryURL = try XCTUnwrap(QuickActionRoute.url(for: .recovery, now: now))
        XCTAssertEqual(QuickActionRoute.parse(statusURL, now: now)?.action, .status)
        XCTAssertEqual(QuickActionRoute.parse(recoveryURL, now: now)?.action, .recovery)
    }

    func testExpiredAndFutureRoutesFailClosed() throws {
        let url = try XCTUnwrap(QuickActionRoute.url(for: .focus(.thirtyMinutes), now: now))
        let route = try XCTUnwrap(QuickActionRoute.parse(url, now: now))
        XCTAssertNil(QuickActionRoute.parse(url, now: route.expiresAt))
        XCTAssertNil(QuickActionRoute.parse(url, now: now.addingTimeInterval(-60)))
    }

    func testUnknownVersionPathAndQueryFailClosed() throws {
        let urls = [
            URL(string: "phonelockbox://quick-action/v2/focus?issued=1000000&expires=1000300&duration=30")!,
            URL(string: "phonelockbox://quick-action/v1/focus?issued=1000000&expires=1000300&duration=90")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&duration=30")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&extra=yes")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000300&expires=1000301")!
        ]
        for url in urls {
            XCTAssertNil(QuickActionRoute.parse(url, now: now), "Unexpectedly accepted \(url)")
        }
    }

    func testWrongSchemeHostAndMalformedTimestampFailClosed() {
        let urls = [
            URL(string: "https://quick-action/v1/status?issued=1000000&expires=1000300")!,
            URL(string: "phonelockbox://other/v1/status?issued=1000000&expires=1000300")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=not-a-date&expires=1000300")!,
            URL(string: "phonelockbox://quick-action/v1/status?issued=1000000&expires=1000000")!
        ]
        for url in urls {
            XCTAssertNil(QuickActionRoute.parse(url, now: now))
        }
    }
}
