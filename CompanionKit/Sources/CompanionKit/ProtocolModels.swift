import Foundation
import CryptoKit

// MARK: - Invitation and pairing (pairing v3)
//
// Pairing v3 (`docs/r5-pairing-v3-plan.md`): the owner creates an invite
// keyed by a random 128-bit token; the friend looks it up, taps Accept, and
// the relay creates the active pairing and both-sided consent in one
// transaction. There is no owner confirm step and no typed code. The owner's
// signature covers the token's hash, the owner's display name and the
// granted scopes; the friend's covers the token itself, the friend's display
// name and the accepted scopes.

/// The invite bearer token: 16 random bytes, 22 base64url characters. It lives
/// only on the owner's device and in the link, and is NEVER sent to the relay.
/// Three domain-separated values derive from it (mirrored by `inviteLookupKey`,
/// `inviteTokenHash` and `acceptanceProof` in the TS relay):
/// - `lookupKey` = H("invite-lookup", token): the relay's only handle on the invite.
///   Anyone with the link can compute it; the relay cannot invert it.
/// - `inviteHash` = H("invite-token", token, ownerPublicKey, inviteID): signed into the
///   invite. Only a token holder can recompute it, so a friend can tell the invite was
///   issued by that owner for that token, and a relay that knows just the lookup key
///   cannot forge or swap an invite.
/// - possession keypair: an Ed25519 key whose seed is H("invite-possession", token). Its public
///   half is signed into the invite and the acceptance carries a signature by the private half,
///   which the RELAY verifies before consuming the invite, so someone who only read the lookup
///   key from a database or log cannot burn the invite.
/// - `acceptanceProof` = H("accept-proof", token, approverPublicKey, acceptanceID):
///   carried in the acceptance. Only a token holder can compute it, so the owner can
///   tell an acceptance came from the link holder and not from the relay.
public enum InviteToken {
    public static let length = 22
    public static let shareLinkPrefix = "phone-lockbox-companion://i/"

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == length && token.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    public static func lookupKey(_ token: String) -> Data {
        CompanionCanonical.digest(CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).invite-lookup", fields: [token]))
    }

    /// The wire form of a lookup key: base64url, unpadded (43 characters).
    public static func lookupKeyString(_ token: String) -> String { base64URL(lookupKey(token)) }

    public static func inviteHash(token: String, ownerPublicKey: Data, inviteID: String) -> Data {
        CompanionCanonical.digest(CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).invite-token", fields: [token, base64URL(ownerPublicKey), inviteID]))
    }

    public static func acceptanceProof(token: String, approverPublicKey: Data, acceptanceID: String) -> Data {
        CompanionCanonical.digest(CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).accept-proof", fields: [token, base64URL(approverPublicKey), acceptanceID]))
    }

    static func possessionPrivateKey(_ token: String) -> Curve25519.Signing.PrivateKey? {
        let seed = CompanionCanonical.digest(CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).invite-possession", fields: [token]))
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// The public half of the token-derived possession key (signed into the invite).
    public static func possessionPublicKey(_ token: String) -> Data? {
        possessionPrivateKey(token).map { Data($0.publicKey.rawRepresentation) }
    }

    /// What the possession key signs: binds the approver key, acceptance ID, invite and lookup key.
    static func possessionMessage(acceptanceID: String, inviteID: String, ownerIdentityID: String,
                                  approverPublicKey: Data, lookupKey: Data) -> Data {
        CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).accept-possession",
                                 fields: [acceptanceID, inviteID, ownerIdentityID, base64URL(approverPublicKey), base64URL(lookupKey)])
    }

    static func possessionSignature(token: String, acceptanceID: String, inviteID: String, ownerIdentityID: String,
                                    approverPublicKey: Data, lookupKey: Data) -> Data? {
        guard let key = possessionPrivateKey(token) else { return nil }
        return try? key.signature(for: possessionMessage(acceptanceID: acceptanceID, inviteID: inviteID, ownerIdentityID: ownerIdentityID,
                                                         approverPublicKey: approverPublicKey, lookupKey: lookupKey))
    }

    /// Verifies an acceptance's possession signature against the invite's signed possession key (what the relay does).
    public static func verifyPossession(of acceptance: PairingAcceptance, possessionKey: Data) -> Bool {
        guard acceptance.possessionSignature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: possessionKey) else { return false }
        return key.isValidSignature(acceptance.possessionSignature, for: possessionMessage(
            acceptanceID: acceptance.acceptanceID, inviteID: acceptance.inviteID, ownerIdentityID: acceptance.owner.identityID,
            approverPublicKey: acceptance.approver.publicKey, lookupKey: acceptance.lookupKey))
    }

    /// Constant-time equality for equal-length secrets or secret-derived values.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// True when `token` is the token behind `payload` (hash bound to its owner and invite ID, and its lookup key).
    public static func matches(_ token: String, payload: InvitePayload) -> Bool {
        isWellFormed(token)
            && constantTimeEqual(inviteHash(token: token, ownerPublicKey: payload.owner.publicKey, inviteID: payload.inviteID), payload.tokenHash)
            && constantTimeEqual(lookupKey(token), payload.lookupKey)
            && possessionPublicKey(token).map({ constantTimeEqual($0, payload.possessionKey) }) == true
    }

    public static func shareLink(token: String) -> String { shareLinkPrefix + token }

    /// Extracts a well-formed token from `phone-lockbox-companion://i/<token>`, or `nil`.
    public static func token(fromShareLink link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(shareLinkPrefix) else { return nil }
        let token = String(trimmed.dropFirst(shareLinkPrefix.count))
        return isWellFormed(token) ? token : nil
    }
}

/// Shared validation for the two optional display names and the scope sets
/// that pairing v3 signs. Mirrors `decodeDisplayName` / `decodeGrantedScopes`
/// in the TS relay: a name is absent or 1...40 Unicode scalars with no control,
/// bidi or invisible-mark scalars and at least one non-blank scalar; scopes are a
/// non-empty, duplicate-free set of R5 scopes.
public enum PairingFields {
    public static let maxDisplayNameScalars = 40

    public static func validateDisplayName(_ value: String?, name: String) throws {
        guard let value else { return }
        let scalars = value.unicodeScalars.map(\.value)
        guard !scalars.isEmpty, scalars.count <= maxDisplayNameScalars,
              !scalars.contains(where: isForbiddenNameScalar),
              !scalars.allSatisfy(isBlankScalar) else {
            throw CompanionError.malformed("invalid \(name)")
        }
    }

    /// Whitespace-like and invisible-filler scalars (a name made only of these is blank), spelled out so Swift and TS agree exactly.
    static func isBlankScalar(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
             // Invisible fillers that render as nothing: a name made only of these is blank.
             0x00AD, 0x115F, 0x1160, 0x200D, 0x2060, 0x2800, 0x3164, 0xFFA0, 0x200C, 0x034F, 0x180E, 0x2061...0x2064, 0xFE00...0xFE0F,
             0x1D173...0x1D17A, 0xE0000...0xE007F,
             0xE0100...0xE01EF, 0x180B...0x180D, 0x180F, 0x17B4...0x17B5, 0x206A...0x206F, 0x1BCA0...0x1BCA3, 0xFFF9...0xFFFB: return true
        default: return false
        }
    }

    /// C0/C1 controls, bidi controls and invisible marks that enable spoofing. U+200D (ZWJ) stays legal for emoji sequences.
    static func isForbiddenNameScalar(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    public static func normalizedScopes(_ scopes: [CompanionScope], name: String) throws -> [CompanionScope] {
        guard !scopes.isEmpty, Set(scopes).count == scopes.count, scopes.allSatisfy(\.isR5) else {
            throw CompanionError.malformed("invalid \(name)")
        }
        return scopes.sorted { $0.rawValue < $1.rawValue }
    }

    static func scopeField(_ scopes: [CompanionScope]) -> String {
        scopes.map(\.rawValue).sorted().joined(separator: ",")
    }
}

