import Foundation
import CryptoKit

// MARK: - Invitation and pairing

public struct InvitePayload: Codable, Hashable, Sendable {
    public let inviteID: String
    public let owner: DeviceIdentity
    public let issuedAt: Date
    public let expiresAt: Date
    public let nonce: Data

    public init(inviteID: String, owner: DeviceIdentity, issuedAt: Date, expiresAt: Date, nonce: Data) throws {
        try requireIdentifier(inviteID, name: "invite ID")
        guard owner.role == .owner, nonce.count >= 16, nonce.count <= 64,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= CompanionLimits.maxInviteLifetime else {
            throw CompanionError.malformed("invalid invitation")
        }
        try requireTimestamp(issuedAt, name: "invite issue time")
        try requireTimestamp(expiresAt, name: "invite expiry")
        self.inviteID = inviteID; self.owner = owner; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.nonce = nonce
    }

    public func signingFields() -> [String] {
        [inviteID, owner.identityID, base64URL(owner.publicKey), String(milliseconds(issuedAt)), String(milliseconds(expiresAt)), base64URL(nonce)]
    }

    public func validate(at now: Date) throws {
        try owner.validate()
        guard nonce.count >= 16, nonce.count <= 64, expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= CompanionLimits.maxInviteLifetime else {
            throw CompanionError.malformed("invalid invitation")
        }
        try requireTimestamp(issuedAt, name: "invite issue time")
        try requireTimestamp(expiresAt, name: "invite expiry")
        guard now < expiresAt else { throw CompanionError.expired }
        guard now >= issuedAt.addingTimeInterval(-60) else { throw CompanionError.malformed("invite is from the future") }
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
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }

    public func validate(at now: Date) throws {
        try payload.validate(at: now)
        try validateSignature()
    }

    public var shareLink: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(self)).map(base64URL) ?? ""
        return "phone-lockbox-companion://invite/\(encoded)"
    }

    public static func fromShareLink(_ link: String) throws -> Invitation {
        let prefix = "phone-lockbox-companion://invite/"
        guard link.hasPrefix(prefix), let data = dataFromBase64URL(String(link.dropFirst(prefix.count))) else {
            throw CompanionError.malformed("invalid invite link")
        }
        do {
            let invitation = try JSONDecoder().decode(Invitation.self, from: data)
            try invitation.validate(at: invitation.payload.issuedAt)
            return invitation
        } catch let error as CompanionError { throw error }
        catch { throw CompanionError.malformed("invalid invite payload") }
    }
}

public struct PairingAcceptance: Codable, Hashable, Sendable {
    public let acceptanceID: String
    public let inviteID: String
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public let issuedAt: Date
    public let verificationCode: String

    public init(acceptanceID: String, invite: InvitePayload, approver: DeviceIdentity, issuedAt: Date) throws {
        try requireIdentifier(acceptanceID, name: "acceptance ID")
        try invite.validate(at: issuedAt)
        guard approver.role == .trustedApprover else { throw CompanionError.malformed("receiver is not an approver") }
        try approver.validate()
        guard issuedAt >= invite.issuedAt.addingTimeInterval(-60), issuedAt < invite.expiresAt else {
            throw CompanionError.expired
        }
        self.acceptanceID = acceptanceID; self.inviteID = invite.inviteID; self.owner = invite.owner
        self.approver = approver; self.issuedAt = issuedAt
        self.verificationCode = Self.code(invite: invite, approver: approver)
    }

    public static func code(invite: InvitePayload, approver: DeviceIdentity) -> String {
        let digest = SHA256.hash(data: CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).pairing-code",
            fields: [invite.inviteID, invite.owner.identityID, approver.identityID, base64URL(invite.nonce)]))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", number)
    }

    public func signingFields() -> [String] {
        [acceptanceID, inviteID, owner.identityID, approver.identityID,
         base64URL(owner.publicKey), base64URL(approver.publicKey), String(milliseconds(issuedAt)), verificationCode]
    }

    public func validate() throws {
        try requireIdentifier(acceptanceID, name: "acceptance ID")
        try requireIdentifier(inviteID, name: "invite ID")
        try owner.validate(); try approver.validate(); try requireTimestamp(issuedAt, name: "acceptance time")
        guard owner.role == .owner, approver.role == .trustedApprover,
              verificationCode.count == 6, verificationCode.allSatisfy(\.isNumber) else {
            throw CompanionError.malformed("invalid pairing acceptance")
        }
    }
}

