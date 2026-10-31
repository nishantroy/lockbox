import XCTest
@testable import PhoneLockbox
#if canImport(CompanionKit)
import CompanionKit
#endif

#if canImport(CompanionKit)
/// P3-0 (docs/r5-pairing-v3-plan.md): end-to-end reproduction of the
/// build-21 owner QA failures against a real local relay
/// (`cd relay && npm run db:start && npm run dev`, port 8002):
///   3. People-tab pull-to-refresh showed a relay error on the owner phone.
///   4. "Ask now" never created a request for the friend.
/// Skipped (not failed) when no relay answers on 127.0.0.1:8002.
@MainActor
final class CompanionLocalRelayFlowTests: XCTestCase {
    private static let relayURL = "http://127.0.0.1:8002"

    private func requireRelay() async throws {
        var request = URLRequest(url: URL(string: "\(Self.relayURL)/v1/health")!)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                // The local relay rate-limits to 60 requests/minute per IP
                // and each flow here spends ~20; spacing the tests keeps the
                // suite from tripping `rate_limited`.
                try await Task.sleep(nanoseconds: 22_000_000_000)
                return
            }
        } catch {}
        throw XCTSkip("no local relay on 127.0.0.1:8002")
    }

    private var keyStores: [ObjectIdentifier: (InMemoryDeviceKeyStore, UserDefaults)] = [:]

    private func makeDevice(_ label: String) throws -> CompanionCoordinator {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p30.\(label).\(UUID().uuidString)"))
        let keyStore = InMemoryDeviceKeyStore()
        let coordinator = CompanionCoordinator(keyStore: keyStore, sharedDefaults: defaults)
        keyStores[ObjectIdentifier(coordinator)] = (keyStore, defaults)
        coordinator.relayBaseURLString = Self.relayURL
        return coordinator
    }

    /// Pair + owner grant (as `confirmPendingAcceptance(grantEarlyEndTrust: true)`
    /// does) + approver accept, refreshing like the real app between steps.
    private func pairFullyTrusted(owner: CompanionCoordinator, friend: CompanionCoordinator) async throws {
        await owner.createInvite()
        XCTAssertNil(owner.lastError)
        let invitation = try XCTUnwrap(owner.pendingInvitation)
        await friend.acceptInvite(invitation)
        XCTAssertNil(friend.lastError)
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError, "owner refresh after friend accepted")
        let pending = try XCTUnwrap(owner.pendingOwnerAcceptances.first)
        await owner.confirmPendingAcceptance(pending, nickname: "Friend", grantEarlyEndTrust: true)
        XCTAssertNil(owner.lastError, "confirm + grant")
        await friend.refreshInbox()
        XCTAssertNil(friend.lastError, "friend refresh after confirm")
        let friendPerson = try XCTUnwrap(friend.people.first)
        await friend.setApproverAccept(.approveEarlyEnd, enabled: true, for: friendPerson)
        XCTAssertNil(friend.lastError)
        let friendPerson2 = try XCTUnwrap(friend.people.first)
        await friend.setApproverAccept(.receiveRequests, enabled: true, for: friendPerson2)
        XCTAssertNil(friend.lastError)
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError, "owner refresh after friend consents")
        XCTAssertEqual(owner.trustedApprovers.count, 1)
    }

    func testAskNowReachesFriendAndOwnerRefreshStaysClean() async throws {
        try await requireRelay()
        let owner = try makeDevice("owner"), friend = try makeDevice("friend")
        try await pairFullyTrusted(owner: owner, friend: friend)

        let start = Date().addingTimeInterval(-300), end = Date().addingTimeInterval(3_600)
        await owner.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                    start: start, end: end, to: owner.trustedApprovers)
        XCTAssertNil(owner.lastError, "requestEarlyEnd")

        await friend.refreshInbox()
        XCTAssertNil(friend.lastError, "friend refresh after request")
        XCTAssertEqual(friend.inboxItems.count, 1, "friend inbox must contain the request")

        // Pull-to-refresh on the owner (twice: a fresh fetch, then a repeat).
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError, "owner pull-to-refresh after publish + request")
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError, "second owner pull-to-refresh")
        XCTAssertEqual(owner.inboxItems.count, 1)
    }

    /// A second Ask for the same (unchanged) session replays the identical
    /// session-publish operation (deterministic operation ID); it must still
    /// create the request.
    func testSecondAskForSameSessionStillCreatesRequest() async throws {
        try await requireRelay()
        let owner = try makeDevice("owner"), friend = try makeDevice("friend")
        try await pairFullyTrusted(owner: owner, friend: friend)
        let sessionID = UUID().uuidString, setID = UUID().uuidString
        let start = Date().addingTimeInterval(-300), end = Date().addingTimeInterval(3_600)
        await owner.requestEarlyEnd(sessionID: sessionID, activeSetID: setID, start: start, end: end, to: owner.trustedApprovers)
        XCTAssertNil(owner.lastError, "first ask")
        await owner.requestEarlyEnd(sessionID: sessionID, activeSetID: setID, start: start, end: end, to: owner.trustedApprovers)
        XCTAssertNil(owner.lastError, "second ask (session publish replay)")
        await friend.refreshInbox()
        XCTAssertEqual(friend.inboxItems.count, 2)
    }

    /// Production evidence (build 21): session published and current, no
    /// request. The owner's pull-to-refresh must stay clean in that state,
    /// including when the publish went through the same persisted rollback
    /// anchor the coordinator uses.
    func testOwnerRefreshIsCleanAfterSessionPublishWithoutRequest() async throws {
        try await requireRelay()
        let owner = try makeDevice("owner"), friend = try makeDevice("friend")
        try await pairFullyTrusted(owner: owner, friend: friend)
        let (keyStore, defaults) = try XCTUnwrap(keyStores[ObjectIdentifier(owner)])
        let identity = try XCTUnwrap(owner.ownerIdentity)
        let transport = HTTPCompanionTransport(baseURL: URL(string: Self.relayURL)!, session: URLSession(configuration: .ephemeral),
                                               anchorStore: UserDefaultsRollbackAnchorStore(defaults: defaults), enforceStateRoot: true)
        let client = AsyncCompanionClient(signer: try DeviceSigner(identity: identity, keyStore: keyStore), transport: transport)
        let session = try ActiveSession(owner: identity, sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                        startsAt: Date().addingTimeInterval(-300), endsAt: Date().addingTimeInterval(3_600))
        _ = try await client.publishSession(session)
        _ = try await client.publishSession(session) // idempotent replay
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError, "owner pull-to-refresh with a published session and no request")
        await owner.refreshInbox()
        XCTAssertNil(owner.lastError)
    }

    /// Build-21 root cause for "pull-to-refresh always shows a relay error"
    /// (Vercel showed HTTP 200 for every inbox call): SwiftUI cancels the
    /// `.refreshable` task, `URLSession` throws `URLError.cancelled`, the
    /// transport maps that to `.unavailable` and the banner reads "Couldn't
    /// reach the relay". A cancelled refresh must neither raise a banner nor
    /// lose the fetched data.
    func testCancelledRefreshDoesNotRaiseRelayErrorAndStillLoadsInbox() async throws {
        try await requireRelay()
        let owner = try makeDevice("owner"), friend = try makeDevice("friend")
        try await pairFullyTrusted(owner: owner, friend: friend)
        await owner.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                    start: Date().addingTimeInterval(-300), end: Date().addingTimeInterval(3_600),
                                    to: owner.trustedApprovers)
        XCTAssertNil(owner.lastError)

        let refresh = Task { await owner.refreshInbox() }
        refresh.cancel() // what SwiftUI does to a `.refreshable` closure
        await refresh.value
        XCTAssertNil(owner.lastError, "a cancelled refresh must not show a relay error banner")
        XCTAssertEqual(owner.inboxItems.count, 1, "the fetch still completes and is applied")

        // And overlapping refreshes (`.task` + pull) join one fetch.
        async let first: Void = owner.refreshInbox()
        async let second: Void = owner.refreshInbox()
        _ = await (first, second)
        XCTAssertNil(owner.lastError)
    }

    /// A refresh requested right after a mutation must not be satisfied by
    /// an older in-flight fetch whose response predates that mutation.
    func testRefreshAfterMutationIsNotSatisfiedByStaleInFlightFetch() async throws {
        try await requireRelay()
        let owner = try makeDevice("owner"), friend = try makeDevice("friend")
        try await pairFullyTrusted(owner: owner, friend: friend)
        // Hold the first pass's already-fetched (soon stale) response until a
        // second refresh call -- the one `requestEarlyEnd` makes after its
        // request is created -- has arrived.
        var passes = 0
        let baseline = owner.refreshCallCountForTesting
        owner.inboxFetchGateForTesting = { [unowned owner] in
            passes += 1
            guard passes == 1 else { return }
            while owner.refreshCallCountForTesting < baseline + 2 { await Task.yield() }
        }
        let early = Task { await owner.refreshInbox() }
        await Task.yield()
        await owner.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                    start: Date().addingTimeInterval(-300), end: Date().addingTimeInterval(3_600),
                                    to: owner.trustedApprovers)
        XCTAssertNil(owner.lastError)
        XCTAssertEqual(owner.inboxItems.count, 1, "post-mutation refresh must reflect the new request")
        await early.value
    }
}
#endif