public struct InvitePayload: Codable, Hashable, Sendable {
    public let inviteID: String
    public let owner: DeviceIdentity
    public let issuedAt: Date
    public let expiresAt: Date
    public let nonce: Data
    /// `InviteToken.inviteHash(token:ownerPublicKey:inviteID:)`; only a token holder can recompute it. The token itself is never sent to the relay.
    public let tokenHash: Data
    /// `InviteToken.lookupKey(token)`: the relay's only handle on this invite; signed so it cannot be re-pointed.
    public let lookupKey: Data
    /// Public key of the token-derived possession keypair; the relay verifies an acceptance's possession signature against it.
    public let possessionKey: Data
    /// Owner-chosen name shown to the friend. Optional, at most 40 scalars.
    public let ownerDisplayName: String?
    /// The scopes creating this invite grants the friend. Sorted, non-empty, R5 only.
    public let grantedScopes: [CompanionScope]

    public init(inviteID: String, owner: DeviceIdentity, issuedAt: Date, expiresAt: Date, nonce: Data,
                tokenHash: Data, lookupKey: Data, possessionKey: Data, ownerDisplayName: String? = nil,
                grantedScopes: [CompanionScope] = [.approveEarlyEnd, .receiveRequests]) throws {
        try requireIdentifier(inviteID, name: "invite ID")
        guard owner.role == .owner, nonce.count >= 16, nonce.count <= 64,
              tokenHash.count == 32, lookupKey.count == 32, possessionKey.count == 32,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= CompanionLimits.maxInviteLifetime else {
            throw CompanionError.malformed("invalid invitation")
        }
        try requireTimestamp(issuedAt, name: "invite issue time")
        try requireTimestamp(expiresAt, name: "invite expiry")
        try PairingFields.validateDisplayName(ownerDisplayName, name: "owner display name")
        self.inviteID = inviteID; self.owner = owner; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.nonce = nonce
        self.tokenHash = tokenHash; self.lookupKey = lookupKey; self.possessionKey = possessionKey; self.ownerDisplayName = ownerDisplayName
        self.grantedScopes = try PairingFields.normalizedScopes(grantedScopes, name: "granted scopes")
    }

    public func signingFields() -> [String] {
        [inviteID, owner.identityID, base64URL(owner.publicKey), String(milliseconds(issuedAt)), String(milliseconds(expiresAt)),
         base64URL(nonce), base64URL(tokenHash), base64URL(lookupKey), base64URL(possessionKey), ownerDisplayName ?? "", PairingFields.scopeField(grantedScopes)]
    }

    public func validate(at now: Date) throws {
        try owner.validate()
        guard nonce.count >= 16, nonce.count <= 64, tokenHash.count == 32, lookupKey.count == 32, possessionKey.count == 32, expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= CompanionLimits.maxInviteLifetime else {
            throw CompanionError.malformed("invalid invitation")
        }
        try requireTimestamp(issuedAt, name: "invite issue time")
        try requireTimestamp(expiresAt, name: "invite expiry")
        try PairingFields.validateDisplayName(ownerDisplayName, name: "owner display name")
        _ = try PairingFields.normalizedScopes(grantedScopes, name: "granted scopes")
        guard now < expiresAt else { throw CompanionError.expired }
        // Generous: devices' clocks differ by more than a minute often enough.
        guard now >= issuedAt.addingTimeInterval(-CompanionLimits.pairingClockSkew) else { throw CompanionError.malformed("invite is from the future") }
    }
}

public struct Invitation: Codable, Hashable, Sendable {
    public let payload: InvitePayload
    public let signature: Data

    public init(payload: InvitePayload, signature: Data) throws {
        guard signature.count == 64 else { throw CompanionError.malformed("invitation signature") }
        try payload.validate(at: payload.issuedAt)
        self.payload = payload; self.signature = signature
    }

    public func validateSignature() throws {
        try payload.validate(at: payload.issuedAt)
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: payload.owner.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).invite.v3", fields: payload.signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }

    public func validate(at now: Date) throws {
        try payload.validate(at: now)
        try validateSignature()
    }

    /// What a friend does with a looked-up invitation: it must verify under the
    /// owner key, still be live, and bind the exact token from the link (hash
    /// bound to this owner and invite ID, plus the lookup key). A relay that only
    /// knows the lookup key cannot produce an invitation that passes.
    public func validate(at now: Date, matchingToken token: String) throws {
        try validate(at: now)
        guard InviteToken.matches(token, payload: payload) else {
            throw CompanionError.malformed("invite does not match the link")
        }
    }
}

/// Friend-signed acceptance (pairing v3). Carries the invite's lookup key (what
/// the relay gates on) and a token-derived `tokenProof` only the link holder can
/// compute; the OWNER verifies the proof, the relay cannot. The relay turns a
/// valid acceptance into an active pairing plus active both-sided consent
/// atomically.
public struct PairingAcceptance: Codable, Hashable, Sendable {
    public let acceptanceID: String
    public let inviteID: String
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public let issuedAt: Date
    public let lookupKey: Data
    public let tokenProof: Data
    /// Signature by the token-derived possession key; verified by the relay before the invite is consumed.
    public let possessionSignature: Data
    public let approverDisplayName: String?
    public let acceptedScopes: [CompanionScope]

    public init(acceptanceID: String, invite: InvitePayload, token: String, approver: DeviceIdentity,
                approverDisplayName: String? = nil, issuedAt: Date) throws {
        try requireIdentifier(acceptanceID, name: "acceptance ID")
        try invite.validate(at: issuedAt)
        guard approver.role == .trustedApprover else { throw CompanionError.malformed("receiver is not an approver") }
        try approver.validate()
        guard InviteToken.matches(token, payload: invite) else {
            throw CompanionError.malformed("invite does not match the link")
        }
        try PairingFields.validateDisplayName(approverDisplayName, name: "approver display name")
        self.acceptanceID = acceptanceID; self.inviteID = invite.inviteID; self.owner = invite.owner
        self.approver = approver; self.issuedAt = issuedAt
        self.lookupKey = InviteToken.lookupKey(token)
        self.tokenProof = InviteToken.acceptanceProof(token: token, approverPublicKey: approver.publicKey, acceptanceID: acceptanceID)
        guard let possession = InviteToken.possessionSignature(
            token: token, acceptanceID: acceptanceID, inviteID: invite.inviteID, ownerIdentityID: invite.owner.identityID,
            approverPublicKey: approver.publicKey, lookupKey: InviteToken.lookupKey(token)) else {
            throw CompanionError.malformed("invalid invite token")
        }
        self.possessionSignature = possession
        self.approverDisplayName = approverDisplayName
        // Accepting is consenting to exactly what the owner granted.
        self.acceptedScopes = invite.grantedScopes
    }

    /// Memberwise form for decoding-adjacent code and tests that need to build a
    /// (possibly hostile) acceptance without holding the token.
    init(acceptanceID: String, inviteID: String, owner: DeviceIdentity, approver: DeviceIdentity, issuedAt: Date,
         lookupKey: Data, tokenProof: Data, possessionSignature: Data = Data(repeating: 0, count: 64),
         approverDisplayName: String?, acceptedScopes: [CompanionScope]) {
        self.acceptanceID = acceptanceID; self.inviteID = inviteID; self.owner = owner; self.approver = approver
        self.issuedAt = issuedAt; self.lookupKey = lookupKey; self.tokenProof = tokenProof; self.possessionSignature = possessionSignature
        self.approverDisplayName = approverDisplayName; self.acceptedScopes = acceptedScopes
    }

