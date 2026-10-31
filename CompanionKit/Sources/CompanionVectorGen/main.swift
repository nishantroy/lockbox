import Foundation
import CryptoKit
import CompanionKit

// R5 relay golden-vector generator.
//
// Writes a deterministic JSON fixture file that the TypeScript relay's test
// suite uses to verify canonical-signing byte-for-byte parity with the Swift
// reference implementation (CompanionKit). This target depends only on the
// public CompanionKit API and does not modify any existing CompanionKit
// source file.
//
// Usage: swift run --package-path CompanionKit CompanionVectorGen <output-file>

// MARK: - Local helpers (duplicated, not exported by CompanionKit)

func b64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func ms(_ date: Date) -> String {
    String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
}

let version = CompanionCanonical.version

func seedBytes(_ start: Int) -> Data {
    Data((0..<32).map { UInt8((start + $0) % 256) })
}

func makeSigner(seed: Data, role: CompanionRole) throws -> DeviceSigner {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let publicKey = key.publicKey.rawRepresentation
    let identity = try DeviceIdentity(identityID: DeviceIdentity.makeID(publicKey), role: role, publicKey: publicKey)
    let store = InMemoryDeviceKeyStore()
    try store.save(privateKey: seed, for: identity.identityID)
    return try DeviceSigner(identity: identity, keyStore: store)
}

// MARK: - Local envelope (mirrors CompanionRelayService.DurableOperationEnvelope)
// This is a trivial, already-documented wire contract (see
// CompanionRelayService/Sources/CompanionRelayService/DurableOperation.swift).
// It is duplicated here only because CompanionVectorGen cannot depend on the
// CompanionRelayService package from within the CompanionKit package graph.

struct VGEnvelope: Codable {
    let operationID: String
    let expectedRevision: Int64
    let payload: Data
}

func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func makeEnvelopedOperation(kind: String, operationID: String, expectedRevision: Int64,
                             payload: Data, signer: DeviceSigner) throws -> SignedOperation {
    let envelope = VGEnvelope(operationID: operationID, expectedRevision: expectedRevision, payload: payload)
    let envelopeData = try encodeSorted(envelope)
    let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: kind,
                                       signer: signer.identity, body: envelopeData,
                                       signature: Data(repeating: 0, count: 64))
    let signature = try signer.sign(domain: "\(version).operation", fields: unsigned.signingFields())
    return try SignedOperation(operationID: operationID, expectedRevision: nil, kind: kind,
                               signer: signer.identity, body: envelopeData, signature: signature)
}

func makeInboxOperation(signer: DeviceSigner) throws -> SignedOperation {
    let query = InboxQuery(identityID: signer.identity.identityID)
    let body = try encodeSorted(query)
    let fields = ["inbox", signer.identity.identityID, b64url(signer.identity.publicKey),
                  b64url(CompanionCanonical.digest(body))]
    let signature = try signer.sign(domain: "\(version).operation", fields: fields)
    return try SignedOperation(kind: "inbox", signer: signer.identity, body: body, signature: signature)
}

/// Captures the exact inbox operation the real `CompanionClient.fetchInbox`
/// signs (body `{"identityID":"...","issuedAt":<double>}`, explicit operation
/// ID), so the relay's vectors track the shipping client rather than a copy.
final class VGCapturingTransport: CompanionTransport, @unchecked Sendable {
    struct Captured: Error {}
    private(set) var inbox: SignedOperation?
    func submit(_ operation: SignedOperation) throws -> RelayResponse { throw Captured() }
    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
        inbox = operation
        throw Captured()
    }
}

func makeInboxOperationWithFreshness(signer: DeviceSigner, issuedAt: Date) throws -> SignedOperation {
    let transport = VGCapturingTransport()
    let client = CompanionClient(signer: signer, transport: transport, now: { issuedAt })
    _ = try? client.fetchInbox()
    guard let operation = transport.inbox else { fatalError("client did not produce an inbox operation") }
    return operation
}

