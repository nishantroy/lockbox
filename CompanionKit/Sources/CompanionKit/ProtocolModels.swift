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

    public func validate(at now: Date) throws {
        try payload.validate(at: now)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: payload.owner.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())) else {
            throw CompanionError.invalidSignature
        }
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

    public func validate() throws {
        try owner.validate(); try approver.validate()
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

public struct TrustedRequest: Codable, Hashable, Sendable {
    public let requestID: String
    public let owner: DeviceIdentity
    public let pairingID: String
    public let pairEpoch: UInt64
    public let sessionID: String
    public let activeSetID: String
    public let targetedApproverIDs: [String]
    public let message: String?
    public let createdAt: Date
    public let expiresAt: Date
    public var status: TrustedRequestStatus
    public var decisions: [String: ApproverDecision]

    public init(requestID: String, owner: DeviceIdentity, pairing: Pairing, session: ActiveSession,
                targets: [String], message: String?, createdAt: Date, expiresAt: Date) throws {
        try requireIdentifier(requestID, name: "request ID")
        guard owner == pairing.owner, pairing.state == .active, session.owner == owner,
              !targets.isEmpty, targets.count <= CompanionLimits.maxTargets,
              Set(targets).count == targets.count,
              targets.contains(pairing.approver.identityID),
              targets.allSatisfy({ (try? requireIdentifier($0, name: "approver ID")) != nil }),
              expiresAt > createdAt, expiresAt <= session.endsAt,
              expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime else {
            throw CompanionError.malformed("invalid trusted request")
        }
        if let message { guard !message.isEmpty, message.utf8.count <= CompanionLimits.maxMessageBytes else { throw CompanionError.malformed("message too long") } }
        try owner.validate()
        self.requestID = requestID; self.owner = owner; self.pairingID = pairing.pairingID; self.pairEpoch = pairing.epoch
        self.sessionID = session.sessionID; self.activeSetID = session.activeSetID; self.targetedApproverIDs = targets
        self.message = message; self.createdAt = createdAt; self.expiresAt = expiresAt; self.status = .pending
        self.decisions = Dictionary(uniqueKeysWithValues: targets.map { ($0, .pending) })
    }

    public func validateShape() throws {
        try requireIdentifier(requestID, name: "request ID"); try owner.validate()
        try requireIdentifier(pairingID, name: "pairing ID"); try requireIdentifier(sessionID, name: "session ID")
        try requireIdentifier(activeSetID, name: "active set ID")
        guard pairEpoch > 0, !targetedApproverIDs.isEmpty, targetedApproverIDs.count <= CompanionLimits.maxTargets,
              Set(targetedApproverIDs).count == targetedApproverIDs.count,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime,
              status == .pending, Set(decisions.keys) == Set(targetedApproverIDs),
              decisions.values.allSatisfy({ $0 == .pending }) else { throw CompanionError.malformed("invalid trusted request") }
        for target in targetedApproverIDs { try requireIdentifier(target, name: "approver ID") }
        if let message { guard !message.isEmpty, message.utf8.count <= CompanionLimits.maxMessageBytes else { throw CompanionError.malformed("message too long") } }
        try requireTimestamp(createdAt, name: "request time"); try requireTimestamp(expiresAt, name: "request expiry")
    }

    func validatePersisted() throws {
        try requireIdentifier(requestID, name: "request ID"); try owner.validate()
        try requireIdentifier(pairingID, name: "pairing ID"); try requireIdentifier(sessionID, name: "session ID")
        try requireIdentifier(activeSetID, name: "active set ID")
        guard pairEpoch > 0, !targetedApproverIDs.isEmpty, targetedApproverIDs.count <= CompanionLimits.maxTargets,
              Set(targetedApproverIDs).count == targetedApproverIDs.count,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime,
              Set(decisions.keys) == Set(targetedApproverIDs) else { throw CompanionError.malformed("invalid stored request") }
        for target in targetedApproverIDs { try requireIdentifier(target, name: "approver ID") }
        guard decisions.values.allSatisfy({ $0 == .pending || $0 == .approved || $0 == .declined }) else {
            throw CompanionError.malformed("invalid stored decision")
        }
        if let message { guard !message.isEmpty, message.utf8.count <= CompanionLimits.maxMessageBytes else { throw CompanionError.malformed("message too long") } }
        try requireTimestamp(createdAt, name: "request time"); try requireTimestamp(expiresAt, name: "request expiry")
    }

    public func effectiveStatus(at now: Date) -> TrustedRequestStatus {
        if status == .cancelled || status == .declined { return status }
        return now >= expiresAt ? .expired : status
    }
}

public struct Approval: Codable, Hashable, Sendable {
    public let approvalID: String
    public let requestID: String
    public let pairingID: String
    public let pairEpoch: UInt64
    public let sessionID: String
    public let activeSetID: String
    public let approver: DeviceIdentity
    public let decision: ApproverDecision
    public let issuedAt: Date
    public let signature: Data

    public func signingFields() -> [String] {
        [approvalID, requestID, pairingID, String(pairEpoch), sessionID, activeSetID, approver.identityID,
         base64URL(approver.publicKey), decision.rawValue, String(milliseconds(issuedAt))]
    }

    public func validateSignature() throws {
        try requireIdentifier(approvalID, name: "approval ID"); try requireIdentifier(requestID, name: "request ID")
        try requireIdentifier(pairingID, name: "pairing ID"); try requireIdentifier(sessionID, name: "session ID")
        try requireIdentifier(activeSetID, name: "active set ID"); try approver.validate(); try requireTimestamp(issuedAt, name: "approval time")
        guard pairEpoch > 0, decision != .pending, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: approver.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).approval", fields: signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }
}

public struct ApprovalVerification: Codable, Hashable, Sendable {
    public let approval: Approval
    public let verifiedAt: Date
    public let useID: String
}

// MARK: - Signed relay envelope

public struct SignedOperation: Codable, Hashable, Sendable {
    public let kind: String
    public let signer: DeviceIdentity
    public let body: Data
    public let signature: Data

    public init(kind: String, signer: DeviceIdentity, body: Data, signature: Data) throws {
        try requireIdentifier(kind, name: "operation kind")
        guard body.count <= 32_768, signature.count == 64 else { throw CompanionError.malformed("invalid operation") }
        self.kind = kind; self.signer = signer; self.body = body; self.signature = signature
    }

    public func validateSignature() throws {
        try requireIdentifier(kind, name: "operation kind")
        guard body.count <= 32_768, signature.count == 64 else { throw CompanionError.malformed("invalid operation") }
        try signer.validate()
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey),
              key.isValidSignature(signature,
                for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).operation",
                                              fields: [kind, signer.identityID, base64URL(signer.publicKey), base64URL(CompanionCanonical.digest(body))])) else {
            throw CompanionError.invalidSignature
        }
    }
}