    public func signingFields() -> [String] {
        [acceptanceID, inviteID, owner.identityID, approver.identityID,
         base64URL(owner.publicKey), base64URL(approver.publicKey), String(milliseconds(issuedAt)),
         base64URL(lookupKey), base64URL(tokenProof), base64URL(possessionSignature), approverDisplayName ?? "", PairingFields.scopeField(acceptedScopes)]
    }

    public func validate() throws {
        try requireIdentifier(acceptanceID, name: "acceptance ID")
        try requireIdentifier(inviteID, name: "invite ID")
        try owner.validate(); try approver.validate(); try requireTimestamp(issuedAt, name: "acceptance time")
        guard owner.role == .owner, approver.role == .trustedApprover, lookupKey.count == 32, tokenProof.count == 32, possessionSignature.count == 64 else {
            throw CompanionError.malformed("invalid pairing acceptance")
        }
        try PairingFields.validateDisplayName(approverDisplayName, name: "approver display name")
        _ = try PairingFields.normalizedScopes(acceptedScopes, name: "accepted scopes")
    }
}

public enum PairingState: String, Codable, Sendable { case active, revoked }

public struct Pairing: Codable, Hashable, Sendable {
    public let pairingID: String
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public let epoch: UInt64
    /// For a pairing created by a v3 accept, the moment the friend joined.
    public let createdAt: Date
    public var state: PairingState
    /// Pairing v3: names carried from the signed invite / acceptance so each side can show who the other is.
    public let ownerDisplayName: String?
    public let approverDisplayName: String?

    public init(pairingID: String, owner: DeviceIdentity, approver: DeviceIdentity,
                epoch: UInt64, createdAt: Date, state: PairingState,
                ownerDisplayName: String? = nil, approverDisplayName: String? = nil) throws {
        try requireIdentifier(pairingID, name: "pairing ID")
        try owner.validate(); try approver.validate(); try requireTimestamp(createdAt, name: "pairing creation time")
        guard owner.role == .owner, approver.role == .trustedApprover, epoch > 0 else {
            throw CompanionError.malformed("invalid pairing")
        }
        try PairingFields.validateDisplayName(ownerDisplayName, name: "owner display name")
        try PairingFields.validateDisplayName(approverDisplayName, name: "approver display name")
        self.pairingID = pairingID; self.owner = owner; self.approver = approver
        self.epoch = epoch; self.createdAt = createdAt; self.state = state
        self.ownerDisplayName = ownerDisplayName; self.approverDisplayName = approverDisplayName
    }

    public func validate() throws {
        try requireIdentifier(pairingID, name: "pairing ID")
        try owner.validate(); try approver.validate()
        try requireTimestamp(createdAt, name: "pairing creation time")
        guard owner.role == .owner, approver.role == .trustedApprover, epoch > 0 else { throw CompanionError.malformed("invalid pairing") }
        try PairingFields.validateDisplayName(ownerDisplayName, name: "owner display name")
        try PairingFields.validateDisplayName(approverDisplayName, name: "approver display name")
    }