func jsonText(_ operation: SignedOperation) throws -> String {
    let data = try encodeSorted(operation)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Fixed deterministic material

let ownerSigner = try makeSigner(seed: seedBytes(1), role: .owner)
let approverSigner = try makeSigner(seed: seedBytes(33), role: .trustedApprover)
let wrongSigner = try makeSigner(seed: seedBytes(65), role: .owner)
let replacementApproverSigner = try makeSigner(seed: seedBytes(97), role: .trustedApprover)

let base = Date(timeIntervalSince1970: 1_800_000_000)
let inviteIssuedAt = base
let inviteExpiresAt = base.addingTimeInterval(3_600)
let acceptanceIssuedAt = base.addingTimeInterval(10)
let confirmationIssuedAt = base.addingTimeInterval(20)
let pairingCreatedAt = base.addingTimeInterval(20)
let sessionStartsAt = base.addingTimeInterval(25)
let sessionEndsAt = base.addingTimeInterval(100_000)
let requestCreatedAt = base.addingTimeInterval(30)
let requestExpiresAt = base.addingTimeInterval(40_000)
let approvalIssuedAt = base.addingTimeInterval(35)
let replacementIssuedAt = base.addingTimeInterval(40)

let fixedPairingID = "fixture-pairing-01"
let fixedNonce = Data((0..<24).map { UInt8((10 + $0) % 256) })
let fixedApprovalNonce = Data((0..<24).map { UInt8((50 + $0) % 256) })

var out: [String: Any] = [:]
out["version"] = version
out["dateReferenceOffsetSeconds"] = 978_307_200
out["notes"] = "Generated by CompanionKit/Sources/CompanionVectorGen. Do not hand-edit; regenerate with swift run --package-path CompanionKit CompanionVectorGen <path>."

func identityDict(_ signer: DeviceSigner, seed: Data) -> [String: Any] {
    [
        "seedBase64": seed.base64EncodedString(),
        "publicKeyBase64": signer.identity.publicKey.base64EncodedString(),
        "identityID": signer.identity.identityID,
        "role": signer.identity.role.rawValue
    ]
}

out["identities"] = [
    "owner": identityDict(ownerSigner, seed: seedBytes(1)),
    "approver": identityDict(approverSigner, seed: seedBytes(33)),
    "wrongKey": identityDict(wrongSigner, seed: seedBytes(65)),
    "replacementApprover": identityDict(replacementApproverSigner, seed: seedBytes(97))
]

// MARK: - dateReferenceOffsetSeconds is documented via a live encoding sample

struct DateSample: Codable { let date: Date }
let dateSampleUnixSeconds: Double = 1_800_000_000
let dateSampleJSON = try encodeSorted(DateSample(date: Date(timeIntervalSince1970: dateSampleUnixSeconds)))
struct DataSample: Codable { let data: Data }
let dataSampleBytes = Data([0x00, 0x01, 0xFF, 0x7E])
let dataSampleJSON = try encodeSorted(DataSample(data: dataSampleBytes))

out["encodingSamples"] = [
    "date": [
        "unixSeconds": dateSampleUnixSeconds,
        "encodedJSON": String(decoding: dateSampleJSON, as: UTF8.self)
    ],
    "data": [
        "inputBytesBase64": dataSampleBytes.base64EncodedString(),
        "encodedJSON": String(decoding: dataSampleJSON, as: UTF8.self)
    ]
]

// MARK: - Generic framing vectors

func framingVector(domain: String, fields: [String]) -> [String: Any] {
    let bytes = CompanionCanonical.bytes(domain: domain, fields: fields)
    return ["domain": domain, "fields": fields, "expectedBytesBase64": bytes.base64EncodedString()]
}

out["framing"] = [
    framingVector(domain: "test.domain.v1", fields: ["a", "bb", "ccc"]),
    framingVector(domain: "\(version).invite", fields: ["x", "y"]),
    framingVector(domain: "empty.fields", fields: [])
]

// MARK: - Invite token vector (pairing v3)

let fixedInviteToken = b64url(Data((1...16).map { UInt8($0) }))
assert(InviteToken.isWellFormed(fixedInviteToken))

out["inviteToken"] = [
    "domain": "\(version).invite-token",
    "token": fixedInviteToken,
    "expectedHashBase64": InviteToken.hash(fixedInviteToken).base64EncodedString()
]

// MARK: - Signature checks (generic crypto/domain-separation vectors)

var signatureChecks: [[String: Any]] = []

@MainActor
func addSignatureCheck(label: String, domain: String, fields: [String], signer: DeviceSigner,
                       publicKeyOverride: Data? = nil, signWith signOverride: DeviceSigner? = nil,
                       expectValid: Bool) {
    let bytes = CompanionCanonical.bytes(domain: domain, fields: fields)
    let signature = (try? (signOverride ?? signer).sign(domain: domain, fields: fields)) ?? Data(repeating: 0, count: 64)
    signatureChecks.append([
        "label": label,
        "domain": domain,
        "fields": fields,
        "canonicalBytesBase64": bytes.base64EncodedString(),
        "signatureBase64": signature.base64EncodedString(),
        "publicKeyBase64": (publicKeyOverride ?? signer.identity.publicKey).base64EncodedString(),
        "expectValid": expectValid
    ])
}

// Invitation payload signature: valid, wrong-key, cross-domain, tampered-bytes.
let invitePayload = try InvitePayload(inviteID: "fixture-invite-01", owner: ownerSigner.identity,
                                      issuedAt: inviteIssuedAt, expiresAt: inviteExpiresAt, nonce: fixedNonce,
                                      tokenHash: InviteToken.hash(fixedInviteToken), ownerDisplayName: "Alex",
                                      grantedScopes: [.approveEarlyEnd, .receiveRequests])
let inviteDomain = "\(version).invite.v3"
let inviteFields = invitePayload.signingFields()
addSignatureCheck(label: "invite-payload-valid", domain: inviteDomain, fields: inviteFields,
                  signer: ownerSigner, expectValid: true)
addSignatureCheck(label: "invite-payload-wrong-key", domain: inviteDomain, fields: inviteFields,
                  signer: ownerSigner, signWith: wrongSigner, expectValid: false)
do {
    // Cross-domain: sign the exact same fields under a *different* domain
    // string, then check the resulting signature against the *correct*
    // domain's canonical bytes -- this is what a verifier actually does, and
    // domain separation must make it fail.
    let wrongDomainSignature = try ownerSigner.sign(domain: "\(version).approval", fields: inviteFields)
    let correctBytes = CompanionCanonical.bytes(domain: inviteDomain, fields: inviteFields)
    signatureChecks.append([
        "label": "invite-payload-cross-domain",
        "domain": inviteDomain,
        "fields": inviteFields,
        "canonicalBytesBase64": correctBytes.base64EncodedString(),
        "signatureBase64": wrongDomainSignature.base64EncodedString(),
        "publicKeyBase64": ownerSigner.identity.publicKey.base64EncodedString(),
        "expectValid": false
    ])
}
do {
    let bytes = CompanionCanonical.bytes(domain: inviteDomain, fields: inviteFields)
    let validSignature = try ownerSigner.sign(domain: inviteDomain, fields: inviteFields)
    var tamperedBytes = bytes
    tamperedBytes[tamperedBytes.count - 1] ^= 0xFF
    signatureChecks.append([
        "label": "invite-payload-tampered-bytes",
        "domain": inviteDomain,
        "fields": inviteFields,
        "canonicalBytesBase64": tamperedBytes.base64EncodedString(),
        "signatureBase64": validSignature.base64EncodedString(),
        "publicKeyBase64": ownerSigner.identity.publicKey.base64EncodedString(),
        "expectValid": false
    ])
}

// Acceptance payload signature: valid, wrong-key.
let acceptance = try PairingAcceptance(acceptanceID: "fixture-acceptance-01", invite: invitePayload,
                                       token: fixedInviteToken, approver: approverSigner.identity,
                                       approverDisplayName: "Sam", issuedAt: acceptanceIssuedAt)
let acceptanceDomain = "\(version).acceptance.v3"
addSignatureCheck(label: "acceptance-valid", domain: acceptanceDomain, fields: acceptance.signingFields(),
                  signer: approverSigner, expectValid: true)
addSignatureCheck(label: "acceptance-wrong-key", domain: acceptanceDomain, fields: acceptance.signingFields(),
                  signer: approverSigner, signWith: wrongSigner, expectValid: false)

// Approval payload signature.
let approvalSession = try ActiveSession(owner: ownerSigner.identity, sessionID: "fixture-session-01",
                                        activeSetID: "fixture-activeset-01", startsAt: sessionStartsAt, endsAt: sessionEndsAt)
let unsignedApproval = Approval(approvalID: "fixture-approval-01", requestID: "fixture-request-01",
                                pairingID: fixedPairingID, pairEpoch: 1, sessionID: approvalSession.sessionID,
                                activeSetID: approvalSession.activeSetID, approver: approverSigner.identity,
                                decision: .approved, issuedAt: approvalIssuedAt, consentGeneration: 1,
                                nonce: fixedApprovalNonce, signature: Data())
let approvalDomain = "\(version).approval"
addSignatureCheck(label: "approval-valid", domain: approvalDomain, fields: unsignedApproval.signingFields(),
                  signer: approverSigner, expectValid: true)
addSignatureCheck(label: "approval-wrong-key", domain: approvalDomain, fields: unsignedApproval.signingFields(),
                  signer: approverSigner, signWith: wrongSigner, expectValid: false)
let approvalSignature = try approverSigner.sign(domain: approvalDomain, fields: unsignedApproval.signingFields())
let signedApproval = Approval(approvalID: unsignedApproval.approvalID, requestID: unsignedApproval.requestID,
                              pairingID: unsignedApproval.pairingID, pairEpoch: unsignedApproval.pairEpoch,
                              sessionID: unsignedApproval.sessionID, activeSetID: unsignedApproval.activeSetID,
                              approver: unsignedApproval.approver, decision: unsignedApproval.decision,
                              issuedAt: unsignedApproval.issuedAt, consentGeneration: unsignedApproval.consentGeneration,
                              nonce: unsignedApproval.nonce, signature: approvalSignature)

// Pairing-replacement payload signature.
let previousPairing = try Pairing(pairingID: fixedPairingID, owner: ownerSigner.identity,
                                  approver: approverSigner.identity, epoch: 1, createdAt: pairingCreatedAt, state: .active)
let pairingReplacement = try PairingReplacement.propose(replacementID: "fixture-replace-01",
                                                        previousPairing: previousPairing,
                                                        replacementPairingID: "fixture-pairing-02",
                                                        signer: replacementApproverSigner,
                                                        issuedAt: replacementIssuedAt)
addSignatureCheck(label: "pairing-replacement-valid", domain: "\(version).pairing-replacement",
                  fields: pairingReplacement.signingFields(), signer: replacementApproverSigner, expectValid: true)

out["signatureChecks"] = signatureChecks

// MARK: - Full operation vectors (one per protocol kind)

var operations: [[String: Any]] = []

@MainActor
func addOperation(name: String, kind: String, operation: SignedOperation, decoded: [String: Any]) throws {
    operations.append([
        "name": name,
        "kind": kind,
        "signedOperationJSON": try jsonText(operation),
        "decoded": decoded
    ])
}

// ack
try addOperation(name: "ack", kind: "ack",
                 operation: try makeEnvelopedOperation(kind: "ack", operationID: "op-ack-01", expectedRevision: 0,
                                                       payload: Data("{}".utf8), signer: ownerSigner),
                 decoded: ["operationID": "op-ack-01", "expectedRevisionInEnvelope": 0, "signerRole": "owner"])

// invite
let inviteSignature = try ownerSigner.sign(domain: inviteDomain, fields: invitePayload.signingFields())
let invitation = try Invitation(payload: invitePayload, signature: inviteSignature)
try addOperation(name: "invite", kind: "invite",
                 operation: try makeEnvelopedOperation(kind: "invite", operationID: "op-invite-01", expectedRevision: 0,
                                                       payload: encodeSorted(invitation), signer: ownerSigner),
                 decoded: [
                     "operationID": "op-invite-01", "expectedRevisionInEnvelope": 0, "signerRole": "owner",
                     "inviteID": invitePayload.inviteID,
                     "issuedAtUnixSeconds": inviteIssuedAt.timeIntervalSince1970,
                     "expiresAtUnixSeconds": inviteExpiresAt.timeIntervalSince1970,
                     "nonceBase64": invitePayload.nonce.base64EncodedString(),
                     "ownerDisplayName": invitePayload.ownerDisplayName ?? "",
                     "tokenHashBase64": invitePayload.tokenHash.base64EncodedString()
                 ])

// accept
let acceptanceSignature = try approverSigner.sign(domain: acceptanceDomain, fields: acceptance.signingFields())
let signedAcceptance = SignedAcceptance(acceptance: acceptance, signature: acceptanceSignature)
try addOperation(name: "accept", kind: "accept",
                 operation: try makeEnvelopedOperation(kind: "accept", operationID: "op-accept-01", expectedRevision: 1,
                                                       payload: encodeSorted(signedAcceptance), signer: approverSigner),
                 decoded: [
                     "operationID": "op-accept-01", "expectedRevisionInEnvelope": 1, "signerRole": "approver",
                     "acceptanceID": acceptance.acceptanceID, "approverDisplayName": acceptance.approverDisplayName ?? ""
                 ])

// consent: ownerGrant, approverAccept, ownerRevoke
func consentMutation(action: ConsentMutationAction, scopes: [CompanionScope], nonceSeed: Int) throws -> RelationshipConsentMutation {
    try RelationshipConsentMutation(relationshipID: fixedPairingID, pairingID: fixedPairingID, pairEpoch: 1,
                                    owner: ownerSigner.identity, approver: approverSigner.identity, action: action,
                                    scopes: try CompanionScopeSet(scopes),
                                    nonce: Data((0..<24).map { UInt8((nonceSeed + $0) % 256) }),
                                    issuedAt: acceptanceIssuedAt.addingTimeInterval(1))
}

let consentGrant = try consentMutation(action: .ownerGrant, scopes: [.approveEarlyEnd, .receiveRequests], nonceSeed: 70)
try addOperation(name: "consent_owner_grant", kind: "consent",
                 operation: try makeEnvelopedOperation(kind: "consent", operationID: "op-consent-grant-01",
                                                       expectedRevision: 3, payload: encodeSorted(consentGrant),
                                                       signer: ownerSigner),
                 decoded: ["operationID": "op-consent-grant-01", "expectedRevisionInEnvelope": 3, "signerRole": "owner", "action": "ownerGrant"])

let consentAccept = try consentMutation(action: .approverAccept, scopes: [.approveEarlyEnd, .receiveRequests], nonceSeed: 90)
try addOperation(name: "consent_approver_accept", kind: "consent",
                 operation: try makeEnvelopedOperation(kind: "consent", operationID: "op-consent-accept-01",
                                                       expectedRevision: 4, payload: encodeSorted(consentAccept),
                                                       signer: approverSigner),
                 decoded: ["operationID": "op-consent-accept-01", "expectedRevisionInEnvelope": 4, "signerRole": "approver", "action": "approverAccept"])

let consentRevoke = try consentMutation(action: .ownerRevoke, scopes: [.approveEarlyEnd, .receiveRequests], nonceSeed: 110)
try addOperation(name: "consent_owner_revoke", kind: "consent",
                 operation: try makeEnvelopedOperation(kind: "consent", operationID: "op-consent-revoke-01",
                                                       expectedRevision: 5, payload: encodeSorted(consentRevoke),
                                                       signer: ownerSigner),
                 decoded: ["operationID": "op-consent-revoke-01", "expectedRevisionInEnvelope": 5, "signerRole": "owner", "action": "ownerRevoke"])

// session
try addOperation(name: "session", kind: "session",
                 operation: try makeEnvelopedOperation(kind: "session", operationID: "op-session-01", expectedRevision: 6,
                                                       payload: encodeSorted(approvalSession), signer: ownerSigner),
                 decoded: [
                     "operationID": "op-session-01", "expectedRevisionInEnvelope": 6, "signerRole": "owner",
                     "sessionID": approvalSession.sessionID, "activeSetID": approvalSession.activeSetID,
                     "startsAtUnixSeconds": sessionStartsAt.timeIntervalSince1970,
                     "endsAtUnixSeconds": sessionEndsAt.timeIntervalSince1970
                 ])

// request
let requestBinding = try RequestTargetBinding(approverIdentityID: approverSigner.identity.identityID,
                                              pairingID: fixedPairingID, pairEpoch: 1, consentGeneration: 1)
let trustedRequest = try TrustedRequest(requestID: "fixture-request-01", owner: ownerSigner.identity,
                                        targetBindings: [requestBinding], session: approvalSession, message: nil,
                                        createdAt: requestCreatedAt, expiresAt: requestExpiresAt)
try addOperation(name: "request", kind: "request",
                 operation: try makeEnvelopedOperation(kind: "request", operationID: "op-request-01", expectedRevision: 7,
                                                       payload: encodeSorted(trustedRequest), signer: ownerSigner),
                 decoded: [
                     "operationID": "op-request-01", "expectedRevisionInEnvelope": 7, "signerRole": "owner",
                     "requestID": trustedRequest.requestID,
                     "createdAtUnixSeconds": requestCreatedAt.timeIntervalSince1970,
                     "expiresAtUnixSeconds": requestExpiresAt.timeIntervalSince1970
                 ])

// approval
try addOperation(name: "approval", kind: "approval",
                 operation: try makeEnvelopedOperation(kind: "approval", operationID: "op-approval-01", expectedRevision: 8,
                                                       payload: encodeSorted(signedApproval), signer: approverSigner),
                 decoded: ["operationID": "op-approval-01", "expectedRevisionInEnvelope": 8, "signerRole": "approver",
                          "approvalID": signedApproval.approvalID])

// use
let approvalUse = ApprovalUse(approval: signedApproval, requestID: trustedRequest.requestID, useID: "fixture-use-01",
                              consentGeneration: 1)
try addOperation(name: "use", kind: "use",
                 operation: try makeEnvelopedOperation(kind: "use", operationID: "op-use-01", expectedRevision: 9,
                                                       payload: encodeSorted(approvalUse), signer: ownerSigner),
                 decoded: ["operationID": "op-use-01", "expectedRevisionInEnvelope": 9, "signerRole": "owner",
                          "useID": "fixture-use-01"])

// cancel
let requestReference = RequestReference(requestID: trustedRequest.requestID)
try addOperation(name: "cancel", kind: "cancel",
                 operation: try makeEnvelopedOperation(kind: "cancel", operationID: "op-cancel-01", expectedRevision: 10,
                                                       payload: encodeSorted(requestReference), signer: ownerSigner),
                 decoded: ["operationID": "op-cancel-01", "expectedRevisionInEnvelope": 10, "signerRole": "owner"])

// natural_end
struct VGNaturalEnd: Codable { let sessionID: String; let activeSetID: String }
let naturalEnd = VGNaturalEnd(sessionID: approvalSession.sessionID, activeSetID: approvalSession.activeSetID)
try addOperation(name: "natural_end", kind: "natural_end",
                 operation: try makeEnvelopedOperation(kind: "natural_end", operationID: "op-natural-end-01",
                                                       expectedRevision: 11, payload: encodeSorted(naturalEnd),
                                                       signer: ownerSigner),
                 decoded: ["operationID": "op-natural-end-01", "expectedRevisionInEnvelope": 11, "signerRole": "owner"])

// revoke
let pairingReference = PairingReference(pairingID: fixedPairingID, epoch: 1)
try addOperation(name: "revoke", kind: "revoke",
                 operation: try makeEnvelopedOperation(kind: "revoke", operationID: "op-revoke-01", expectedRevision: 12,
                                                       payload: encodeSorted(pairingReference), signer: ownerSigner),
                 decoded: ["operationID": "op-revoke-01", "expectedRevisionInEnvelope": 12, "signerRole": "owner"])

// replace_pairing
try addOperation(name: "replace_pairing", kind: "replace_pairing",
                 operation: try makeEnvelopedOperation(kind: "replace_pairing", operationID: "op-replace-01",
                                                       expectedRevision: 13, payload: encodeSorted(pairingReplacement),
                                                       signer: ownerSigner),
                 decoded: ["operationID": "op-replace-01", "expectedRevisionInEnvelope": 13, "signerRole": "owner"])

// inbox (non-enveloped, legacy-derived operation ID), legacy form: the
// `issuedAt` freshness field is omitted entirely (not null) when absent.
try addOperation(name: "inbox", kind: "inbox",
                 operation: try makeInboxOperation(signer: approverSigner),
                 decoded: ["signerRole": "approver", "identityID": approverSigner.identity.identityID])

// inbox with the freshness field, captured from the real CompanionClient
// (`issuedAt` is seconds since the 2001-01-01 reference date).
try addOperation(name: "inbox_with_issued_at", kind: "inbox",
                 operation: try makeInboxOperationWithFreshness(signer: approverSigner, issuedAt: base.addingTimeInterval(50)),
                 decoded: ["signerRole": "approver", "identityID": approverSigner.identity.identityID,
                          "issuedAtUnixSeconds": base.addingTimeInterval(50).timeIntervalSince1970])

out["operations"] = operations

// MARK: - Raw (non-enveloped) operation vectors.
// The actual Swift clients (`CompanionClient.submit`/`fetchInbox` in
// CompanionKit/Sources/CompanionKit/ProtocolModels.swift, and the async HTTP
// client) send `SignedOperation.body` as the raw per-kind payload directly --
// there is no `DurableOperationEnvelope` wrapper on the wire, and
// `expectedRevision` is send as-is (frequently `nil`, meaning "no optimistic
// check"). These vectors exercise that actual wire format, alongside the
// enveloped vectors above.

func rawOperationID(kind: String, signer: DeviceIdentity, body: Data) -> String {
    let bytes = CompanionCanonical.bytes(domain: "\(version).operation-id",
                                         fields: [kind, signer.identityID, b64url(CompanionCanonical.digest(body))])
    return String(b64url(Data(SHA256.hash(data: bytes))).prefix(32))
}

func makeRawOperation(kind: String, expectedRevision: UInt64?, payload: Data, signer: DeviceSigner) throws -> SignedOperation {
    let operationID = rawOperationID(kind: kind, signer: signer.identity, body: payload)
    let unsigned = try SignedOperation(operationID: operationID, expectedRevision: expectedRevision, kind: kind,
                                       signer: signer.identity, body: payload, signature: Data(repeating: 0, count: 64))
    let signature = try signer.sign(domain: "\(version).operation", fields: unsigned.signingFields())
    return try SignedOperation(operationID: operationID, expectedRevision: expectedRevision, kind: kind,
                               signer: signer.identity, body: payload, signature: signature)
}

var rawOperations: [[String: Any]] = []

@MainActor
func addRawOperation(name: String, operation: SignedOperation) throws {
    rawOperations.append(["name": name, "kind": operation.kind, "signedOperationJSON": try jsonText(operation)])
}

try addRawOperation(name: "raw_ack_no_expected_revision",
                    operation: try makeRawOperation(kind: "ack", expectedRevision: nil,
                                                    payload: Data("{}".utf8), signer: ownerSigner))
try addRawOperation(name: "raw_invite_no_expected_revision",
                    operation: try makeRawOperation(kind: "invite", expectedRevision: nil,
                                                    payload: try encodeSorted(invitation), signer: ownerSigner))
try addRawOperation(name: "raw_request_no_expected_revision",
                    operation: try makeRawOperation(kind: "request", expectedRevision: nil,
                                                    payload: try encodeSorted(trustedRequest), signer: ownerSigner))
try addRawOperation(name: "raw_request_with_expected_revision_7",
                    operation: try makeRawOperation(kind: "request", expectedRevision: 7,
                                                    payload: try encodeSorted(trustedRequest), signer: ownerSigner))
try addRawOperation(name: "raw_approval_no_expected_revision",
                    operation: try makeRawOperation(kind: "approval", expectedRevision: nil,
                                                    payload: try encodeSorted(signedApproval), signer: approverSigner))
try addRawOperation(name: "raw_consent_owner_grant_no_expected_revision",
                    operation: try makeRawOperation(kind: "consent", expectedRevision: nil,
                                                    payload: try encodeSorted(consentGrant), signer: ownerSigner))
try addRawOperation(name: "raw_consent_approver_accept_no_expected_revision",
                    operation: try makeRawOperation(kind: "consent", expectedRevision: nil,
                                                    payload: try encodeSorted(consentAccept), signer: approverSigner))

out["rawOperations"] = rawOperations

// MARK: - RelayResult/RelayResponse/InboxResponse wire-format samples.
// RelayResult is a plain `enum ... : Codable` with associated values and no
// custom Codable implementation, so its JSON shape depends on Swift's
// compiler-synthesized enum Codable (SE-0295). These samples let the TS relay
// reproduce the exact wire shape the iOS client will decode.

func resultJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encodeSorted(value), as: UTF8.self)
}