public struct RelaySnapshot: Codable, Sendable {
    let owner: DeviceIdentity
    let currentTime: Date
    let invitations: [Invitation]
    let usedInviteIDs: Set<String>
    let pendingAcceptances: [PairingAcceptance]
    let pairings: [Pairing]
    let sessions: [ActiveSession]
    let requests: [TrustedRequest]
    let approvals: [Approval]
    let usedApprovalIDs: Set<String>

    init(owner: DeviceIdentity, currentTime: Date, invitations: [Invitation], usedInviteIDs: Set<String>,
         pendingAcceptances: [PairingAcceptance], pairings: [Pairing], sessions: [ActiveSession],
         requests: [TrustedRequest], approvals: [Approval], usedApprovalIDs: Set<String>) {
        self.owner = owner; self.currentTime = currentTime; self.invitations = invitations; self.usedInviteIDs = usedInviteIDs
        self.pendingAcceptances = pendingAcceptances; self.pairings = pairings; self.sessions = sessions
        self.requests = requests; self.approvals = approvals; self.usedApprovalIDs = usedApprovalIDs
    }
}

// MARK: - Local transport and client

public protocol CompanionTransport: Sendable {
    func submit(_ operation: SignedOperation) throws -> RelayResult
    /// Foreground fetch is also authenticated. Notification/APNs delivery is
    /// intentionally outside this package and never authorizes an action.
    func fetchInbox(_ operation: SignedOperation) throws -> [TrustedRequest]
}

public enum RelayResult: Sendable {
    case invitation(Invitation)
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
        let fields = [kind, signer.identity.identityID, base64URL(signer.identity.publicKey), base64URL(CompanionCanonical.digest(data))]
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation", fields: fields)
        return try transport.submit(SignedOperation(kind: kind, signer: signer.identity, body: data, signature: signature))
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

    public func requestUnlock(requestID: String, pairing: Pairing, session: ActiveSession, target: String,
                              message: String?, validFor: TimeInterval) throws -> TrustedRequest {
        try requestUnlock(requestID: requestID, pairings: [pairing], session: session, targets: [target],
                          message: message, validFor: validFor)
    }

    /// Targets are explicit identities, each backed by one active pairing. The
    /// first pairing is the request's primary epoch binding; approvals carry
    /// and independently validate their own pairing epoch.
    public func requestUnlock(requestID: String, pairings: [Pairing], session: ActiveSession,
                              targets: [String], message: String?, validFor: TimeInterval) throws -> TrustedRequest {
        guard let primary = pairings.first, signer.identity == primary.owner,
              pairings.count == targets.count,
              zip(pairings, targets).allSatisfy({ $0.0.approver.identityID == $0.1 }) else { throw CompanionError.wrongTarget }
        let createdAt = now()
        let request = try TrustedRequest(requestID: requestID, owner: signer.identity, pairing: primary, session: session,
                                         targets: targets, message: message, createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(validFor))
        guard case let .request(value) = try submit("request", request) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func submitApproval(request: TrustedRequest, pairing: Pairing, decision: ApproverDecision) throws -> Approval {
        guard signer.identity == pairing.approver else { throw CompanionError.unauthorized }
        let unsigned = Approval(approvalID: UUID().uuidString, requestID: request.requestID, pairingID: pairing.pairingID,
                                pairEpoch: pairing.epoch, sessionID: request.sessionID, activeSetID: request.activeSetID,
                                approver: signer.identity, decision: decision, issuedAt: now(), signature: Data())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).approval", fields: unsigned.signingFields())
        let approval = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID, pairingID: unsigned.pairingID,
                               pairEpoch: unsigned.pairEpoch, sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                               approver: unsigned.approver, decision: unsigned.decision, issuedAt: unsigned.issuedAt, signature: signature)
        guard case let .approval(value) = try submit("approval", approval) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func useApproval(_ approval: Approval, request: TrustedRequest, useID: String) throws -> ApprovalVerification {
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: useID)
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
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: ["inbox", signer.identity.identityID, base64URL(signer.identity.publicKey), base64URL(CompanionCanonical.digest(body))])
        return try transport.fetchInbox(SignedOperation(kind: "inbox", signer: signer.identity, body: body, signature: signature))
    }

    public func revoke(_ pairing: Pairing) throws {
        guard signer.identity == pairing.owner else { throw CompanionError.unauthorized }
        _ = try submit("revoke", PairingReference(pairingID: pairing.pairingID, epoch: pairing.epoch))
    }
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
    public init(approval: Approval, requestID: String, useID: String) { self.approval = approval; self.requestID = requestID; self.useID = useID }
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