    /// `pairingID` the relay derives for the pairing an accepted invite creates.
    public static func derivedID(inviteID: String, approverIdentityID: String) -> String {
        String(base64URL(Data(SHA256.hash(data: CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).pairing", fields: [inviteID, approverIdentityID])))).prefix(32))
    }
}

// MARK: - Sessions, requests and approvals

public struct ActiveSession: Codable, Hashable, Sendable {
    public let owner: DeviceIdentity
    public let sessionID: String
    public let activeSetID: String
    public let startsAt: Date
    public let endsAt: Date

    public init(owner: DeviceIdentity, sessionID: String, activeSetID: String, startsAt: Date, endsAt: Date) throws {
        try requireIdentifier(sessionID, name: "session ID"); try requireIdentifier(activeSetID, name: "active set ID")
        guard owner.role == .owner, endsAt > startsAt,
              endsAt.timeIntervalSince(startsAt) <= CompanionLimits.maxSessionLifetime else { throw CompanionError.malformed("invalid session") }
        try owner.validate(); try requireTimestamp(startsAt, name: "session start"); try requireTimestamp(endsAt, name: "session end")
        self.owner = owner; self.sessionID = sessionID; self.activeSetID = activeSetID; self.startsAt = startsAt; self.endsAt = endsAt
    }

    public func isActive(at now: Date) -> Bool { now >= startsAt && now < endsAt }

    public func validate() throws {
        _ = try ActiveSession(owner: owner, sessionID: sessionID, activeSetID: activeSetID,
                              startsAt: startsAt, endsAt: endsAt)
    }
}

public enum TrustedRequestStatus: String, Codable, Sendable {
    case pending, approved, declined, cancelled, expired
}

public enum ApproverDecision: String, Codable, Sendable { case pending, approved, declined }

/// The pairing selected for one target is part of the request, not inferred
/// from the target's identity. This matters when one identity has multiple
/// active pairings (for example, after a re-pair on another device).
public struct RequestTargetBinding: Codable, Hashable, Sendable {
    public let approverIdentityID: String
    public let pairingID: String
    public let pairEpoch: UInt64
    /// The exact bilateral-consent generation observed when this target was
    /// selected. Zero is accepted only by legacy decoding and is never
    /// accepted by a relay request/approval reducer.
    public let consentGeneration: UInt64

    public init(pairing: Pairing, consentGeneration: UInt64 = 1) throws {
        try pairing.validate()
        guard pairing.state == .active else { throw CompanionError.revokedPairing }
        self.approverIdentityID = pairing.approver.identityID
        self.pairingID = pairing.pairingID
        self.pairEpoch = pairing.epoch
        self.consentGeneration = consentGeneration
    }

    public init(approverIdentityID: String, pairingID: String, pairEpoch: UInt64,
                consentGeneration: UInt64 = 1) throws {
        try requireIdentifier(approverIdentityID, name: "approver ID")
        try requireIdentifier(pairingID, name: "pairing ID")
        guard pairEpoch > 0 else { throw CompanionError.malformed("invalid pairing epoch") }
        self.approverIdentityID = approverIdentityID; self.pairingID = pairingID; self.pairEpoch = pairEpoch
        self.consentGeneration = consentGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case approverIdentityID, pairingID, pairEpoch, consentGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(approverIdentityID: c.decode(String.self, forKey: .approverIdentityID),
                      pairingID: c.decode(String.self, forKey: .pairingID),
                      pairEpoch: c.decode(UInt64.self, forKey: .pairEpoch),
                      consentGeneration: c.decodeIfPresent(UInt64.self, forKey: .consentGeneration) ?? 0)
    }

    public func validateShape() throws {
        try requireIdentifier(approverIdentityID, name: "approver ID")
        try requireIdentifier(pairingID, name: "pairing ID")
        guard pairEpoch > 0 else { throw CompanionError.malformed("invalid pairing epoch") }
    }
}

public struct TrustedRequest: Codable, Hashable, Sendable {
    public let requestID: String
    public let owner: DeviceIdentity
    /// Compatibility fields for the request's first target. All targets must
    /// also be checked through `targetBindings`.
    public let pairingID: String
    public let pairEpoch: UInt64
    /// Compatibility value for the first target. Multi-target requests bind
    /// each target's generation in `targetBindings`.
    public let consentGeneration: UInt64
    public let sessionID: String
    public let activeSetID: String
    public let purpose: TrustedRequestPurpose
    public let targetedApproverIDs: [String]
    public let targetBindings: [RequestTargetBinding]
    public let message: String?
    public let createdAt: Date
    public let expiresAt: Date
    public var status: TrustedRequestStatus
    public var decisions: [String: ApproverDecision]

    /// Kept for source compatibility with the original one-target API. A
    /// multi-target request must use the binding-aware initializer below.
    public init(requestID: String, owner: DeviceIdentity, pairing: Pairing, session: ActiveSession,
                targets: [String], message: String?, createdAt: Date, expiresAt: Date,
                purpose: TrustedRequestPurpose = .approveEarlyEnd) throws {
        guard targets.count == 1, targets.first == pairing.approver.identityID else {
            throw CompanionError.malformed("exact target pairing bindings required")
        }
        try self.init(requestID: requestID, owner: owner,
                      targetBindings: [RequestTargetBinding(pairing: pairing)], session: session,
                      message: message, createdAt: createdAt, expiresAt: expiresAt,
                      purpose: purpose)
    }

    public init(requestID: String, owner: DeviceIdentity, targetBindings: [RequestTargetBinding],
                session: ActiveSession, message: String?, createdAt: Date, expiresAt: Date,
                purpose: TrustedRequestPurpose = .approveEarlyEnd) throws {
        try requireIdentifier(requestID, name: "request ID")
        guard !targetBindings.isEmpty, targetBindings.count <= CompanionLimits.maxTargets,
              Set(targetBindings.map(\.approverIdentityID)).count == targetBindings.count,
              targetBindings.allSatisfy({ $0.consentGeneration > 0 }),
              session.owner == owner, purpose == .approveEarlyEnd,
              expiresAt > createdAt, expiresAt <= session.endsAt,
              expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime else {
            throw CompanionError.malformed("invalid trusted request")
        }
        for binding in targetBindings { try binding.validateShape() }
        // Trusted-person requests carry only session and relationship
        // identifiers. Free-form text could disclose selections, usage, or
        // task material, so new requests never accept a message.
        guard message == nil else { throw CompanionError.malformed("request material is not permitted") }
        try owner.validate(); try session.validate()
        let targets = targetBindings.map(\.approverIdentityID)
        self.requestID = requestID; self.owner = owner
        self.pairingID = targetBindings[0].pairingID; self.pairEpoch = targetBindings[0].pairEpoch
        self.consentGeneration = targetBindings[0].consentGeneration
        self.sessionID = session.sessionID; self.activeSetID = session.activeSetID
        self.purpose = purpose
        self.targetedApproverIDs = targets; self.targetBindings = targetBindings
        self.message = message; self.createdAt = createdAt; self.expiresAt = expiresAt; self.status = .pending
        self.decisions = Dictionary(uniqueKeysWithValues: targets.map { ($0, .pending) })
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, owner, pairingID, pairEpoch, consentGeneration, sessionID, activeSetID, purpose,
             targetedApproverIDs, targetBindings, message, createdAt, expiresAt, status, decisions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestID = try container.decode(String.self, forKey: .requestID)
        self.owner = try container.decode(DeviceIdentity.self, forKey: .owner)
        self.pairingID = try container.decode(String.self, forKey: .pairingID)
        self.pairEpoch = try container.decode(UInt64.self, forKey: .pairEpoch)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.activeSetID = try container.decode(String.self, forKey: .activeSetID)
        self.purpose = try container.decodeIfPresent(TrustedRequestPurpose.self, forKey: .purpose) ?? .approveEarlyEnd
        self.targetedApproverIDs = try container.decode([String].self, forKey: .targetedApproverIDs)
        let targetBindings = try container.decode([RequestTargetBinding].self, forKey: .targetBindings)
        self.targetBindings = targetBindings
        self.consentGeneration = try container.decodeIfPresent(UInt64.self, forKey: .consentGeneration)
            ?? targetBindings.first?.consentGeneration ?? 0
        // Drop the pre-scope free-form field during migration rather than
        // exposing historical material through a trusted-person inbox.
        self.message = nil
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        let decodedStatus = try container.decode(TrustedRequestStatus.self, forKey: .status)
        let legacyGeneration = self.consentGeneration == 0 || targetBindings.contains { $0.consentGeneration == 0 }
        // An old approved request is a historical artifact, not a capability.
        // Keep it inspectable as expired but never let a later consent grant
        // make it eligible again.
        self.status = legacyGeneration ? .expired : decodedStatus
        self.decisions = try container.decode([String: ApproverDecision].self, forKey: .decisions)
    }

    public func binding(for approverIdentityID: String) -> RequestTargetBinding? {
        targetBindings.first { $0.approverIdentityID == approverIdentityID }
    }

    public func validateShape() throws {
        try validateCommon()
        guard purpose == .approveEarlyEnd,
              consentGeneration > 0,
              targetBindings.allSatisfy({ $0.consentGeneration > 0 }),
              status == .pending, decisions.values.allSatisfy({ $0 == .pending }) else {
            throw CompanionError.malformed("invalid trusted request")
        }
    }

    func validatePersisted() throws {
        try validateCommon(allowLegacyTerminal: true)
        guard decisions.values.allSatisfy({ $0 == .pending || $0 == .approved || $0 == .declined }) else {
            throw CompanionError.malformed("invalid stored decision")
        }
    }

    private func validateCommon(allowLegacyTerminal: Bool = false) throws {
        try requireIdentifier(requestID, name: "request ID"); try owner.validate()
        try requireIdentifier(pairingID, name: "pairing ID"); try requireIdentifier(sessionID, name: "session ID")
        try requireIdentifier(activeSetID, name: "active set ID")
        guard purpose == .approveEarlyEnd else { throw CompanionError.unsupportedScope }
        guard pairEpoch > 0, !targetedApproverIDs.isEmpty, targetedApproverIDs.count <= CompanionLimits.maxTargets,
              Set(targetedApproverIDs).count == targetedApproverIDs.count,
              targetBindings.count == targetedApproverIDs.count,
              targetBindings.map(\.approverIdentityID) == targetedApproverIDs,
              targetBindings.first?.pairingID == pairingID, targetBindings.first?.pairEpoch == pairEpoch,
              targetBindings.first?.consentGeneration == consentGeneration,
              (consentGeneration > 0 && targetBindings.allSatisfy({ $0.consentGeneration > 0 })
               || (allowLegacyTerminal && status == .expired && consentGeneration == 0
                   && targetBindings.allSatisfy({ $0.consentGeneration == 0 }))),
              Set(decisions.keys) == Set(targetedApproverIDs), expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime else {
            throw CompanionError.malformed("invalid stored request")
        }
        for target in targetedApproverIDs { try requireIdentifier(target, name: "approver ID") }
        for binding in targetBindings { try binding.validateShape() }
        guard message == nil else { throw CompanionError.malformed("request material is not permitted") }
        try requireTimestamp(createdAt, name: "request time"); try requireTimestamp(expiresAt, name: "request expiry")
    }

    public func effectiveStatus(at now: Date) -> TrustedRequestStatus {
        if status == .cancelled || status == .declined { return status }
        return now >= expiresAt ? .expired : status
    }
}

public struct Approval: Codable, Hashable, Sendable {
    public let approvalID: String
    /// Fresh per approval. An empty value is accepted only when decoding a
    /// pre-generation snapshot; newly submitted approvals must carry a nonce.
    public let nonce: Data
    public let requestID: String
    public let pairingID: String
    public let pairEpoch: UInt64
    /// Bilateral consent generation bound into the approver signature.
    /// Generation zero is legacy and permanently unusable.
    public let consentGeneration: UInt64
    public let sessionID: String
    public let activeSetID: String
    public let approver: DeviceIdentity
    public let decision: ApproverDecision
    public let issuedAt: Date
    public let signature: Data

    public init(approvalID: String, requestID: String, pairingID: String, pairEpoch: UInt64,
                sessionID: String, activeSetID: String, approver: DeviceIdentity,
                decision: ApproverDecision, issuedAt: Date,
                consentGeneration: UInt64 = 0, nonce: Data = Data(), signature: Data) {
        self.approvalID = approvalID; self.requestID = requestID; self.pairingID = pairingID
        self.pairEpoch = pairEpoch; self.consentGeneration = consentGeneration
        self.sessionID = sessionID; self.activeSetID = activeSetID
        self.approver = approver; self.decision = decision; self.issuedAt = issuedAt
        self.nonce = nonce; self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case approvalID, nonce, requestID, pairingID, pairEpoch, consentGeneration, sessionID, activeSetID,
             approver, decision, issuedAt, signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.approvalID = try container.decode(String.self, forKey: .approvalID)
        self.nonce = try container.decodeIfPresent(Data.self, forKey: .nonce) ?? Data()
        self.requestID = try container.decode(String.self, forKey: .requestID)
        self.pairingID = try container.decode(String.self, forKey: .pairingID)
        self.pairEpoch = try container.decode(UInt64.self, forKey: .pairEpoch)
        self.consentGeneration = try container.decodeIfPresent(UInt64.self, forKey: .consentGeneration) ?? 0
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.activeSetID = try container.decode(String.self, forKey: .activeSetID)
        self.approver = try container.decode(DeviceIdentity.self, forKey: .approver)
        self.decision = try container.decode(ApproverDecision.self, forKey: .decision)
        self.issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        self.signature = try container.decode(Data.self, forKey: .signature)
    }

    public func signingFields() -> [String] {
        var fields = [approvalID, requestID, pairingID, String(pairEpoch), String(consentGeneration),
                      sessionID, activeSetID, approver.identityID, base64URL(approver.publicKey),
                      decision.rawValue, String(milliseconds(issuedAt))]
        if !nonce.isEmpty { fields.append(base64URL(nonce)) }
        return fields
    }

    private func legacySigningFields() -> [String] {
        [approvalID, requestID, pairingID, String(pairEpoch), sessionID, activeSetID, approver.identityID,
         base64URL(approver.publicKey), decision.rawValue, String(milliseconds(issuedAt))]
    }

    public func validateSignature() throws {
        try requireIdentifier(approvalID, name: "approval ID"); try requireIdentifier(requestID, name: "request ID")
        try requireIdentifier(pairingID, name: "pairing ID"); try requireIdentifier(sessionID, name: "session ID")
        try requireIdentifier(activeSetID, name: "active set ID"); try approver.validate(); try requireTimestamp(issuedAt, name: "approval time")
        guard pairEpoch > 0, decision != .pending,
              (consentGeneration > 0 && nonce.count >= 16 && nonce.count <= 64)
                || (consentGeneration == 0 && nonce.isEmpty), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: approver.publicKey),
              (key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).approval", fields: signingFields()))
               || (consentGeneration == 0 && nonce.isEmpty
                   && key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).approval", fields: legacySigningFields())))) else {
            throw CompanionError.invalidSignature
        }
    }
}

public struct ApprovalVerification: Codable, Hashable, Sendable {
    public let approval: Approval
    public let verifiedAt: Date
    public let useID: String