var resultSamples: [String: Any] = [:]
resultSamples["acknowledgement"] = try resultJSON(RelayResult.acknowledgement)
resultSamples["invitation"] = try resultJSON(RelayResult.invitation(invitation))
resultSamples["pairing"] = try resultJSON(RelayResult.pairing(previousPairing))
resultSamples["session"] = try resultJSON(RelayResult.session(approvalSession))
resultSamples["request"] = try resultJSON(RelayResult.request(trustedRequest))
resultSamples["approval"] = try resultJSON(RelayResult.approval(signedApproval))
resultSamples["verification"] = try resultJSON(RelayResult.verification(
    ApprovalVerification(approval: signedApproval, verifiedAt: base, useID: "fixture-use-01")))
out["relayResultSamples"] = resultSamples

let sampleRelayResponse = try RelayResponse(operationID: "op-sample-01", revision: 7, result: .acknowledgement)
out["relayResponseSample"] = try resultJSON(sampleRelayResponse)
// R5 Slice B2a: an owner inbox sample that also carries `approvals` (contract
// v1.2, additive) -- the relay-stored accepted approval for the fixture
// request, exactly as an owner fetch of their own ledger would include it.
let sampleInboxResponse = try InboxResponse(ownerIdentityID: ownerSigner.identity.identityID, revision: 7,
                                            requests: [trustedRequest], approvals: [signedApproval])
