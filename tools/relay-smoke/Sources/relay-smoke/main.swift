import Foundation
import CryptoKit
import CompanionKit

// relay-smoke: a small, reusable end-to-end smoke test for the R5 companion
// relay (docs/r5-relay-plan.md). It drives two fresh, in-memory, throwaway
// identities (an owner and a helper) through the same flow
// `CompanionCoordinator` drives in the app: invite, accept, confirm, learn
// the pairing, consent, publish an exact session, request an early end,
// approve, and revoke.
//
// R5 pairing v2 (docs/r5-pairing-v2-plan.md's "Slice P2a"): confirm no
// longer uses an out-of-band/typed verification code. The owner learns of
// the helper's acceptance only through its own anchored inbox fetch
// (`pendingAcceptances`), verifies it locally with `OwnerAcceptanceCheck`,
// and confirms with the code that check derives -- exactly the path the app
// takes, with no code ever read or typed by a human.
//
// Nothing here is persisted: identities live only in `InMemoryDeviceKeyStore`,
// and the owner's rollback anchor lives only in `InMemoryRollbackAnchorStore`.
// No Keychain and no App Group are touched.
//
// Usage: swift run --package-path tools/relay-smoke relay-smoke [baseURL]
// Default base URL: http://127.0.0.1:8002

// MARK: - CLI

let defaultBaseURL = "http://127.0.0.1:8002"
let baseURLString = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultBaseURL
guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil, baseURL.host != nil else {
    print("FAIL startup: invalid base URL \(baseURLString)")
    exit(1)
}

// MARK: - Step tracking

/// Prints one PASS/FAIL line per step and tallies failures. Never prints raw
/// keys, signatures, or identifiers; only short prefixes when a value needs
/// to appear at all.
final class StepTracker {
    private(set) var failureCount = 0

    func pass(_ name: String) {
        print("PASS \(name)")
    }

    func fail(_ name: String, _ reason: String) {
        failureCount += 1
        print("FAIL \(name): \(reason)")
    }
}

let tracker = StepTracker()

enum SmokeError: Error, CustomStringConvertible {
    case unexpected(String)
    var description: String {
        switch self { case .unexpected(let message): return message }
    }
}

/// Runs one step, expecting it to succeed. `@MainActor` on the closure
/// matches top-level code's implicit main-actor isolation (the flow state
/// below is a sequence of top-level `var`s, not thread-shared).
@MainActor
func step(_ name: String, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
        tracker.pass(name)
    } catch {
        tracker.fail(name, "\(error)")
    }
}

/// Runs one step, expecting it to throw. Used for the deliberate-rejection
/// checks (wrong verification code, duplicate approval).
@MainActor
func expectRejection(_ name: String, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
        tracker.fail(name, "expected a rejection, but the call succeeded")
    } catch {
        tracker.pass(name)
    }
}

func shortPrefix(_ value: String) -> String { String(value.prefix(8)) }

// MARK: - Companion active-set ID (mirrors Shared/RuntimeFriendRelease.swift)

/// Copied from `RuntimeActiveSet.id(for:)` in `Shared/RuntimeFriendRelease.swift`
/// (which in turn must stay byte-identical to
/// `ScreenTimeCoordinator.companionActiveSetID(for:)`). This tool owns only
/// `tools/relay-smoke/**`, so the algorithm is duplicated here rather than
/// importing `Shared`, exactly as the app-layer code documents it must.
/// `SHA256("PhoneLockbox.active-set.v1" || "|" || sorted session ID
/// uuidStrings joined by "|")`.
func companionActiveSetID(for sessionIDs: [UUID]) -> String {
    let sortedIDs = sessionIDs.map { $0.uuidString }.sorted()
    let input = (["PhoneLockbox.active-set.v1"] + sortedIDs).joined(separator: "|")
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Identities and transports

let ownerKeyStore = InMemoryDeviceKeyStore()
let helperKeyStore = InMemoryDeviceKeyStore()
let ownerAnchorStore = InMemoryRollbackAnchorStore()
let httpSession = URLSession(configuration: .ephemeral)

var ownerSigner: DeviceSigner?
var helperSigner: DeviceSigner?

do {
    ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeyStore)
    helperSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: helperKeyStore)
} catch {
    print("FAIL startup: could not create throwaway identities: \(error)")
    exit(1)
}