    public init(approval: Approval, verifiedAt: Date, useID: String) {
        self.approval = approval; self.verifiedAt = verifiedAt; self.useID = useID
    }
}

/// Shared by `CompanionClient.useApproval` (sync) and
/// `AsyncCompanionClient.useApproval` (`HTTPTransport.swift`). The relay's
/// "use" command already enforces every one of these checks server-side
/// before it ever returns a `.verification` result (`InMemoryRelay.swift`,
/// the TS reducer's `"use"` case); this is the client's own defense against a
/// malicious or buggy relay substituting a different approval, use ID, or
/// unapproved decision in its response. R5 Slice B2a.
func validateUseVerification(_ verification: ApprovalVerification, approval: Approval,
                             request: TrustedRequest, useID: String) throws {
    guard verification.approval == approval else {
        throw CompanionError.malformed("relay use verification does not match the submitted approval")
    }
    guard verification.useID == useID else {
        throw CompanionError.malformed("relay use verification carries a different use ID")
    }
    try verification.approval.validateSignature()
    guard verification.approval.requestID == request.requestID,
          verification.approval.sessionID == request.sessionID,
          verification.approval.activeSetID == request.activeSetID,
          let binding = request.binding(for: verification.approval.approver.identityID),
          binding.pairingID == verification.approval.pairingID,
          binding.pairEpoch == verification.approval.pairEpoch,
          binding.consentGeneration == verification.approval.consentGeneration else {
        throw CompanionError.wrongTarget
    }
    guard verification.approval.decision == .approved else {
        throw CompanionError.wrongTarget
    }
}

// MARK: - Signed relay envelope

public struct SignedOperation: Codable, Hashable, Sendable {
    public let operationID: String
    public let expectedRevision: UInt64?
    public let kind: String
    public let signer: DeviceIdentity
    public let body: Data
    public let signature: Data

    public init(operationID: String, expectedRevision: UInt64?, kind: String,
                signer: DeviceIdentity, body: Data, signature: Data) throws {
        try requireIdentifier(operationID, name: "operation ID")
        try requireIdentifier(kind, name: "operation kind")
        guard body.count <= 32_768, signature.count == 64 else { throw CompanionError.malformed("invalid operation") }
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.kind = kind; self.signer = signer; self.body = body; self.signature = signature
    }

    /// Compatibility initializer for callers that do not yet provide an
    /// operation ID. The derived ID is stable for an identical command body;
    /// its legacy signature field encoding remains accepted for migration.
    public init(kind: String, signer: DeviceIdentity, body: Data, signature: Data) throws {
        try self.init(operationID: Self.legacyOperationID(kind: kind, signer: signer, body: body),
                      expectedRevision: nil, kind: kind, signer: signer, body: body,
                      signature: signature)
    }

    private static func legacyOperationID(kind: String, signer: DeviceIdentity, body: Data) -> String {
        let digest = SHA256.hash(data: CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).legacy-operation-id",
            fields: [kind, signer.identityID, base64URL(CompanionCanonical.digest(body))]))
        return String(base64URL(Data(digest)).prefix(32))
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, expectedRevision, kind, signer, body, signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let signer = try container.decode(DeviceIdentity.self, forKey: .signer)
        let body = try container.decode(Data.self, forKey: .body)
        let signature = try container.decode(Data.self, forKey: .signature)
        let operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
            ?? Self.legacyOperationID(kind: kind, signer: signer, body: body)
        try self.init(operationID: operationID,
                      expectedRevision: try container.decodeIfPresent(UInt64.self, forKey: .expectedRevision),
                      kind: kind, signer: signer, body: body, signature: signature)
    }

    public func signingFields() -> [String] {
        [operationID, expectedRevision.map(String.init) ?? "none", kind,
         signer.identityID, base64URL(signer.publicKey), base64URL(CompanionCanonical.digest(body))]
    }

    public func validateSignature() throws {
        try requireIdentifier(operationID, name: "operation ID")
        try requireIdentifier(kind, name: "operation kind")
        guard body.count <= 32_768, signature.count == 64 else { throw CompanionError.malformed("invalid operation") }
        try signer.validate()
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey) else {
            throw CompanionError.invalidSignature
        }
        let currentFields = CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).operation",
                                                      fields: signingFields())
        let legacyFields = CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).operation",
                                                     fields: [kind, signer.identityID,
                                                              base64URL(signer.publicKey),
                                                              base64URL(CompanionCanonical.digest(body))])
        let hasDerivedLegacyID = operationID == Self.legacyOperationID(kind: kind,
                                                                        signer: signer,
                                                                        body: body)
        guard key.isValidSignature(signature, for: currentFields)
                || (expectedRevision == nil && hasDerivedLegacyID
                    && key.isValidSignature(signature, for: legacyFields)) else {
            throw CompanionError.invalidSignature
        }
    }
}