out["inboxResponseSample"] = try resultJSON(sampleInboxResponse)

// A pure helper/approver inbox sample omits `approvals` entirely (`nil`, not
// an empty array) -- confirms the wire body has no "approvals" key at all.
let sampleHelperInboxResponse = try InboxResponse(ownerIdentityID: nil, revision: 7, requests: [trustedRequest])
out["helperInboxResponseSample"] = try resultJSON(sampleHelperInboxResponse)

// Pairing v3 (docs/r5-pairing-v3-plan.md, contract v1.4): an owner inbox
// sample that also carries `pairings` (with display names) and `acceptances`
// -- the friend-signed acceptance behind each pairing, exactly as an owner
// fetch of their own ledger would include it.
let joinedPairing = try Pairing(pairingID: Pairing.derivedID(inviteID: invitePayload.inviteID,
                                                              approverIdentityID: approverSigner.identity.identityID),
                                owner: ownerSigner.identity, approver: approverSigner.identity, epoch: 1,
                                createdAt: acceptanceIssuedAt, state: .active,
                                ownerDisplayName: "Alex", approverDisplayName: "Sam")
let sampleInboxResponseWithAcceptances = try InboxResponse(
    ownerIdentityID: ownerSigner.identity.identityID, revision: 7, requests: [trustedRequest],
    pairings: [joinedPairing], acceptances: [signedAcceptance])