public struct PairingConfirmation: Codable, Hashable, Sendable {
    public let acceptanceID: String
    public let inviteID: String
    public let owner: DeviceIdentity
    public let approverIdentityID: String
    public let verificationCode: String
    public let issuedAt: Date

    public init(acceptance: PairingAcceptance, owner: DeviceIdentity, verificationCode: String, issuedAt: Date) throws {
        try requireTimestamp(issuedAt, name: "confirmation time")
        guard owner == acceptance.owner, verificationCode.count == 6, verificationCode.allSatisfy(\.isNumber) else {
            throw CompanionError.unauthorized
        }
        self.acceptanceID = acceptance.acceptanceID; self.inviteID = acceptance.inviteID; self.owner = owner
        self.approverIdentityID = acceptance.approver.identityID; self.verificationCode = verificationCode; self.issuedAt = issuedAt
    }

    public func signingFields() -> [String] {
        [acceptanceID, inviteID, owner.identityID, approverIdentityID, verificationCode, String(milliseconds(issuedAt))]
    }
}

public enum PairingState: String, Codable, Sendable { case active, revoked }

public struct Pairing: Codable, Hashable, Sendable {
    public let pairingID: String
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public let epoch: UInt64
    public let createdAt: Date
    public var state: PairingState

    public init(pairingID: String, owner: DeviceIdentity, approver: DeviceIdentity,
                epoch: UInt64, createdAt: Date, state: PairingState) throws {
        try requireIdentifier(pairingID, name: "pairing ID")
        try owner.validate(); try approver.validate(); try requireTimestamp(createdAt, name: "pairing creation time")
        guard owner.role == .owner, approver.role == .trustedApprover, epoch > 0 else {
            throw CompanionError.malformed("invalid pairing")
        }
        self.pairingID = pairingID; self.owner = owner; self.approver = approver
        self.epoch = epoch; self.createdAt = createdAt; self.state = state
    }