public struct RelaySnapshot: Codable, Sendable {
    // Bumped to 5 for R5 pairing v3 (docs/r5-pairing-v3-plan.md): invites carry
    // a token hash, display name and granted scopes; accept creates the pairing
    // directly (retaining the friend-signed acceptance per pairing), so there is
    // no `pendingAcceptances` any more. `validateSnapshot` requires an exact
    // `schemaVersion` match (no cross-version decoding is supported for this
    // reference/test-only snapshot format -- see docs/companion-security.md),
    // and this type backs only the developer harness's in-process relay (never
    // a field build's persisted data), so the bump carries no production
    // migration risk.
    static let currentSchemaVersion: UInt16 = 5
    let schemaVersion: UInt16
    let owner: DeviceIdentity
    let currentTime: Date
    let revision: UInt64
    let currentSessionID: String?
    let invitations: [Invitation]
    let usedInviteIDs: Set<String>
    let pairings: [Pairing]
    let joinAcceptances: [SignedAcceptance]
    let sessions: [ActiveSession]
    let requests: [TrustedRequest]
    let approvals: [Approval]
    let usedApprovalIDs: Set<String>
    let usedApprovalNonces: Set<String>
    let usedConsentNonces: Set<String>
    let relationshipConsents: [RelationshipConsent]
    let operationRecords: [RelayOperationRecord]

    init(owner: DeviceIdentity, currentTime: Date, revision: UInt64, currentSessionID: String?,
         invitations: [Invitation], usedInviteIDs: Set<String>,
         pairings: [Pairing], joinAcceptances: [SignedAcceptance], sessions: [ActiveSession],
         requests: [TrustedRequest], approvals: [Approval], usedApprovalIDs: Set<String>,
         usedApprovalNonces: Set<String> = [], usedConsentNonces: Set<String> = [],
         relationshipConsents: [RelationshipConsent] = [],
         operationRecords: [RelayOperationRecord]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.owner = owner; self.currentTime = currentTime; self.revision = revision
        self.currentSessionID = currentSessionID
        self.invitations = invitations; self.usedInviteIDs = usedInviteIDs
        self.pairings = pairings; self.joinAcceptances = joinAcceptances; self.sessions = sessions
        self.requests = requests; self.approvals = approvals; self.usedApprovalIDs = usedApprovalIDs
        self.usedApprovalNonces = usedApprovalNonces; self.usedConsentNonces = usedConsentNonces
        self.relationshipConsents = relationshipConsents
        self.operationRecords = operationRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, owner, currentTime, revision, currentSessionID, invitations,
             usedInviteIDs, pairings, joinAcceptances, sessions, requests, approvals,
             usedApprovalIDs, usedApprovalNonces, usedConsentNonces, relationshipConsents, operationRecords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(UInt16.self, forKey: .schemaVersion) ?? 0
        self.owner = try c.decode(DeviceIdentity.self, forKey: .owner)
        self.currentTime = try c.decode(Date.self, forKey: .currentTime)
        self.revision = try c.decode(UInt64.self, forKey: .revision)
        self.currentSessionID = try c.decodeIfPresent(String.self, forKey: .currentSessionID)
        self.invitations = try c.decode([Invitation].self, forKey: .invitations)
        self.usedInviteIDs = try c.decode(Set<String>.self, forKey: .usedInviteIDs)
        self.pairings = try c.decode([Pairing].self, forKey: .pairings)
        self.joinAcceptances = try c.decode([SignedAcceptance].self, forKey: .joinAcceptances)
        self.sessions = try c.decode([ActiveSession].self, forKey: .sessions)
        self.requests = try c.decode([TrustedRequest].self, forKey: .requests)
        self.approvals = try c.decode([Approval].self, forKey: .approvals)
        self.usedApprovalIDs = try c.decode(Set<String>.self, forKey: .usedApprovalIDs)
        self.usedApprovalNonces = try c.decodeIfPresent(Set<String>.self, forKey: .usedApprovalNonces) ?? []
        self.usedConsentNonces = try c.decodeIfPresent(Set<String>.self, forKey: .usedConsentNonces) ?? []
        self.relationshipConsents = try c.decodeIfPresent([RelationshipConsent].self, forKey: .relationshipConsents) ?? []
        self.operationRecords = try c.decode([RelayOperationRecord].self, forKey: .operationRecords)
    }
}

// MARK: - Local transport and client

public protocol CompanionTransport: Sendable {
    /// Reads the current bilateral-consent generation before a request is
    /// signed. A transport that cannot provide this must fail closed.
    func consent(relationshipID: String) throws -> RelationshipConsent

    /// A successful response includes the committed owner-scoped revision.
    /// Implementations must persist the response receipt atomically with the
    /// command before returning it.
    func submit(_ operation: SignedOperation) throws -> RelayResponse
    /// Foreground fetch is also authenticated. Notification/APNs delivery is
    /// intentionally outside this package and never authorizes an action.
    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse

    /// Pairing v3: resolves an invite lookup key (`InviteToken.lookupKeyString`) to
    /// the owner-signed invitation. The token itself is never sent. The caller
    /// must verify the result (`Invitation.validate(at:matchingToken:)`).
    func lookupInvite(lookupKey: String) throws -> Invitation
}

public extension CompanionTransport {
    func consent(relationshipID: String) throws -> RelationshipConsent {
        throw CompanionError.notFound
    }

    /// A transport that cannot look up invites fails closed.
    func lookupInvite(lookupKey: String) throws -> Invitation {
        throw CompanionError.notFound
    }
}

public enum RelayResult: Codable, Hashable, Sendable {
    case invitation(Invitation)
    case consent(RelationshipConsent)
    case acceptance(PairingAcceptance)
    case pairing(Pairing)
    case session(ActiveSession)
    case request(TrustedRequest)
    case approval(Approval)
    case verification(ApprovalVerification)
    case acknowledgement
}

/// Shared by both `CompanionClient.acceptInvite` (sync) and
/// `AsyncCompanionClient.acceptInvite` (async). The accept response is the
/// first time this device learns the owner-side pairing record, so it is
/// checked against what the friend actually accepted: the owner and scope
/// grant from the verified invitation, and this device as the approver. A
/// malicious relay answering with a different owner, a substituted approver key
/// or altered names must never be accepted.
func validateAcceptResponse(_ pairing: Pairing, invitation: Invitation, acceptance: PairingAcceptance,
                            signerIdentity: DeviceIdentity) throws {
    guard pairing.owner == invitation.payload.owner, pairing.approver == signerIdentity,
          pairing.approver == acceptance.approver,
          pairing.pairingID == Pairing.derivedID(inviteID: invitation.payload.inviteID, approverIdentityID: signerIdentity.identityID),
          pairing.ownerDisplayName == invitation.payload.ownerDisplayName,
          pairing.approverDisplayName == acceptance.approverDisplayName,
          pairing.state == .active else {
        throw CompanionError.malformed("relay accept response does not match the accepted invitation")
    }
    try pairing.validate()
}

/// What `createInvite` returns: the owner-signed invitation plus the one-time
/// token, which exists only here (the relay never receives it). Codable so the
/// owner app can persist it for as long as the pairing exists: the token is a
/// secret, so store it in the Keychain (or another protected store), never in
/// plain defaults, and delete it when the owner removes that person.
public struct IssuedInvite: Codable, Hashable, Sendable {
    public let invitation: Invitation
    public let token: String
    public var shareLink: String { InviteToken.shareLink(token: token) }
    public init(invitation: Invitation, token: String) { self.invitation = invitation; self.token = token }
}

/// Logging, `print`, `dump` and `Mirror` must never reveal the plaintext token (or the share link
/// derived from it). `Codable` is deliberately kept so the app can persist the value; the persisted
/// bytes contain the token, so they belong in the Keychain.
extension IssuedInvite: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "IssuedInvite(inviteID: \(invitation.payload.inviteID), token: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["inviteID": invitation.payload.inviteID, "token": "<redacted>"], displayStyle: .struct)
    }
}

