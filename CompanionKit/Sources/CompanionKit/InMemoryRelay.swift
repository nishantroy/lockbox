import Foundation
import CryptoKit

/// A deterministic, process-local relay used by the developer prototype and
/// tests. It exercises authentication and replay rules but is not a network
/// service, APNs provider, or remote-unlock implementation.
public final class InMemoryCompanionRelay: CompanionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var owner: DeviceIdentity
    private var invitations: [String: Invitation] = [:]
    private var usedInviteIDs = Set<String>()
    private var pendingAcceptances: [String: PairingAcceptance] = [:]
    private var pairings: [String: Pairing] = [:]
    private var sessions: [String: ActiveSession] = [:]
    private var requests: [String: TrustedRequest] = [:]
    private var approvals: [String: Approval] = [:]
    private var usedApprovalIDs = Set<String>()
    private var operationTimes: [String: [Date]] = [:]
    public private(set) var currentTime: Date

    public init(owner: DeviceIdentity, now: Date = Date()) throws {
        guard owner.role == .owner else { throw CompanionError.unauthorized }
        try owner.validate(); try requireTimestamp(now, name: "relay time")
        self.owner = owner; self.currentTime = now
    }

    public convenience init(snapshot data: Data) throws {
        let snapshot: RelaySnapshot
        do { snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: data) }
        catch { throw CompanionError.malformed("invalid relay snapshot") }
        guard snapshot.invitations.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.pendingAcceptances.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.pairings.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.sessions.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.requests.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.approvals.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedInviteIDs.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedApprovalIDs.count <= CompanionLimits.maxSnapshotRecords else {
            throw CompanionError.malformed("relay snapshot too large")
        }
        try snapshot.owner.validate()
        for inviteID in snapshot.usedInviteIDs { try requireIdentifier(inviteID, name: "used invite ID") }
        for approvalID in snapshot.usedApprovalIDs { try requireIdentifier(approvalID, name: "used approval ID") }
        try self.init(owner: snapshot.owner, now: snapshot.currentTime)
        for invitation in snapshot.invitations {
            try invitation.payload.validate(at: invitation.payload.issuedAt)
            guard invitations[invitation.payload.inviteID] == nil else { throw CompanionError.malformed("duplicate invite") }
            invitations[invitation.payload.inviteID] = invitation
        }
        self.usedInviteIDs = snapshot.usedInviteIDs
        for acceptance in snapshot.pendingAcceptances {
            try acceptance.validate()
            guard pendingAcceptances[acceptance.acceptanceID] == nil else { throw CompanionError.malformed("duplicate acceptance") }
            pendingAcceptances[acceptance.acceptanceID] = acceptance
        }
        for pairing in snapshot.pairings {
            try pairing.validate()
            guard pairings[pairing.pairingID] == nil else { throw CompanionError.malformed("duplicate pairing") }
            pairings[pairing.pairingID] = pairing
        }
        for session in snapshot.sessions {
            try session.validate()
            guard sessions[session.owner.identityID] == nil else { throw CompanionError.malformed("duplicate session") }
            sessions[session.owner.identityID] = session
        }
        for request in snapshot.requests {
            try request.validatePersisted()
            guard requests[request.requestID] == nil else { throw CompanionError.malformed("duplicate request") }
            requests[request.requestID] = request
        }
        for approval in snapshot.approvals {
            try approval.validateSignature()
            guard approvals[approval.approvalID] == nil else { throw CompanionError.malformed("duplicate approval") }
            approvals[approval.approvalID] = approval
        }
        self.usedApprovalIDs = snapshot.usedApprovalIDs
    }

    public func advance(to time: Date) throws {
        try requireTimestamp(time, name: "relay time")
        lock.lock(); defer { lock.unlock() }
        guard time >= currentTime else { throw CompanionError.malformed("relay clock cannot go backwards") }
        currentTime = time
    }

    public func snapshot() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let value = RelaySnapshot(owner: owner, currentTime: currentTime,
                                  invitations: invitations.values.sorted { $0.payload.inviteID < $1.payload.inviteID },
                                  usedInviteIDs: usedInviteIDs,
                                  pendingAcceptances: pendingAcceptances.values.sorted { $0.acceptanceID < $1.acceptanceID },
                                  pairings: pairings.values.sorted { $0.pairingID < $1.pairingID },
                                  sessions: sessions.values.sorted { $0.sessionID < $1.sessionID },
                                  requests: requests.values.sorted { $0.requestID < $1.requestID },
                                  approvals: approvals.values.sorted { $0.approvalID < $1.approvalID },
                                  usedApprovalIDs: usedApprovalIDs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public func fetchInbox(_ operation: SignedOperation) throws -> [TrustedRequest] {
        lock.lock(); defer { lock.unlock() }
        try operation.validateSignature()
        guard operation.kind == "inbox" else { throw CompanionError.malformed("invalid inbox operation") }
        let query = try decode(InboxQuery.self, operation.body)
        guard query.identityID == operation.signer.identityID else { throw CompanionError.unauthorized }
        try charge(operation.signer.identityID)
        var values = requests.values.filter { $0.owner.identityID == query.identityID || $0.targetedApproverIDs.contains(query.identityID) }
        values = values.map { request in
            var copy = request; updateExpiry(&copy); return copy
        }
        return values.sorted { $0.createdAt < $1.createdAt }
    }

    public func pairing(id: String) throws -> Pairing {
        lock.lock(); defer { lock.unlock() }
        guard let pairing = pairings[id] else { throw CompanionError.notFound }
        return pairing
    }

    public func request(id: String) throws -> TrustedRequest {
        lock.lock(); defer { lock.unlock() }
        guard var request = requests[id] else { throw CompanionError.notFound }
        updateExpiry(&request)
        requests[id] = request
        return request
    }

    public func submit(_ operation: SignedOperation) throws -> RelayResult {
        lock.lock(); defer { lock.unlock() }
        try operation.validateSignature()
        try charge(operation.signer.identityID)
        switch operation.kind {
        case "invite":
            let invitation = try decode(Invitation.self, operation.body)
            guard operation.signer == owner, invitation.payload.owner == owner else { throw CompanionError.unauthorized }
            try invitation.validate(at: currentTime)
            guard invitations[invitation.payload.inviteID] == nil, !usedInviteIDs.contains(invitation.payload.inviteID) else { throw CompanionError.replay }
            invitations[invitation.payload.inviteID] = invitation
            return .invitation(invitation)

        case "accept":
            let signed = try decode(SignedAcceptance.self, operation.body)
            guard operation.signer == signed.acceptance.approver else { throw CompanionError.unauthorized }
            try signed.acceptance.validate()
            guard signed.acceptance.owner == owner,
                  let invitation = invitations[signed.acceptance.inviteID],
                  invitation.payload.owner == signed.acceptance.owner,
                  !usedInviteIDs.contains(signed.acceptance.inviteID), currentTime < invitation.payload.expiresAt,
                  signed.acceptance.issuedAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.unauthorized }
            guard verify(signed.signature, domain: "\(CompanionCanonical.version).acceptance", fields: signed.acceptance.signingFields(), key: signed.acceptance.approver.publicKey) else { throw CompanionError.invalidSignature }
            guard pendingAcceptances[signed.acceptance.acceptanceID] == nil else { throw CompanionError.replay }
            pendingAcceptances[signed.acceptance.acceptanceID] = signed.acceptance
            return .acceptance(signed.acceptance)

        case "confirm":
            let signed = try decode(SignedConfirmation.self, operation.body)
            guard operation.signer == owner, signed.confirmation.owner == owner else { throw CompanionError.unauthorized }
            try requireTimestamp(signed.confirmation.issuedAt, name: "confirmation time")
            guard let acceptance = pendingAcceptances[signed.confirmation.acceptanceID],
                  acceptance.inviteID == signed.confirmation.inviteID,
                  acceptance.approver.identityID == signed.confirmation.approverIdentityID,
                  let invitation = invitations[acceptance.inviteID], currentTime < invitation.payload.expiresAt,
                  signed.confirmation.issuedAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.expired }
            guard verify(signed.signature, domain: "\(CompanionCanonical.version).confirmation", fields: signed.confirmation.signingFields(), key: owner.publicKey) else { throw CompanionError.invalidSignature }
            guard acceptance.verificationCode == signed.confirmation.verificationCode,
                  PairingAcceptance.code(invite: invitation.payload, approver: acceptance.approver) == signed.confirmation.verificationCode else { throw CompanionError.wrongVerificationCode }
            usedInviteIDs.insert(acceptance.inviteID)
            pendingAcceptances.removeValue(forKey: acceptance.acceptanceID)
            let pairingID = base64URL(Data(SHA256.hash(data: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).pairing", fields: [acceptance.inviteID, acceptance.approver.identityID])))).prefix(32).description
            let pairing = Pairing(pairingID: pairingID, owner: owner, approver: acceptance.approver, epoch: 1, createdAt: currentTime, state: .active)
            pairings[pairingID] = pairing
            return .pairing(pairing)

        case "session":
            let session = try decode(ActiveSession.self, operation.body)
            guard operation.signer == owner, session.owner == owner, session.startsAt <= currentTime.addingTimeInterval(60),
                  session.endsAt > currentTime else { throw CompanionError.invalidTransition }
            try session.validate()
            // Replacing the active set makes every old request stale, even when
            // the new session happens to use the same human-readable policy.
            sessions[owner.identityID] = session
            expireRequests(supersededBy: session)
            return .session(session)

        case "request":
            let request = try decode(TrustedRequest.self, operation.body)
            guard operation.signer == owner, request.owner == owner,
                  let session = sessions[owner.identityID], session.sessionID == request.sessionID,
                  session.activeSetID == request.activeSetID, session.isActive(at: currentTime),
                  request.createdAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.staleSession }
            try request.validateShape()
            try validateRequestPairing(request, session: session)
            guard requests[request.requestID] == nil else { throw CompanionError.replay }
            requests[request.requestID] = request
            return .request(request)

        case "approval":
            let approval = try decode(Approval.self, operation.body)
            guard operation.signer == approval.approver else { throw CompanionError.unauthorized }
            try approval.validateSignature()
            guard approvals[approval.approvalID] == nil,
                  !usedApprovalIDs.contains(approval.approvalID) else { throw CompanionError.replay }
            guard let request = requests[approval.requestID] else { throw CompanionError.notFound }
            var currentRequest = request; updateExpiry(&currentRequest); requests[request.requestID] = currentRequest
            guard currentRequest.effectiveStatus(at: currentTime) == .pending,
                  currentRequest.sessionID == approval.sessionID, currentRequest.activeSetID == approval.activeSetID,
                  currentRequest.targetedApproverIDs.contains(approval.approver.identityID),
                  let pairing = pairings[approval.pairingID], pairing.owner == owner,
                  pairing.approver == approval.approver, pairing.epoch == approval.pairEpoch,
                  pairing.state == .active else { throw CompanionError.wrongTarget }
            guard approval.issuedAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.expired }
            guard currentRequest.decisions[approval.approver.identityID] == .pending else { throw CompanionError.replay }
            approvals[approval.approvalID] = approval
            currentRequest.decisions[approval.approver.identityID] = approval.decision
            if approval.decision == .approved { currentRequest.status = .approved }
            else if currentRequest.decisions.values.allSatisfy({ $0 == .declined }) { currentRequest.status = .declined }
            requests[request.requestID] = currentRequest
            return .approval(approval)

        case "use":
            let use = try decode(ApprovalUse.self, operation.body)
            try requireIdentifier(use.useID, name: "use ID")
            guard operation.signer == owner, let request = requests[use.requestID], request.owner == owner else { throw CompanionError.unauthorized }
            // Only the immutable approval record created by the relay can be
            // consumed. A valid signature alone is not proof that the relay
            // accepted the approval or that its target actually approved.
            guard let acceptedApproval = approvals[use.approval.approvalID],
                  acceptedApproval == use.approval else { throw CompanionError.replay }
            var currentRequest = request; updateExpiry(&currentRequest); requests[request.requestID] = currentRequest
            let currentSession = sessions[owner.identityID]
            guard currentRequest.effectiveStatus(at: currentTime) == .approved,
                  currentSession?.isActive(at: currentTime) == true,
                  currentRequest.sessionID == currentSession?.sessionID,
                  currentRequest.activeSetID == currentSession?.activeSetID,
                  acceptedApproval.requestID == currentRequest.requestID,
                  acceptedApproval.sessionID == currentRequest.sessionID,
                  acceptedApproval.activeSetID == currentRequest.activeSetID,
                  currentRequest.targetedApproverIDs.contains(acceptedApproval.approver.identityID),
                  currentRequest.decisions[acceptedApproval.approver.identityID] == .approved,
                  !usedApprovalIDs.contains(acceptedApproval.approvalID),
                  !usedApprovalIDs.contains(use.useID),
                  use.approval.requestID == use.requestID,
                  use.approval.decision == .approved else { throw CompanionError.replay }
            guard let pairing = pairings[acceptedApproval.pairingID], pairing.owner == owner,
                  pairing.state == .active, pairing.epoch == acceptedApproval.pairEpoch,
                  pairing.approver == acceptedApproval.approver else {
                throw CompanionError.revokedPairing
            }
            try acceptedApproval.validateSignature()
            usedApprovalIDs.insert(acceptedApproval.approvalID); usedApprovalIDs.insert(use.useID)
            return .verification(ApprovalVerification(approval: acceptedApproval, verifiedAt: currentTime, useID: use.useID))

        case "cancel":
            let reference = try decode(RequestReference.self, operation.body)
            guard operation.signer == owner, var request = requests[reference.requestID], request.owner == owner else { throw CompanionError.unauthorized }
            updateExpiry(&request)
            guard request.effectiveStatus(at: currentTime) == .pending || request.effectiveStatus(at: currentTime) == .approved else {
                throw CompanionError.invalidTransition
            }
            if request.effectiveStatus(at: currentTime) == .approved {
                let hasConsumedApproval = approvals.values.contains {
                    $0.requestID == request.requestID && $0.decision == .approved && usedApprovalIDs.contains($0.approvalID)
                }
                guard !hasConsumedApproval else { throw CompanionError.invalidTransition }
            }
            // Cancellation is durable before the acknowledgement is returned;
            // a later use cannot race this state transition under the relay lock.
            request.status = .cancelled; requests[reference.requestID] = request
            return .acknowledgement

        case "revoke":
            let reference = try decode(PairingReference.self, operation.body)
            guard operation.signer == owner, var pairing = pairings[reference.pairingID], pairing.owner == owner,
                  pairing.epoch == reference.epoch else { throw CompanionError.unauthorized }
            pairing.state = .revoked; pairings[reference.pairingID] = pairing
            return .acknowledgement

        default:
            throw CompanionError.malformed("unknown operation")
        }
    }

    private func validateRequestPairing(_ request: TrustedRequest, session: ActiveSession) throws {
        guard let primary = pairings[request.pairingID], primary.owner == owner,
              primary.approver.identityID == request.targetedApproverIDs.first,
              primary.state == .active, primary.epoch == request.pairEpoch else { throw CompanionError.revokedPairing }
        for target in request.targetedApproverIDs {
            guard pairings.values.contains(where: { $0.owner == owner && $0.approver.identityID == target && $0.state == .active }) else {
                throw CompanionError.wrongTarget
            }
        }
        guard request.expiresAt <= session.endsAt else { throw CompanionError.expired }
    }

    private func expireRequests(supersededBy session: ActiveSession) {
        for key in requests.keys {
            var request = requests[key]!
            if request.sessionID != session.sessionID || request.activeSetID != session.activeSetID {
                if request.status != .cancelled && request.status != .declined { request.status = .expired }
            } else {
                updateExpiry(&request)
            }
            requests[key] = request
        }
    }

    private func updateExpiry(_ request: inout TrustedRequest) {
        if request.status != .cancelled && request.status != .declined,
           (currentTime >= request.expiresAt || sessions[owner.identityID].map({ currentTime >= $0.endsAt }) == true) {
            request.status = .expired
        }
    }

    private func charge(_ identityID: String) throws {
        let cutoff = currentTime.addingTimeInterval(-CompanionLimits.rateWindow)
        var events = (operationTimes[identityID] ?? []).filter { $0 > cutoff }
        guard events.count < CompanionLimits.maxRateOperations else { throw CompanionError.rateLimited }
        events.append(currentTime); operationTimes[identityID] = events
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CompanionError.malformed("invalid operation body") }
    }

    private func verify(_ signature: Data, domain: String, fields: [String], key: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature, for: CompanionCanonical.bytes(domain: domain, fields: fields))
    }
}