guard let ownerSigner, let helperSigner else {
    print("FAIL startup: identities unavailable")
    exit(1)
}

print("relay-smoke: base URL \(baseURLString), owner \(shortPrefix(ownerSigner.identity.identityID))…, helper \(shortPrefix(helperSigner.identity.identityID))…")

func makeOwnerClient() -> AsyncCompanionClient {
    let transport = HTTPCompanionTransport(baseURL: baseURL, session: httpSession,
                                           anchorStore: ownerAnchorStore, enforceStateRoot: true)
    return AsyncCompanionClient(signer: ownerSigner, transport: transport)
}

func makeHelperClient() -> AsyncCompanionClient {
    // The helper is never anchored on this device (only owner-signed
    // operations are folded into a rollback anchor — see
    // `HTTPCompanionTransport.validateAnchor`), so no anchor store is needed.
    let transport = HTTPCompanionTransport(baseURL: baseURL, session: httpSession)
    return AsyncCompanionClient(signer: helperSigner, transport: transport)
}

let ownerClient = makeOwnerClient()
let helperClient = makeHelperClient()

// MARK: - Flow state

var invitation: Invitation?
var pendingAcceptance: SignedAcceptance?
var derivedVerificationCode: String?
var pairing: Pairing?
var ownerConsent: RelationshipConsent?
var helperConsent: RelationshipConsent?
var publishedSession: ActiveSession?
var request: TrustedRequest?
var approval: Approval?
var ownerCachedConsent: RelationshipConsent?
var useID: String?
var firstVerification: ApprovalVerification?

// MARK: - 1. Health

await step("GET /v1/health") {
    let transport = HTTPCompanionTransport(baseURL: baseURL, session: httpSession)
    guard try await transport.health() else { throw SmokeError.unexpected("health check returned false") }
}

// MARK: - 2. Invite and accept

await step("owner creates an invite") {
    invitation = try await ownerClient.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date())
}

await step("helper accepts the invite") {
    guard let invitation else { throw SmokeError.unexpected("no invitation to accept") }
    // The returned acceptance is discarded here on purpose: the owner never
    // sees it out of band. The owner only ever learns of it through its own
    // inbox fetch below (R5 pairing v2, docs/r5-pairing-v2-plan.md's "Slice
    // P2a"), exactly as the real app does.
    _ = try await helperClient.accept(invitation, acceptanceID: UUID().uuidString, now: Date())
}

// MARK: - 3. Owner's inbox delivers the pending acceptance; OwnerAcceptanceCheck
// verifies it and derives the code locally, with no out-of-band/typed code.

await step("owner's inbox delivers the pending acceptance") {
    guard let invitation else { throw SmokeError.unexpected("no invitation") }
    let response = try await ownerClient.fetchInboxResponse()
    guard let entry = response.pendingAcceptances?.first(where: { $0.acceptance.inviteID == invitation.payload.inviteID }) else {
        throw SmokeError.unexpected("owner inbox did not deliver the pending acceptance")
    }
    pendingAcceptance = entry
}

await step("OwnerAcceptanceCheck verifies the inbox-delivered acceptance and derives the code") {
    guard let invitation, let pendingAcceptance else { throw SmokeError.unexpected("missing invitation or pending acceptance") }
    derivedVerificationCode = try OwnerAcceptanceCheck.verify(signedAcceptance: pendingAcceptance, invite: invitation,
                                                              ownerIdentity: ownerSigner.identity, now: Date())
}