public struct CompanionClient: Sendable {
    public let signer: DeviceSigner
    public let transport: any CompanionTransport
    public let identityAvailability: IdentityAvailability
    public let now: @Sendable () -> Date

    public init(signer: DeviceSigner, transport: any CompanionTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.signer = signer; self.transport = transport; self.identityAvailability = .available; self.now = now
    }

    public init(identity: DeviceIdentity, keyStore: any DeviceKeyStore, transport: any CompanionTransport,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        self.signer = try DeviceSigner(identity: identity, keyStore: keyStore)
        self.transport = transport; self.identityAvailability = .available; self.now = now
    }

    private func submit<T: Encodable>(_ kind: String, _ body: T) throws -> RelayResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        let operationID = operationIdentifier(kind: kind, signer: signer.identity, body: data)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: kind, signer: signer.identity, body: data,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        let operation = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                            kind: kind, signer: signer.identity, body: data,
                                            signature: signature)
        return try transport.submit(operation).validated(for: operation).result
    }

    /// Creates, signs and submits a pairing-v3 invite. The returned `token` is the
    /// only copy: the relay and the signed payload carry just its hash.
    public func createInvite(inviteID: String, validFor: TimeInterval, now: Date, nonce: Data? = nil,
                             token: String? = nil, ownerDisplayName: String? = nil,
                             grantedScopes: [CompanionScope] = [.approveEarlyEnd, .receiveRequests]) throws -> IssuedInvite {
        guard signer.identity.role == .owner, validFor > 0, validFor <= CompanionLimits.maxInviteLifetime else { throw CompanionError.unauthorized }
        let token = token ?? InviteToken.generate()
        guard InviteToken.isWellFormed(token) else { throw CompanionError.malformed("invalid invite token") }
        let payload = try InvitePayload(inviteID: inviteID, owner: signer.identity, issuedAt: now,
                                        expiresAt: now.addingTimeInterval(validFor), nonce: nonce ?? randomNonce(),
                                        tokenHash: InviteToken.inviteHash(token: token, ownerPublicKey: signer.identity.publicKey, inviteID: inviteID),
                                        lookupKey: InviteToken.lookupKey(token),
                                        possessionKey: try InviteToken.possessionPublicKey(token) ?? { throw CompanionError.malformed("invalid invite token") }(),
                                        ownerDisplayName: ownerDisplayName,
                                        grantedScopes: grantedScopes)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).invite.v3", fields: payload.signingFields())
        let invitation = try Invitation(payload: payload, signature: signature)
        _ = try submit("invite", invitation)
        return IssuedInvite(invitation: invitation, token: token)
    }

    /// Resolves a link token to its owner-signed invitation and verifies it
    /// (owner signature, still live, hash binds this exact token).
    public func lookupInvite(token: String) throws -> Invitation {
        guard InviteToken.isWellFormed(token) else { throw CompanionError.malformed("invalid invite token") }
        let invitation = try transport.lookupInvite(lookupKey: InviteToken.lookupKeyString(token))
        try invitation.validate(at: now(), matchingToken: token)
        return invitation
    }

    /// Accepting is the friend's consent to the granted scopes: one signed
    /// operation that yields the active pairing (and active consent). The
    /// response is checked against the invitation before it is returned.
    public func acceptInvite(_ invitation: Invitation, token: String, approverDisplayName: String? = nil,
                             acceptanceID: String, now: Date) throws -> Pairing {
        guard signer.identity.role == .trustedApprover else { throw CompanionError.unauthorized }
        try invitation.validate(at: now, matchingToken: token)
        let acceptance = try PairingAcceptance(acceptanceID: acceptanceID, invite: invitation.payload, token: token,
                                               approver: signer.identity, approverDisplayName: approverDisplayName, issuedAt: now)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).acceptance.v3", fields: acceptance.signingFields())
        guard case let .pairing(pairing) = try submit("accept", SignedAcceptance(acceptance: acceptance, signature: signature)) else {
            throw CompanionError.malformed("relay response")
        }
        try validateAcceptResponse(pairing, invitation: invitation, acceptance: acceptance, signerIdentity: signer.identity)
        return pairing
    }

    public func publishSession(_ session: ActiveSession) throws -> ActiveSession {
        guard signer.identity.role == .owner, session.owner == signer.identity else { throw CompanionError.unauthorized }
        guard case let .session(value) = try submit("session", session) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func grantScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) throws -> RelationshipConsent {
        guard signer.identity == pairing.owner else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: .ownerGrant,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func acceptScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) throws -> RelationshipConsent {
        guard signer.identity == pairing.approver else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: .approverAccept,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func revokeScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) throws -> RelationshipConsent {
        let action: ConsentMutationAction
        if signer.identity == pairing.owner { action = .ownerRevoke }
        else if signer.identity == pairing.approver { action = .approverRevoke }
        else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: action,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    /// A trusted-person approval is intentionally the only request purpose.
    /// The request contains session identity and selected relationship IDs,
    /// never policy selections, usage, steps, or task material.
    public func requestUnlock(requestID: String, pairing: Pairing, session: ActiveSession, target: String,
                              message: String?, validFor: TimeInterval) throws -> TrustedRequest {
        try requestUnlock(requestID: requestID, pairings: [pairing], session: session, targets: [target],
                          message: message, validFor: validFor)
    }

    /// Targets are explicit identities, each paired to the exact pairing ID
    /// and epoch selected by the owner. A target identity is not sufficient
    /// authorization when that identity has multiple active pairings.
    public func requestUnlock(requestID: String, pairings: [Pairing], session: ActiveSession,
                              targets: [String], message: String?, validFor: TimeInterval) throws -> TrustedRequest {
        guard !pairings.isEmpty, signer.identity == pairings[0].owner,
              pairings.count == targets.count,
              Set(targets).count == targets.count,
              zip(pairings, targets).allSatisfy({ $0.0.owner == signer.identity && $0.0.approver.identityID == $0.1 }) else { throw CompanionError.wrongTarget }
        let bindings = try pairings.map { pairing in
            guard let consent = try? transport.consent(relationshipID: pairing.pairingID),
                  consent.pairingID == pairing.pairingID,
                  consent.pairEpoch == pairing.epoch,
                  consent.generation > 0 else { throw CompanionError.consentRequired }
            return try RequestTargetBinding(pairing: pairing, consentGeneration: consent.generation)
        }
        let createdAt = now()
        let request = try TrustedRequest(requestID: requestID, owner: signer.identity,
                                         targetBindings: bindings, session: session,
                                         message: message, createdAt: createdAt, expiresAt: min(createdAt.addingTimeInterval(validFor), session.endsAt))
        guard case let .request(value) = try submit("request", request) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func submitApproval(request: TrustedRequest, pairing: Pairing, decision: ApproverDecision,
                                approvalID: String = UUID().uuidString, nonce: Data? = nil) throws -> Approval {
        guard signer.identity == pairing.approver else { throw CompanionError.unauthorized }
        guard let binding = request.binding(for: signer.identity.identityID),
              binding.pairingID == pairing.pairingID, binding.pairEpoch == pairing.epoch,
              binding.consentGeneration > 0 else { throw CompanionError.wrongTarget }
        let unsigned = Approval(approvalID: approvalID, requestID: request.requestID, pairingID: pairing.pairingID,
                                pairEpoch: pairing.epoch, sessionID: request.sessionID, activeSetID: request.activeSetID,
                                approver: signer.identity, decision: decision, issuedAt: now(),
                                consentGeneration: binding.consentGeneration,
                                nonce: nonce ?? randomNonce(), signature: Data())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).approval", fields: unsigned.signingFields())
        let approval = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID, pairingID: unsigned.pairingID,
                               pairEpoch: unsigned.pairEpoch, sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                               approver: unsigned.approver, decision: unsigned.decision, issuedAt: unsigned.issuedAt,
                               consentGeneration: unsigned.consentGeneration,
                               nonce: unsigned.nonce, signature: signature)
        guard case let .approval(value) = try submit("approval", approval) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func useApproval(_ approval: Approval, request: TrustedRequest, useID: String) throws -> ApprovalVerification {
        // This owner-identity guard, and any failure signing/submitting the
        // command below, are ordinary definitive rejections of this call --
        // never wrapped as `.responseVerificationFailed`, which is reserved
        // for the relay's response itself failing local verification (R5
        // Slice B2a review fix, N3).
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: useID,
                              consentGeneration: approval.consentGeneration)
        guard case let .verification(value) = try submit("use", use) else {
            throw CompanionError.responseVerificationFailed("relay \"use\" response was not a verification")
        }
        do {
            try validateUseVerification(value, approval: approval, request: request, useID: useID)
        } catch {
            throw CompanionError.responseVerificationFailed(String(describing: error))
        }
        return value
    }

    public func cancel(_ request: TrustedRequest) throws {
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        _ = try submit("cancel", RequestReference(requestID: request.requestID))
    }

    public func fetchInbox() throws -> [TrustedRequest] {
        let query = InboxQuery(identityID: signer.identity.identityID, issuedAt: now())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let operationID = operationIdentifier(kind: "inbox", signer: signer.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: "inbox", signer: signer.identity, body: body,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        let operation = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                            kind: "inbox", signer: signer.identity, body: body,
                                            signature: signature)
        let response = try transport.fetchInbox(operation)
        guard response.ownerIdentityID == signer.identity.identityID else {
            throw CompanionError.malformed("inbox response owner mismatch")
        }
        return response.requests
    }

    public func revoke(_ pairing: Pairing) throws {
        guard signer.identity == pairing.owner else { throw CompanionError.unauthorized }
        _ = try submit("revoke", PairingReference(pairingID: pairing.pairingID, epoch: pairing.epoch))
    }

    public func replacePairing(_ replacement: PairingReplacement) throws -> Pairing {
        guard signer.identity == replacement.owner, signer.identity.role == .owner else {
            throw CompanionError.unauthorized
        }
        guard case let .pairing(pairing) = try submit("replace_pairing", replacement) else {
            throw CompanionError.malformed("relay response")
        }
        return pairing
    }
}

