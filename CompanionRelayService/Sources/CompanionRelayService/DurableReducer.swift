import Foundation
import CryptoKit
import CompanionKit

/// A late request command terminalizes the request and is recorded as a
/// rejected operation by the enclosing transaction. It is deliberately not a
/// normal reducer result, so no approval/use can be mistaken for success.
enum DurableProtocolTransitionError: Error {
    case requestExpired
}

/// The only stateful durable protocol implementation. Every case runs while
/// the caller holds the owner ledger transaction lock; no generic closure is
/// allowed to authorize or mutate these records.
enum DurableProtocolReducer {
    static func apply(kind: String, envelope: DurableOperationEnvelope,
                      signer: DeviceIdentity, owner: DeviceIdentity,
                      ledger: inout DurableOwnerLedger, now: Date) throws -> RelayResult {
        try validateTimestamp(now)
        switch kind {
        case "ack":
            guard signer == owner, envelope.payload == Data("{}".utf8) else {
                throw CompanionError.malformed("ack must have an empty payload")
            }
            return .acknowledgement

        case "invite":
            let invitation = try decode(Invitation.self, envelope.payload)
            guard signer == owner, invitation.payload.owner == owner else { throw CompanionError.unauthorized }
            try invitation.validate(at: now)
            guard ledger.invitations[invitation.payload.inviteID] == nil else { throw CompanionError.replay }
            // A token hash identifies exactly one invite (the lookup key).
            guard !ledger.invitations.values.contains(where: { $0.invitation.payload.tokenHash == invitation.payload.tokenHash }) else {
                throw CompanionError.replay
            }
            ledger.invitations[invitation.payload.inviteID] = DurableInvitationRecord(invitation: invitation)
            return .invitation(invitation)

        case "accept":
            // Pairing v3: one friend-signed operation consumes the invite and
            // creates the active pairing and both-sided consent together.
            let signed = try decode(SignedAcceptance.self, envelope.payload)
            let acceptance = signed.acceptance
            guard signer == acceptance.approver else { throw CompanionError.unauthorized }
            try acceptance.validate()
            guard acceptance.owner == owner else { throw CompanionError.unauthorized }
            // Unknown invite, wrong token and a bad signature are one indistinguishable failure.
            guard let record = ledger.invitations[acceptance.inviteID],
                  record.invitation.payload.owner == owner,
                  InviteToken.matches(acceptance.token, hash: record.invitation.payload.tokenHash),
                  verify(signed.signature, domain: "\(CompanionCanonical.version).acceptance.v3",
                         fields: acceptance.signingFields(), key: acceptance.approver.publicKey) else {
                throw CompanionError.unauthorized
            }
            let invitePayload = record.invitation.payload
            guard record.consumedAt == nil else { throw CompanionError.replay }
            guard now < invitePayload.expiresAt,
                  acceptance.issuedAt <= now.addingTimeInterval(60),
                  acceptance.issuedAt >= invitePayload.issuedAt.addingTimeInterval(-60),
                  acceptance.issuedAt < invitePayload.expiresAt else { throw CompanionError.expired }
            guard acceptance.acceptedScopes.sorted(by: { $0.rawValue < $1.rawValue }) == invitePayload.grantedScopes else {
                throw CompanionError.consentRequired
            }
            let pairingID = Pairing.derivedID(inviteID: acceptance.inviteID, approverIdentityID: acceptance.approver.identityID)
            guard ledger.pairings[pairingID] == nil else { throw CompanionError.replay }
            let epoch = try checkedPairingEpoch(ledger.pairingEpochs[pairingID] ?? 0)
            let pairing = try Pairing(pairingID: pairingID, owner: owner, approver: acceptance.approver,
                                      epoch: epoch, createdAt: now, state: .active,
                                      ownerDisplayName: invitePayload.ownerDisplayName,
                                      approverDisplayName: acceptance.approverDisplayName)
            // Equivalent to the owner-grant + approver-accept pair of mutations,
            // applied atomically: generation 2, both sides active.
            let consent = try RelationshipConsent(relationshipID: pairingID, pairingID: pairingID, pairEpoch: epoch,
                                                  owner: owner, approver: acceptance.approver,
                                                  ownerScopes: invitePayload.grantedScopes,
                                                  approverScopes: acceptance.acceptedScopes,
                                                  ownerState: .active, approverState: .active,
                                                  updatedAt: now, generation: 2)
            ledger.invitations[acceptance.inviteID]?.consumedAt = now
            ledger.pairings[pairingID] = DurablePairingRecord(pairing: pairing)
            ledger.pairingEpochs[pairingID] = epoch
            ledger.relationshipConsents[pairingID] = consent
            return .pairing(pairing)

        case "consent":
            let mutation = try decode(RelationshipConsentMutation.self, envelope.payload)
            guard mutation.scopes.scopes.allSatisfy(\.isR5) else {
                throw CompanionError.unsupportedScope
            }
            guard mutation.owner == owner,
                  mutation.relationshipID == mutation.pairingID,
                  let pairingRecord = ledger.pairings[mutation.pairingID],
                  pairingRecord.pairing.owner == owner,
                  pairingRecord.pairing.approver == mutation.approver,
                  pairingRecord.pairing.epoch == mutation.pairEpoch,
                  pairingRecord.pairing.state == .active,
                  mutation.issuedAt <= now.addingTimeInterval(60) else {
                throw CompanionError.wrongTarget
            }
            let ownerAction = mutation.action == .ownerGrant || mutation.action == .ownerRevoke
            let signerIsOwner = signer == owner
            let signerIsApprover = signer == pairingRecord.pairing.approver
            guard (ownerAction && signerIsOwner) || (!ownerAction && signerIsApprover) else {
                throw CompanionError.unauthorized
            }
            let nonceKey = durableBase64URL(mutation.nonce)
            guard !ledger.usedConsentNonces.contains(nonceKey) else { throw CompanionError.replay }
            var consent = try (ledger.relationshipConsents[mutation.relationshipID]
                ?? RelationshipConsent(relationshipID: mutation.relationshipID,
                                             pairingID: pairingRecord.pairing.pairingID,
                                             pairEpoch: pairingRecord.pairing.epoch,
                                             owner: owner, approver: pairingRecord.pairing.approver,
                                             ownerState: .revoked, approverState: .revoked,
                                             updatedAt: now, generation: 0))
            switch mutation.action {
            case .ownerGrant:
                consent.ownerScopes = mutation.scopes.scopes
                consent.approverScopes = consent.approverScopes.filter { mutation.scopes.contains($0) }
                consent.ownerState = mutation.scopes.isEmpty ? .revoked : .active
                consent.approverState = consent.approverScopes.isEmpty ? .pending : .active
            case .approverAccept:
                guard Set(mutation.scopes.scopes).isSubset(of: Set(consent.ownerScopes)) else {
                    throw CompanionError.consentRequired
                }
                consent.approverScopes = mutation.scopes.scopes
                consent.approverState = mutation.scopes.isEmpty ? .revoked : .active
            case .ownerRevoke:
                consent.ownerScopes.removeAll { mutation.scopes.contains($0) }
                consent.approverScopes.removeAll { mutation.scopes.contains($0) }
                consent.ownerState = consent.ownerScopes.isEmpty ? .revoked : .active
                consent.approverState = consent.approverScopes.isEmpty ? .pending : .active
            case .approverRevoke:
                consent.approverScopes.removeAll { mutation.scopes.contains($0) }
                consent.approverState = consent.approverScopes.isEmpty ? .revoked : .active
            }
            try consent.advanceGeneration()
            consent.updatedAt = now
            try consent.validate()
            ledger.usedConsentNonces.insert(nonceKey)
            ledger.relationshipConsents[mutation.relationshipID] = consent
            invalidate(pairingID: pairingRecord.pairing.pairingID, now: now, ledger: &ledger)
            return .consent(consent)

        case "session":
            let session = try decode(ActiveSession.self, envelope.payload)
            guard signer == owner, session.owner == owner,
                  session.startsAt <= now.addingTimeInterval(60), session.endsAt > now else {
                throw CompanionError.invalidTransition
            }
            try session.validate()
            ledger.sessions[session.sessionID] = DurableSessionRecord(session: session, publishedAt: now)
            ledger.currentSessionID = session.sessionID
            for key in ledger.requests.keys {
                if ledger.requests[key]?.request.sessionID != session.sessionID ||
                    ledger.requests[key]?.request.activeSetID != session.activeSetID {
                    expire(requestID: key, now: now, ledger: &ledger)
                }
            }
            return .session(session)

        case "request":
            let request = try decode(TrustedRequest.self, envelope.payload)
            guard signer == owner, request.owner == owner,
                  request.status == .pending,
                  ledger.currentSessionID == request.sessionID,
                  let session = ledger.sessions[request.sessionID]?.session,
                  session.activeSetID == request.activeSetID,
                  session.isActive(at: now), request.createdAt <= now.addingTimeInterval(60),
                  now < request.expiresAt else {
                throw CompanionError.expired
            }
            try request.validateShape()
            try validateRequest(request, session: session, owner: owner, ledger: ledger)
            guard ledger.requests[request.requestID] == nil else { throw CompanionError.replay }
            ledger.requests[request.requestID] = DurableRequestRecord(request: request)
            return .request(request)

        case "approval":
            let approval = try decode(Approval.self, envelope.payload)
            guard signer == approval.approver, approval.approver.role == .trustedApprover else {
                throw CompanionError.unauthorized
            }
            try approval.validateSignature()
            try expireIfDue(requestID: approval.requestID, now: now, ledger: &ledger)
            guard approval.consentGeneration > 0, approval.nonce.count >= 16,
                  ledger.approvals[approval.approvalID] == nil,
                  !ledger.usedApprovalIDs.contains(approval.approvalID),
                  !ledger.usedApprovalNonces.contains(durableBase64URL(approval.nonce)),
                  let record = ledger.requests[approval.requestID],
                  record.request.status == .pending,
                  let session = ledger.sessions[approval.sessionID]?.session,
                  ledger.currentSessionID == approval.sessionID,
                  session.activeSetID == approval.activeSetID,
                  session.isActive(at: now),
                  approval.issuedAt <= now.addingTimeInterval(60),
                  let binding = record.request.binding(for: approval.approver.identityID),
                  binding.pairingID == approval.pairingID,
                  binding.pairEpoch == approval.pairEpoch,
                  binding.consentGeneration == approval.consentGeneration,
                  let pairing = ledger.pairings[approval.pairingID]?.pairing,
                  pairing.owner == owner, pairing.approver == approval.approver,
                  pairing.epoch == approval.pairEpoch, pairing.state == .active,
                  let consent = ledger.relationshipConsents[approval.pairingID],
                  consent.generation == approval.consentGeneration,
                  consent.authorizes(.approveEarlyEnd), consent.authorizes(.receiveRequests),
                  record.request.decisions[approval.approver.identityID] == .pending else {
                throw CompanionError.wrongTarget
            }
            ledger.approvals[approval.approvalID] = DurableApprovalRecord(approval: approval, acceptedAt: now)
            ledger.usedApprovalNonces.insert(durableBase64URL(approval.nonce))
            var current = record.request
            current.decisions[approval.approver.identityID] = approval.decision
            if approval.decision == .approved {
                current.status = .approved
            } else if current.decisions.values.allSatisfy({ $0 == .declined }) {
                current.status = .declined
            }
            ledger.requests[approval.requestID]?.request = current
            return .approval(approval)

        case "use":
            let use = try decode(ApprovalUse.self, envelope.payload)
            guard isValidIdentifier(use.useID) else { throw CompanionError.malformed("invalid use ID") }
            guard signer == owner,
                  let requestRecord = ledger.requests[use.requestID], requestRecord.request.owner == owner else {
                throw CompanionError.unauthorized
            }
            try expireIfDue(requestID: use.requestID, now: now, ledger: &ledger)
            guard let accepted = ledger.approvals[use.approval.approvalID]?.approval,
                  accepted == use.approval,
                  use.requestID == accepted.requestID,
                  use.consentGeneration > 0,
                  use.consentGeneration == accepted.consentGeneration,
                  ledger.approvalUses[use.useID] == nil,
                  !ledger.usedApprovalIDs.contains(use.useID),
                  !ledger.usedApprovalIDs.contains(accepted.approvalID),
                  requestRecord.request.status == .approved,
                  ledger.currentSessionID == requestRecord.request.sessionID,
                  let session = ledger.sessions[requestRecord.request.sessionID]?.session,
                  session.activeSetID == requestRecord.request.activeSetID,
                  session.isActive(at: now),
                  accepted.requestID == requestRecord.request.requestID,
                  accepted.sessionID == requestRecord.request.sessionID,
                  accepted.activeSetID == requestRecord.request.activeSetID,
                  requestRecord.request.decisions[accepted.approver.identityID] == .approved,
                  let binding = requestRecord.request.binding(for: accepted.approver.identityID),
                  binding.pairingID == accepted.pairingID,
                  binding.pairEpoch == accepted.pairEpoch,
                  binding.consentGeneration == accepted.consentGeneration,
                  let pairing = ledger.pairings[accepted.pairingID]?.pairing,
                  pairing.owner == owner, pairing.approver == accepted.approver,
                  pairing.epoch == accepted.pairEpoch, pairing.state == .active,
                  let consent = ledger.relationshipConsents[accepted.pairingID],
                  consent.generation == accepted.consentGeneration,
                  consent.authorizes(.approveEarlyEnd), consent.authorizes(.receiveRequests) else {
                throw CompanionError.replay
            }
            try accepted.validateSignature()
            let committedRevision = try checkedIncrement(ledger.revision, name: "ledger revision")
            ledger.usedApprovalIDs.insert(accepted.approvalID)
            ledger.usedApprovalIDs.insert(use.useID)
            ledger.approvalUses[use.useID] = DurableApprovalUseRecord(
                useID: use.useID, approvalID: accepted.approvalID, requestID: use.requestID,
                usedAt: now, committedRevision: committedRevision)
            return .verification(ApprovalVerification(approval: accepted, verifiedAt: now, useID: use.useID))

        case "cancel":
            let reference = try decode(RequestReference.self, envelope.payload)
            guard signer == owner, var record = ledger.requests[reference.requestID], record.request.owner == owner else {
                throw CompanionError.unauthorized
            }
            try expireIfDue(requestID: reference.requestID, now: now, ledger: &ledger)
            guard let freshRecord = ledger.requests[reference.requestID] else {
                throw CompanionError.notFound
            }
            record = freshRecord
            guard record.request.status == .pending || record.request.status == .approved else {
                throw CompanionError.invalidTransition
            }
            let consumed = ledger.approvalUses.values.contains { $0.requestID == reference.requestID }
            guard !consumed else { throw CompanionError.invalidTransition }
            record.request.status = .cancelled; record.cancelledAt = now
            ledger.requests[reference.requestID] = record
            return .acknowledgement

        case "natural_end":
            let reference: DurableNaturalEnd
            if let decoded = try? JSONDecoder().decode(DurableNaturalEnd.self, from: envelope.payload) {
                reference = decoded
            } else {
                let session = try decode(ActiveSession.self, envelope.payload)
                reference = DurableNaturalEnd(sessionID: session.sessionID, activeSetID: session.activeSetID)
            }
            guard signer == owner, ledger.currentSessionID == reference.sessionID,
                  let session = ledger.sessions[reference.sessionID]?.session,
                  session.owner == owner, session.activeSetID == reference.activeSetID,
                  now >= session.endsAt else { throw CompanionError.invalidTransition }
            for key in ledger.requests.keys { expire(requestID: key, now: now, ledger: &ledger) }
            return .acknowledgement

        case "revoke":
            let reference = try decode(PairingReference.self, envelope.payload)
            guard signer == owner, var record = ledger.pairings[reference.pairingID],
                  record.pairing.owner == owner, record.pairing.epoch == reference.epoch,
                  record.pairing.state == .active else { throw CompanionError.revokedPairing }
            record.pairing.state = .revoked; record.revokedAt = now
            ledger.pairings[reference.pairingID] = record
            try revokeConsent(pairingID: reference.pairingID, now: now, ledger: &ledger)
            invalidate(pairingID: reference.pairingID, now: now, ledger: &ledger)
            return .acknowledgement

        case "replace_pairing":
            let proposal = try decode(PairingReplacement.self, envelope.payload)
            guard signer == owner, proposal.owner == owner,
                  let previous = ledger.pairings[proposal.previousPairingID]?.pairing,
                  previous.owner == owner, previous.state == .active,
                  previous.epoch < UInt64.max else { throw CompanionError.revokedPairing }
            try proposal.validateSignature()
            let replacement = try PairingReplacement(
                replacementID: proposal.replacementID, previousPairing: previous,
                replacementPairingID: proposal.replacementPairingID,
                replacement: proposal.replacement, replacementEpoch: proposal.replacementEpoch,
                issuedAt: proposal.issuedAt, signature: proposal.signature)
            guard ledger.pairings[replacement.replacementPairingID] == nil else { throw CompanionError.replay }
            var revoked = previous; revoked.state = .revoked
            ledger.pairings[previous.pairingID] = DurablePairingRecord(pairing: revoked, revokedAt: now)
            try revokeConsent(pairingID: previous.pairingID, now: now, ledger: &ledger)
            invalidate(pairingID: previous.pairingID, now: now, ledger: &ledger)
            let activated = try Pairing(pairingID: replacement.replacementPairingID, owner: owner,
                                        approver: replacement.replacement,
                                        epoch: replacement.replacementEpoch,
                                        createdAt: now, state: .active,
                                        ownerDisplayName: previous.ownerDisplayName,
                                        approverDisplayName: previous.approverDisplayName)
            ledger.pairings[activated.pairingID] = DurablePairingRecord(pairing: activated)
            ledger.pairingEpochs[activated.pairingID] = activated.epoch
            return .pairing(activated)

        default:
            throw DurableRelayError.unsupportedOperation(kind)
        }
    }