// MARK: - 4. Confirm: wrong code rejected, then the locally derived code

await expectRejection("confirm rejects a wrong verification code") {
    guard let pendingAcceptance, let derivedVerificationCode else { throw SmokeError.unexpected("no derived verification code") }
    let wrongCode = derivedVerificationCode == "000000" ? "111111" : "000000"
    _ = try await ownerClient.confirm(pendingAcceptance.acceptance, verificationCode: wrongCode, now: Date())
}

await step("confirm accepts the inbox-delivered acceptance using the locally derived code") {
    guard let pendingAcceptance, let derivedVerificationCode else { throw SmokeError.unexpected("no derived verification code") }
    pairing = try await ownerClient.confirm(pendingAcceptance.acceptance, verificationCode: derivedVerificationCode, now: Date())
}

await step("the confirmed pending acceptance no longer appears in the owner's inbox") {
    guard let invitation else { throw SmokeError.unexpected("no invitation") }
    let response = try await ownerClient.fetchInboxResponse()
    guard (response.pendingAcceptances ?? []).contains(where: { $0.acceptance.inviteID == invitation.payload.inviteID }) == false else {
        throw SmokeError.unexpected("owner inbox still delivered the confirmed acceptance")
    }
}

// MARK: - 5. Helper learns the pairing from its inbox

await step("helper learns the pairing from its inbox") {
    guard let pairing else { throw SmokeError.unexpected("no confirmed pairing") }
    let response = try await helperClient.fetchInboxResponse()
    guard let learned = response.pairings?.first(where: { $0.pairingID == pairing.pairingID }) else {
        throw SmokeError.unexpected("helper inbox did not report the pairing")
    }
    guard learned.state == .active else {
        throw SmokeError.unexpected("learned pairing is not active")
    }
}

// MARK: - 6. Consent both sides; owner's anchored inbox shows both

await step("owner grants approveEarlyEnd and receiveRequests") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    ownerConsent = try await ownerClient.grantScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
}

await step("helper accepts approveEarlyEnd and receiveRequests") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    helperConsent = try await helperClient.acceptScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
}

await step("owner's anchored inbox shows bilateral consent") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    let response = try await ownerClient.fetchInboxResponse()
    guard let consent = response.consents?.first(where: { $0.pairingID == pairing.pairingID }) else {
        throw SmokeError.unexpected("owner inbox did not report consent")
    }
    guard consent.authorizes(.approveEarlyEnd), consent.authorizes(.receiveRequests) else {
        throw SmokeError.unexpected("consent is not bilaterally active for both scopes")
    }
}

// MARK: - 7. Publish an exact session and request an early end

await step("owner publishes an exact session") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    _ = pairing // silence unused warning if reordered later
    let sessionID = UUID()
    let now = Date()
    let activeSetID = companionActiveSetID(for: [sessionID])
    let session = try ActiveSession(owner: ownerSigner.identity, sessionID: sessionID.uuidString,
                                    activeSetID: activeSetID, startsAt: now, endsAt: now.addingTimeInterval(20 * 60))
    publishedSession = try await ownerClient.publishSession(session)
}

await step("owner requests an early end") {
    guard let pairing, let publishedSession, let helperConsent else {
        throw SmokeError.unexpected("missing pairing, session, or consent")
    }
    request = try await ownerClient.requestUnlock(requestID: UUID().uuidString, pairing: pairing,
                                                   consent: helperConsent, session: publishedSession,
                                                   target: helperSigner.identity.identityID, validFor: 600)
}

// MARK: - 8. Helper sees and approves the request; a duplicate is rejected

await step("helper sees the pending request in its inbox") {
    guard let request else { throw SmokeError.unexpected("no request") }
    let response = try await helperClient.fetchInboxResponse()
    guard response.requests.contains(where: { $0.requestID == request.requestID }) else {
        throw SmokeError.unexpected("helper inbox did not report the request")
    }
}