out["inboxResponseWithAcceptancesSample"] = try resultJSON(sampleInboxResponseWithAcceptances)
out["joinedPairingSample"] = try resultJSON(RelayResult.pairing(joinedPairing))

// `POST /v1/invite/lookup` 200 response body.
struct VGLookupResponse: Codable { let invitation: Invitation }
out["inviteLookupResponseSample"] = String(decoding: try encodeSorted(VGLookupResponse(invitation: invitation)), as: UTF8.self)

// MARK: - Tampered full-operation variants (built from the "invite" and "request" ops)

var tamperedOperations: [[String: Any]] = []

@MainActor
func tamper(base: SignedOperation, label: String, mutate: (inout String, inout Data, inout Data, inout DeviceIdentity) -> Void) throws -> [String: Any] {
    var operationID = base.operationID
    var body = base.body
    var signature = base.signature
    var signer = base.signer
    mutate(&operationID, &body, &signature, &signer)
    // Construct without validation so an intentionally-invalid signature can
    // still be serialized for the TS test to reject.
    let json = try jsonText(unsafeOperation(operationID: operationID, expectedRevision: base.expectedRevision,
                                            kind: base.kind, signer: signer, body: body, signature: signature))
    return ["label": label, "basedOn": base.kind, "signedOperationJSON": json, "expectValid": false]
}