    private static func validateRequest(_ request: TrustedRequest, session: ActiveSession,
                                        owner: DeviceIdentity,
                                        ledger: DurableOwnerLedger) throws {
        guard request.expiresAt <= session.endsAt,
              request.targetBindings.count == request.targetedApproverIDs.count,
              let primary = ledger.pairings[request.pairingID]?.pairing,
              primary.owner == owner, primary.state == .active,
              primary.approver.identityID == request.targetedApproverIDs[0],
              primary.epoch == request.pairEpoch else { throw CompanionError.revokedPairing }
        for binding in request.targetBindings {
            guard binding.consentGeneration > 0,
                  let pairing = ledger.pairings[binding.pairingID]?.pairing,
                  pairing.owner == owner, pairing.state == .active,
                  pairing.approver.identityID == binding.approverIdentityID,
                  pairing.epoch == binding.pairEpoch,
                  let consent = ledger.relationshipConsents[binding.pairingID],
                  consent.pairEpoch == binding.pairEpoch,
                  consent.generation == binding.consentGeneration,
                  consent.authorizes(.receiveRequests),
                  consent.authorizes(.approveEarlyEnd) else { throw CompanionError.consentRequired }
        }
    }

    private static func expire(requestID: String, now: Date,
                               ledger: inout DurableOwnerLedger) {
        guard var record = ledger.requests[requestID], record.request.status != .cancelled,
              record.request.status != .declined, record.request.status != .expired else { return }
        record.request.status = .expired
        record.expiredAt = now
        ledger.requests[requestID] = record
    }