    public func validate() throws {
        try requireIdentifier(pairingID, name: "pairing ID")
        try owner.validate(); try approver.validate()
        try requireTimestamp(createdAt, name: "pairing creation time")
        guard owner.role == .owner, approver.role == .trustedApprover, epoch > 0 else { throw CompanionError.malformed("invalid pairing") }
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
    static let currentSchemaVersion: UInt16 = 3
    let schemaVersion: UInt16
    let owner: DeviceIdentity
    let currentTime: Date
    let revision: UInt64
    let currentSessionID: String?
    let invitations: [Invitation]
    let usedInviteIDs: Set<String>
    let pendingAcceptances: [PairingAcceptance]
    let pairings: [Pairing]
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
         pendingAcceptances: [PairingAcceptance], pairings: [Pairing], sessions: [ActiveSession],
         requests: [TrustedRequest], approvals: [Approval], usedApprovalIDs: Set<String>,
         usedApprovalNonces: Set<String> = [], usedConsentNonces: Set<String> = [],
         relationshipConsents: [RelationshipConsent] = [],
         operationRecords: [RelayOperationRecord]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.owner = owner; self.currentTime = currentTime; self.revision = revision
        self.currentSessionID = currentSessionID
        self.invitations = invitations; self.usedInviteIDs = usedInviteIDs
        self.pendingAcceptances = pendingAcceptances; self.pairings = pairings; self.sessions = sessions
        self.requests = requests; self.approvals = approvals; self.usedApprovalIDs = usedApprovalIDs
        self.usedApprovalNonces = usedApprovalNonces; self.usedConsentNonces = usedConsentNonces
        self.relationshipConsents = relationshipConsents
        self.operationRecords = operationRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, owner, currentTime, revision, currentSessionID, invitations,
             usedInviteIDs, pendingAcceptances, pairings, sessions, requests, approvals,
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
        self.pendingAcceptances = try c.decode([PairingAcceptance].self, forKey: .pendingAcceptances)
        self.pairings = try c.decode([Pairing].self, forKey: .pairings)
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
}

public extension CompanionTransport {
    func consent(relationshipID: String) throws -> RelationshipConsent {
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

    public func createInvite(inviteID: String, validFor: TimeInterval, now: Date, nonce: Data? = nil) throws -> Invitation {
        guard signer.identity.role == .owner, validFor > 0, validFor <= CompanionLimits.maxInviteLifetime else { throw CompanionError.unauthorized }
        let payload = try InvitePayload(inviteID: inviteID, owner: signer.identity, issuedAt: now,
                                        expiresAt: now.addingTimeInterval(validFor), nonce: nonce ?? Data((0..<24).map { _ in UInt8.random(in: 0...255) }))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
        let invitation = try Invitation(payload: payload, signature: signature)
        _ = try submit("invite", invitation)
        return invitation
    }

    public func accept(_ invitation: Invitation, acceptanceID: String, now: Date) throws -> PairingAcceptance {
        guard signer.identity.role == .trustedApprover else { throw CompanionError.unauthorized }
        try invitation.validate(at: now)
        let acceptance = try PairingAcceptance(acceptanceID: acceptanceID, invite: invitation.payload, approver: signer.identity, issuedAt: now)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).acceptance", fields: acceptance.signingFields())
        let signed = SignedAcceptance(acceptance: acceptance, signature: signature)
        _ = try submit("accept", signed)
        return acceptance
    }

    public func confirm(_ acceptance: PairingAcceptance, verificationCode: String, now: Date) throws -> Pairing {
        guard signer.identity == acceptance.owner, signer.identity.role == .owner else { throw CompanionError.unauthorized }
        let confirmation = try PairingConfirmation(acceptance: acceptance, owner: signer.identity, verificationCode: verificationCode, issuedAt: now)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).confirmation", fields: confirmation.signingFields())
        guard case let .pairing(pairing) = try submit("confirm", SignedConfirmation(confirmation: confirmation, signature: signature)) else { throw CompanionError.malformed("relay response") }
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
                                         message: message, createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(validFor))
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
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: useID,
                              consentGeneration: approval.consentGeneration)
        guard case let .verification(value) = try submit("use", use) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func cancel(_ request: TrustedRequest) throws {
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        _ = try submit("cancel", RequestReference(requestID: request.requestID))
    }

    public func fetchInbox() throws -> [TrustedRequest] {
        let query = InboxQuery(identityID: signer.identity.identityID)
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

private func randomNonce() -> Data {
    Data((0..<24).map { _ in UInt8.random(in: 0...255) })
}

private func operationIdentifier(kind: String, signer: DeviceIdentity, body: Data) -> String {
    let digest = SHA256.hash(data: CompanionCanonical.bytes(
        domain: "\(CompanionCanonical.version).operation-id",
        fields: [kind, signer.identityID, base64URL(CompanionCanonical.digest(body))]))
    return String(base64URL(Data(digest)).prefix(32))
}

public struct SignedAcceptance: Codable, Sendable {
    public let acceptance: PairingAcceptance
    public let signature: Data
    public init(acceptance: PairingAcceptance, signature: Data) { self.acceptance = acceptance; self.signature = signature }
}
public struct SignedConfirmation: Codable, Sendable {
    public let confirmation: PairingConfirmation
    public let signature: Data
    public init(confirmation: PairingConfirmation, signature: Data) { self.confirmation = confirmation; self.signature = signature }
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
    public init(identityID: String) { self.identityID = identityID }
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
            try encodedList(pendingAcceptances),
            try encodedList(pairings),
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