/// Builds a SignedOperation bypassing its normal validating initializer, so a
/// deliberately-invalid fixture (bad signature/tampered body) can still be
/// serialized to JSON for a rejection test.
func unsafeOperation(operationID: String, expectedRevision: UInt64?, kind: String, signer: DeviceIdentity,
                     body: Data, signature: Data) -> SignedOperation {
    struct Raw: Codable {
        let operationID: String
        let expectedRevision: UInt64?
        let kind: String
        let signer: DeviceIdentity
        let body: Data
        let signature: Data
    }
    let raw = Raw(operationID: operationID, expectedRevision: expectedRevision, kind: kind,
                  signer: signer, body: body, signature: signature)
    let data = try! JSONEncoder().encode(raw)
    return try! JSONDecoder().decode(SignedOperation.self, from: data)
}

let inviteOperationForTamper = try makeEnvelopedOperation(kind: "invite", operationID: "op-invite-tamper-base",
                                                          expectedRevision: 0, payload: try encodeSorted(invitation),
                                                          signer: ownerSigner)

tamperedOperations.append(try tamper(base: inviteOperationForTamper, label: "invite-op-wrong-signature") { _, _, signature, _ in
    signature = Data(repeating: 0x42, count: 64)
})
tamperedOperations.append(try tamper(base: inviteOperationForTamper, label: "invite-op-tampered-body") { _, body, _, _ in
    body[body.count - 1] ^= 0xFF
})
tamperedOperations.append(try tamper(base: inviteOperationForTamper, label: "invite-op-tampered-operation-id") { operationID, _, _, _ in
    operationID = "op-invite-tamper-mutated"
})
do {
    // Cross-domain: sign the exact same operation-level fields, but under a
    // different domain string (simulates a signature lifted from another
    // protocol context).
    let unsigned = try SignedOperation(operationID: "op-invite-tamper-base", expectedRevision: nil, kind: "invite",
                                       signer: ownerSigner.identity, body: inviteOperationForTamper.body,
                                       signature: Data(repeating: 0, count: 64))
    let crossDomainSignature = try ownerSigner.sign(domain: "\(version).approval", fields: unsigned.signingFields())
    let json = try jsonText(unsafeOperation(operationID: "op-invite-tamper-base", expectedRevision: nil, kind: "invite",
                                            signer: ownerSigner.identity, body: inviteOperationForTamper.body,
                                            signature: crossDomainSignature))
    tamperedOperations.append(["label": "invite-op-cross-domain-signature", "basedOn": "invite",
                               "signedOperationJSON": json, "expectValid": false])
}

let requestOperationForTamper = try makeEnvelopedOperation(kind: "request", operationID: "op-request-tamper-base",
                                                           expectedRevision: 7, payload: try encodeSorted(trustedRequest),
                                                           signer: ownerSigner)
tamperedOperations.append(try tamper(base: requestOperationForTamper, label: "request-op-wrong-key-signature") { _, body, signature, signer in
    signature = (try? wrongSigner.sign(domain: "\(version).operation",
                                       fields: try! SignedOperation(operationID: "op-request-tamper-base",
                                                                    expectedRevision: nil, kind: "request",
                                                                    signer: signer, body: body,
                                                                    signature: Data(repeating: 0, count: 64)).signingFields())) ?? Data(repeating: 0, count: 64)
})
tamperedOperations.append(try tamper(base: requestOperationForTamper, label: "request-op-tampered-body") { _, body, _, _ in
    body[0] ^= 0xFF
})

out["tamperedOperations"] = tamperedOperations

// MARK: - Write output

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: CompanionVectorGen <output-file>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]
let outputData = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
try outputData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputData.count) bytes to \(outputPath)")