/// Shared with `AsyncCompanionClient` in `HTTPTransport.swift`. Widened from
/// `private` to file-module visibility only for that reuse; behavior is
/// unchanged.
func randomNonce() -> Data {
    Data((0..<24).map { _ in UInt8.random(in: 0...255) })
}

func operationIdentifier(kind: String, signer: DeviceIdentity, body: Data) -> String {
    let digest = SHA256.hash(data: CompanionCanonical.bytes(
        domain: "\(CompanionCanonical.version).operation-id",
        fields: [kind, signer.identityID, base64URL(CompanionCanonical.digest(body))]))
    return String(base64URL(Data(digest)).prefix(32))
}

public struct SignedAcceptance: Codable, Hashable, Sendable {
    public let acceptance: PairingAcceptance
    public let signature: Data
    public init(acceptance: PairingAcceptance, signature: Data) { self.acceptance = acceptance; self.signature = signature }

    /// Verifies the approver's signature over `acceptance` (R5 pairing v2,
    /// `docs/r5-pairing-v2-plan.md`'s "Slice P2a", item 1: "Each entry
    /// includes the approver's signature material, so the owner can verify
    /// it."). Mirrors `Invitation.validateSignature()`'s shape: structural
    /// validation first, then the raw Ed25519 check against the canonical
    /// signed-field bytes.
    public func validateSignature() throws {
        try acceptance.validate()
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: acceptance.approver.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).acceptance.v3", fields: acceptance.signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }
}
public struct ApprovalUse: Codable, Sendable {
    public let approval: Approval
    public let requestID: String
    public let useID: String
    /// Redundant on purpose: a durable use command must carry the generation
    /// it intends to consume, not merely an opaque approval blob.
    public let consentGeneration: UInt64
    public init(approval: Approval, requestID: String, useID: String,
                consentGeneration: UInt64? = nil) {
        self.approval = approval; self.requestID = requestID; self.useID = useID
        self.consentGeneration = consentGeneration ?? approval.consentGeneration
    }
}
public struct InboxQuery: Codable, Sendable {
    public let identityID: String
    /// Signed freshness hint for the relay (this query body is covered by
    /// the enclosing `SignedOperation`'s signature, like every other
    /// operation kind). Optional so an older encoded query, or a relay that
    /// does not check it yet, still decodes; both `CompanionClient` and
    /// `AsyncCompanionClient` always populate it with the current time.
    public let issuedAt: Date?

    public init(identityID: String, issuedAt: Date? = nil) {
        self.identityID = identityID
        self.issuedAt = issuedAt
    }
}
public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}
/// Body of a `push_token` operation (`POST /v1/push-token`). Encoded exactly
/// like `InboxQuery`: `JSONEncoder` `.sortedKeys`, default `Date` encoding.
/// `token` is lowercase hex (64-200 chars); nil unregisters this identity's
/// tokens on `environment`. The key is omitted from the JSON when nil.
public struct PushTokenRegistration: Codable, Sendable, Equatable {
    public static let operationKind = "push_token"
    public let identityID: String
    public let issuedAt: Date
    public let token: String?
    public let environment: PushEnvironment

    public init(identityID: String, issuedAt: Date, token: String?, environment: PushEnvironment) {
        self.identityID = identityID; self.issuedAt = issuedAt
        self.token = token; self.environment = environment
    }

    public static func validate(token: String) throws {
        guard (64...200).contains(token.utf8.count),
              token.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw CompanionError.malformed("invalid push token")
        }
    }
}
public struct RequestReference: Codable, Sendable {
    public let requestID: String
    public init(requestID: String) { self.requestID = requestID }
}
public struct PairingReference: Codable, Sendable {
    public let pairingID: String
    public let epoch: UInt64
    public init(pairingID: String, epoch: UInt64) { self.pairingID = pairingID; self.epoch = epoch }
}

public extension RelaySnapshot {
    /// Hashes every authoritative snapshot field in a stable representation.
    /// Arrays whose order is not protocol meaning are sorted by their encoded
    /// bytes; request/decision dictionaries are included in their leaf JSON.
    func canonicalStateRoot() throws -> Data {
        func encodedList<T: Encodable>(_ values: [T]) throws -> Data {
            let encoded = try values.map { try CompanionCanonical.encoded($0) }
                .sorted { base64URL($0) < base64URL($1) }
            return CompanionCanonical.framed(domain: "\(CompanionCanonical.version).state-list", fields: encoded)
        }
        func encodedSet(_ values: Set<String>) throws -> Data {
            try encodedList(values.sorted())
        }
        let currentSession: Data
        if let currentSessionID {
            currentSession = try CompanionCanonical.encoded(currentSessionID)
        } else {
            currentSession = Data("null".utf8)
        }
        let fields: [Data] = [
            try CompanionCanonical.encoded(schemaVersion),
            try CompanionCanonical.encoded(owner),
            try CompanionCanonical.encoded(currentTime),
            try CompanionCanonical.encoded(revision),
            currentSession,
            try encodedList(invitations),
            try encodedSet(usedInviteIDs),
            try encodedList(pairings),
            try encodedList(joinAcceptances),
            try encodedList(sessions),
            try encodedList(requests),
            try encodedList(approvals),
            try encodedSet(usedApprovalIDs),
            try encodedSet(usedApprovalNonces),
            try encodedSet(usedConsentNonces),
            try encodedList(relationshipConsents),
            try encodedList(operationRecords)
        ]
        return CompanionCanonical.digest(CompanionCanonical.framed(
            domain: "\(CompanionCanonical.version).relay-state-root", fields: fields))
    }
}