await step("helper approves the request") {
    guard let request, let pairing else { throw SmokeError.unexpected("missing request or pairing") }
    _ = try await helperClient.submitApproval(request: request, pairing: pairing, decision: .approved)
}

await expectRejection("a duplicate approval is rejected") {
    guard let request, let pairing else { throw SmokeError.unexpected("missing request or pairing") }
    _ = try await helperClient.submitApproval(request: request, pairing: pairing, decision: .approved)
}

// MARK: - 9. Owner's inbox shows the request approved

await step("owner's inbox shows the request as approved") {
    guard let request else { throw SmokeError.unexpected("no request") }
    let response = try await ownerClient.fetchInboxResponse()
    guard let seen = response.requests.first(where: { $0.requestID == request.requestID }) else {
        throw SmokeError.unexpected("owner inbox did not report the request")
    }
    guard seen.effectiveStatus(at: Date()) == .approved else {
        throw SmokeError.unexpected("request status is \(seen.effectiveStatus(at: Date())), not approved")
    }
}

// MARK: - 9b. Owner's anchored inbox includes the approval (R5 Slice B2a/B2c)

await step("owner's anchored inbox includes the approval") {
    guard let request, let pairing else { throw SmokeError.unexpected("no request or pairing") }
    let response = try await ownerClient.fetchInboxResponse()
    guard let found = response.approvals?.first(where: { $0.requestID == request.requestID }) else {
        throw SmokeError.unexpected("owner inbox did not report an approval for this request")
    }
    guard found.decision == .approved else {
        throw SmokeError.unexpected("inbox-delivered approval decision is \(found.decision), not approved")
    }
    approval = found
    // The owner's own freshest cached consent, exactly as the app reads it
    // (never a possibly stale locally-held copy) — required so
    // `OwnerApprovalCheck`'s generation check lines up with the generation
    // actually bound into the approval.
    guard let consent = response.consents?.first(where: { $0.pairingID == pairing.pairingID }) else {
        throw SmokeError.unexpected("owner inbox did not report consent for this pairing")
    }
    ownerCachedConsent = consent
}

// MARK: - 9c. OwnerApprovalCheck passes against the owner's own trusted-person cache

await step("OwnerApprovalCheck verifies the inbox-delivered approval") {
    guard let approval, let request, let pairing, let ownerCachedConsent else {
        throw SmokeError.unexpected("missing approval, request, pairing, or owner's cached consent")
    }
    let trustedApprover = OwnerApprovalCheck.TrustedApprover(pairing: pairing, consent: ownerCachedConsent)
    try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trustedApprover,
                                  ownerIdentity: ownerSigner.identity)
}

// MARK: - 9d. useApproval succeeds and its verification matches

await step("owner's useApproval succeeds and its verification matches") {
    guard let approval, let request else { throw SmokeError.unexpected("missing approval or request") }
    let generatedUseID = UUID().uuidString
    useID = generatedUseID
    let verification = try await ownerClient.useApproval(approval, request: request, useID: generatedUseID)
    guard verification.approval == approval, verification.useID == generatedUseID else {
        throw SmokeError.unexpected("use verification does not match the submitted approval/useID")
    }
    firstVerification = verification
}

// MARK: - 9e. An identical use retry returns the same verification (idempotent replay)

await step("an identical use retry returns the same verification") {
    guard let approval, let request, let useID, let firstVerification else {
        throw SmokeError.unexpected("missing approval, request, useID, or first verification")
    }
    let replay = try await ownerClient.useApproval(approval, request: request, useID: useID)
    guard replay == firstVerification else {
        throw SmokeError.unexpected("replayed use verification differs from the first one")
    }
}

// MARK: - 9f. A different useID is rejected, and classify returns .definitive