    /// Checks the request's own frozen expiry and its session end before every
    /// approval/use/cancellation transition. The caller's transaction commits
    /// this terminal state together with the rejected operation receipt.
    private static func expireIfDue(requestID: String, now: Date,
                                    ledger: inout DurableOwnerLedger) throws {
        guard let record = ledger.requests[requestID],
              record.request.status != .cancelled,
              record.request.status != .declined,
              record.request.status != .expired else { return }
        let sessionEnded = ledger.sessions[record.request.sessionID].map { $0.session.endsAt <= now } ?? false
        guard now >= record.request.expiresAt || sessionEnded else { return }
        expire(requestID: requestID, now: now, ledger: &ledger)
        throw DurableProtocolTransitionError.requestExpired
    }

    private static func invalidate(pairingID: String, now: Date,
                                   ledger: inout DurableOwnerLedger) {
        for key in ledger.requests.keys where ledger.requests[key]?.request.targetBindings.contains(where: { $0.pairingID == pairingID }) == true {
            expire(requestID: key, now: now, ledger: &ledger)
        }
    }

    private static func revokeConsent(pairingID: String, now: Date,
                                      ledger: inout DurableOwnerLedger) throws {
        guard var consent = ledger.relationshipConsents[pairingID], consent.generation < UInt64.max else { return }
        consent.ownerScopes = []; consent.approverScopes = []
        consent.ownerState = .revoked; consent.approverState = .revoked
        try consent.advanceGeneration()
        consent.updatedAt = now
        ledger.relationshipConsents[pairingID] = consent
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CompanionError.malformed("invalid operation body") }
    }

    private static func verify(_ signature: Data, domain: String, fields: [String], key: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature,
                                          for: CompanionCanonical.bytes(domain: domain, fields: fields))
    }
}