await step("a different useID on a consumed approval is rejected as .definitive") {
    guard let approval, let request else { throw SmokeError.unexpected("missing approval or request") }
    var caught: Error?
    do {
        _ = try await ownerClient.useApproval(approval, request: request, useID: UUID().uuidString)
    } catch {
        caught = error
    }
    guard let caught else {
        throw SmokeError.unexpected("expected a rejection, but the call succeeded")
    }
    guard AsyncCompanionClient.UseFailureDisposition.classify(caught) == .definitive else {
        throw SmokeError.unexpected("expected .definitive, classify(_:) returned something else for: \(caught)")
    }
}

// MARK: - 9g. `use` is rejected once the session is superseded (R5 Slice B2c review, P2-11)
//
// The relay's "use" reducer requires `ledger.currentSessionID ==
// current.request.sessionID` (relay/src/reducer.ts); publishing a *new*
// session for the same owner immediately moves `currentSessionID` and also
// expires every outstanding request bound to the old session/active-set
// (the same reducer's "session" case). This exercises that without any
// sleep/time-based expiry: a second session supersedes the first one
// synchronously.

var supersededRequest: TrustedRequest?
var supersededApproval: Approval?

await step("owner publishes a second session, requests early end, and the helper approves it") {
    guard let pairing, let helperConsent else { throw SmokeError.unexpected("missing pairing or helper consent") }
    let sessionID = UUID()
    let now = Date()
    let activeSetID = companionActiveSetID(for: [sessionID])
    let session = try ActiveSession(owner: ownerSigner.identity, sessionID: sessionID.uuidString,
                                    activeSetID: activeSetID, startsAt: now, endsAt: now.addingTimeInterval(20 * 60))
    _ = try await ownerClient.publishSession(session)
    let newRequest = try await ownerClient.requestUnlock(requestID: UUID().uuidString, pairing: pairing,
                                                          consent: helperConsent, session: session,
                                                          target: helperSigner.identity.identityID, validFor: 600)
    supersededRequest = newRequest
    supersededApproval = try await helperClient.submitApproval(request: newRequest, pairing: pairing, decision: .approved)
}

await step("owner publishes a superseding session") {
    let newSessionID = UUID()
    let now = Date()
    let activeSetID = companionActiveSetID(for: [newSessionID])
    let session = try ActiveSession(owner: ownerSigner.identity, sessionID: newSessionID.uuidString,
                                    activeSetID: activeSetID, startsAt: now, endsAt: now.addingTimeInterval(20 * 60))
    _ = try await ownerClient.publishSession(session)
}

await step("use after the session is superseded is rejected as .definitive") {
    guard let supersededRequest, let supersededApproval else { throw SmokeError.unexpected("missing request or approval") }
    var caught: Error?
    do {
        _ = try await ownerClient.useApproval(supersededApproval, request: supersededRequest, useID: UUID().uuidString)
    } catch {
        caught = error
    }
    guard let caught else { throw SmokeError.unexpected("expected a rejection, but the call succeeded") }
    guard AsyncCompanionClient.UseFailureDisposition.classify(caught) == .definitive else {
        throw SmokeError.unexpected("expected .definitive, classify(_:) returned something else for: \(caught)")
    }
}

// MARK: - 10. Owner revokes; helper sees the pairing revoked

await step("owner revokes the pairing") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    try await ownerClient.revoke(pairing)
}

await step("helper sees the pairing revoked") {
    guard let pairing else { throw SmokeError.unexpected("no pairing") }
    let response = try await helperClient.fetchInboxResponse()
    guard let seen = response.pairings?.first(where: { $0.pairingID == pairing.pairingID }) else {
        throw SmokeError.unexpected("helper inbox did not report the pairing")
    }
    guard seen.state == .revoked else {
        throw SmokeError.unexpected("pairing state is \(seen.state), not revoked")
    }
}

// MARK: - Summary

if tracker.failureCount > 0 {
    print("relay-smoke: \(tracker.failureCount) step(s) FAILED")
    exit(1)
} else {
    print("relay-smoke: all steps PASSED")
    exit(0)
}
