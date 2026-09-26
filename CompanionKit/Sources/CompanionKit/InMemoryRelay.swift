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
    private var sessionHistory: [String: ActiveSession] = [:]
    private var requests: [String: TrustedRequest] = [:]
    private var approvals: [String: Approval] = [:]
    private var usedApprovalIDs = Set<String>()
    private var usedApprovalNonces = Set<String>()
    private var usedConsentNonces = Set<String>()
    private var relationshipConsents: [String: RelationshipConsent] = [:]
    private var operationRecords: [String: RelayOperationRecord] = [:]
    private var revision: UInt64 = 0
    private var operationTimes: [String: [Date]] = [:]
    public private(set) var currentTime: Date

    public var currentRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    // Internal seam for the bounded exhaustion regression; not part of the
    // public transport API.
    func setRevisionForTesting(_ value: UInt64) {
        lock.lock(); defer { lock.unlock() }
        revision = value
    }

    public init(owner: DeviceIdentity, now: Date = Date()) throws {
        guard owner.role == .owner else { throw CompanionError.unauthorized }
        try owner.validate(); try requireTimestamp(now, name: "relay time")
        self.owner = owner; self.currentTime = now
    }

    /// Test-only restore without an external monotonic anchor. This cannot
    /// establish rollback protection and is intentionally inaccessible to
    /// production callers; use the anchored overload for persistence tests.
    convenience init(testSnapshot data: Data) throws {
        let snapshot: RelaySnapshot
        do { snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: data) }
        catch { throw CompanionError.malformed("invalid relay snapshot") }
        // Validate the complete graph before installing any decoded value.
        // This keeps restore fail-closed and prevents a partially trusted
        // snapshot from becoming relay state.
        try Self.validateSnapshot(snapshot, requireRetainedRequestBinding: false)
        try self.init(owner: snapshot.owner, now: snapshot.currentTime)
        self.invitations = Dictionary(uniqueKeysWithValues: snapshot.invitations.map { ($0.payload.inviteID, $0) })
        self.usedInviteIDs = snapshot.usedInviteIDs
        self.pendingAcceptances = Dictionary(uniqueKeysWithValues: snapshot.pendingAcceptances.map { ($0.acceptanceID, $0) })
        self.pairings = Dictionary(uniqueKeysWithValues: snapshot.pairings.map { ($0.pairingID, $0) })
        self.sessionHistory = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0) })
        if let currentSessionID = snapshot.currentSessionID,
           let currentSession = sessionHistory[currentSessionID] {
            self.sessions = [currentSession.owner.identityID: currentSession]
        }
        self.requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        self.approvals = Dictionary(uniqueKeysWithValues: snapshot.approvals.map { ($0.approvalID, $0) })
        self.usedApprovalIDs = snapshot.usedApprovalIDs
        self.usedApprovalNonces = snapshot.usedApprovalNonces
        self.usedConsentNonces = snapshot.usedConsentNonces
        self.relationshipConsents = Dictionary(uniqueKeysWithValues: snapshot.relationshipConsents.map { ($0.relationshipID, $0) })
        self.operationRecords = Dictionary(uniqueKeysWithValues: snapshot.operationRecords.map { ($0.operationID, $0) })
        self.revision = snapshot.revision
    }

    /// Restores only with a checkpoint retained outside the mutable snapshot.
    /// The checkpoint binds both the exact revision and the complete canonical
    /// state root; a revision number alone does not authenticate state.
    public convenience init(snapshot data: Data, checkpoint: CompanionCheckpoint) throws {
        let snapshot: RelaySnapshot
        do { snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: data) }
        catch { throw CompanionError.malformed("invalid relay snapshot") }
        try checkpoint.validate()
        guard snapshot.owner.identityID == checkpoint.ownerIdentityID,
              snapshot.revision == checkpoint.revision else {
            throw CompanionError.staleRevision(expected: checkpoint.revision, actual: snapshot.revision)
        }
        try Self.validateSnapshot(snapshot, requireRetainedRequestBinding: true)
        guard try snapshot.canonicalStateRoot() == checkpoint.stateRoot else {
            throw CompanionError.malformed("relay checkpoint root mismatch")
        }
        try self.init(testSnapshot: data)
    }

    /// The caller must retain this checkpoint independently and rotate it only
    /// after the corresponding committed transaction has completed.
    public func checkpoint() throws -> CompanionCheckpoint {
        lock.lock(); defer { lock.unlock() }
        let snapshot = try makeSnapshot()
        return try CompanionCheckpoint(ownerIdentityID: owner.identityID,
                                       revision: revision,
                                       stateRoot: snapshot.canonicalStateRoot())
    }

    private static func validateSnapshot(_ snapshot: RelaySnapshot,
                                         requireRetainedRequestBinding: Bool = false) throws {
        guard snapshot.revision <= UInt64(CompanionLimits.maxSnapshotRecords),
              snapshot.invitations.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.pendingAcceptances.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.pairings.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.sessions.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.requests.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.approvals.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedInviteIDs.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedApprovalIDs.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedApprovalNonces.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.usedConsentNonces.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.relationshipConsents.count <= CompanionLimits.maxSnapshotRecords,
              snapshot.operationRecords.count <= CompanionLimits.maxSnapshotRecords else {
            throw CompanionError.malformed("relay snapshot too large")
        }
        guard snapshot.schemaVersion == RelaySnapshot.currentSchemaVersion else {
            throw CompanionError.malformed("unsupported relay snapshot schema")
        }
        guard snapshot.owner.role == .owner else { throw CompanionError.unauthorized }
        try snapshot.owner.validate(); try requireTimestamp(snapshot.currentTime, name: "snapshot time")
        var recordIDs = Set<String>()
        var recordRevisions = Set<UInt64>()
        for record in snapshot.operationRecords {
            try record.validate()
            let signed = try decodeSignedOperation(record.signedOperation)
            guard record.revision <= snapshot.revision,
                  signed.operationID == record.operationID,
                  signed.kind == record.kind,
                  signed.signer.identityID == record.signerIdentityID,
                  signed.expectedRevision == record.expectedRevision,
                  record.bodyDigest == CompanionCanonical.digest(signed.body),
                  recordIDs.insert(record.operationID).inserted,
                  recordRevisions.insert(record.revision).inserted else {
                throw CompanionError.malformed("invalid operation record")
            }
            try signed.validateSignature()
        }
        if requireRetainedRequestBinding {
            for request in snapshot.requests {
                let records = snapshot.operationRecords.filter { record in
                    guard record.kind == "request",
                          let signed = try? decodeSignedOperation(record.signedOperation),
                          signed.signer == snapshot.owner,
                          let initial = try? JSONDecoder().decode(TrustedRequest.self, from: signed.body) else { return false }
                    return initial.requestID == request.requestID
                }
                guard records.count == 1,
                      let record = records.first,
                      let signed = try? decodeSignedOperation(record.signedOperation),
                      let initial = try? JSONDecoder().decode(TrustedRequest.self, from: signed.body),
                      requestImmutableFieldsMatch(request, initial),
                      initial.status == .pending,
                      initial.decisions.values.allSatisfy({ $0 == .pending }) else {
                    throw CompanionError.malformed("request is not bound to retained operation")
                }
            }
        }
        let expectedRecordRevisions: Set<UInt64> = snapshot.revision == 0
            ? []
            : Set((1...Int(snapshot.revision)).map(UInt64.init))
        guard UInt64(recordRevisions.count) == snapshot.revision,
              recordRevisions == expectedRecordRevisions else {
            throw CompanionError.malformed("incomplete operation records")
        }

        var invitations: [String: Invitation] = [:]
        for invitation in snapshot.invitations {
            try invitation.validateSignature()
            guard invitation.payload.owner == snapshot.owner,
                  invitations[invitation.payload.inviteID] == nil else { throw CompanionError.malformed("invalid invitation ownership") }
            invitations[invitation.payload.inviteID] = invitation
        }
        for inviteID in snapshot.usedInviteIDs {
            try requireIdentifier(inviteID, name: "used invite ID")
            guard invitations[inviteID] != nil else { throw CompanionError.malformed("unknown used invite") }
        }

        var acceptances: [String: PairingAcceptance] = [:]
        for acceptance in snapshot.pendingAcceptances {
            try acceptance.validate()
            guard acceptance.owner == snapshot.owner,
                  !snapshot.usedInviteIDs.contains(acceptance.inviteID),
                  let invitation = invitations[acceptance.inviteID], invitation.payload.owner == snapshot.owner,
                  acceptance.issuedAt >= invitation.payload.issuedAt.addingTimeInterval(-60),
                  acceptance.issuedAt < invitation.payload.expiresAt,
                  acceptance.verificationCode == PairingAcceptance.code(invite: invitation.payload, approver: acceptance.approver),
                  acceptances[acceptance.acceptanceID] == nil else {
                throw CompanionError.malformed("invalid pending acceptance graph")
            }
            acceptances[acceptance.acceptanceID] = acceptance
        }

        var pairings: [String: Pairing] = [:]
        for pairing in snapshot.pairings {
            try pairing.validate()
            guard pairing.owner == snapshot.owner, pairings[pairing.pairingID] == nil else {
                throw CompanionError.malformed("invalid pairing ownership")
            }
            pairings[pairing.pairingID] = pairing
        }

        var sessions: [String: ActiveSession] = [:]
        for session in snapshot.sessions {
            try session.validate()
            guard session.owner == snapshot.owner, sessions[session.sessionID] == nil else {
                throw CompanionError.malformed("invalid session ownership")
            }
            sessions[session.sessionID] = session
        }
        if let currentSessionID = snapshot.currentSessionID {
            try requireIdentifier(currentSessionID, name: "current session ID")
            guard sessions[currentSessionID] != nil else {
                throw CompanionError.malformed("unknown current session")
            }
        } else if !sessions.isEmpty {
            throw CompanionError.malformed("missing current session")
        }

        var requests: [String: TrustedRequest] = [:]
        for request in snapshot.requests {
            try request.validatePersisted()
            guard request.owner == snapshot.owner,
                  let session = sessions[request.sessionID],
                  session.activeSetID == request.activeSetID,
                  requests[request.requestID] == nil else {
                throw CompanionError.malformed("invalid request graph")
            }
            if request.sessionID != snapshot.currentSessionID {
                guard request.status == .expired || request.status == .cancelled || request.status == .declined else {
                    throw CompanionError.malformed("historical request is not terminal")
                }
            }
            guard request.targetBindings.allSatisfy({ binding in
                guard let pairing = pairings[binding.pairingID] else { return false }
                return pairing.owner == snapshot.owner && pairing.approver.identityID == binding.approverIdentityID && pairing.epoch == binding.pairEpoch
            }) else { throw CompanionError.malformed("request pairing mismatch") }
            requests[request.requestID] = request
        }

        var approvals: [String: Approval] = [:]
        var approvalTargets: [String: Set<String>] = [:]
        var approvalNonces = Set<String>()
        for approval in snapshot.approvals {
            try approval.validateSignature()
            let targetWasUnique = approvalTargets[approval.requestID, default: []].insert(approval.approver.identityID).inserted
            let nonceWasUnique = approval.nonce.isEmpty || approvalNonces.insert(base64URL(approval.nonce)).inserted
            guard approvals[approval.approvalID] == nil,
                  let request = requests[approval.requestID], request.owner == snapshot.owner,
                  request.sessionID == approval.sessionID, request.activeSetID == approval.activeSetID,
                  request.binding(for: approval.approver.identityID)?.pairingID == approval.pairingID,
                  request.binding(for: approval.approver.identityID)?.pairEpoch == approval.pairEpoch,
                  request.binding(for: approval.approver.identityID)?.consentGeneration == approval.consentGeneration,
                  let pairing = pairings[approval.pairingID], pairing.owner == snapshot.owner,
                  pairing.approver == approval.approver, pairing.epoch == approval.pairEpoch,
                  targetWasUnique, nonceWasUnique,
                  request.decisions[approval.approver.identityID] == approval.decision else {
                throw CompanionError.malformed("invalid approval graph")
            }
            approvals[approval.approvalID] = approval
        }
        for approvalID in snapshot.usedApprovalIDs { try requireIdentifier(approvalID, name: "used approval ID") }
        for nonce in snapshot.usedApprovalNonces {
            guard let data = dataFromBase64URL(nonce), data.count >= 16, data.count <= 64 else {
                throw CompanionError.malformed("invalid approval nonce marker")
            }
        }
        for nonce in snapshot.usedConsentNonces {
            guard let data = dataFromBase64URL(nonce), data.count >= 16, data.count <= 64 else {
                throw CompanionError.malformed("invalid consent nonce marker")
            }
        }
        guard snapshot.usedApprovalNonces.isSuperset(of: approvalNonces.filter { !$0.isEmpty }) else {
            throw CompanionError.malformed("missing approval nonce marker")
        }

        var consents: [String: RelationshipConsent] = [:]
        for consent in snapshot.relationshipConsents {
            try consent.validate()
            guard consent.owner == snapshot.owner,
                  let pairing = pairings[consent.pairingID],
                  pairing.owner == snapshot.owner,
                  pairing.approver == consent.approver,
                  pairing.epoch == consent.pairEpoch,
                  consent.relationshipID == consent.pairingID,
                  consents[consent.relationshipID] == nil else {
                throw CompanionError.malformed("invalid relationship consent graph")
            }
            consents[consent.relationshipID] = consent
        }

        // Decisions are durable relay outcomes. Do not restore an approved or
        // declined decision without the corresponding accepted signed record.
        for request in requests.values {
            for target in request.targetedApproverIDs {
                let records = approvals.values.filter { $0.requestID == request.requestID && $0.approver.identityID == target }
                switch request.decisions[target] {
                case .pending: guard records.isEmpty else { throw CompanionError.malformed("pending decision has approval") }
                case .approved: guard records.count == 1, records[0].decision == .approved else { throw CompanionError.malformed("missing approval record") }
                case .declined: guard records.count == 1, records[0].decision == .declined else { throw CompanionError.malformed("missing decline record") }
                case nil: throw CompanionError.malformed("missing request decision")
                }
            }
        }
    }

    public func advance(to time: Date) throws {
        try requireTimestamp(time, name: "relay time")
        lock.lock(); defer { lock.unlock() }
        guard time >= currentTime else { throw CompanionError.malformed("relay clock cannot go backwards") }
        currentTime = time
    }

    public func snapshot() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(makeSnapshot())
    }

    private func makeSnapshot() throws -> RelaySnapshot {
        RelaySnapshot(owner: owner, currentTime: currentTime, revision: revision,
                      currentSessionID: sessions[owner.identityID]?.sessionID,
                      invitations: invitations.values.sorted { $0.payload.inviteID < $1.payload.inviteID },
                      usedInviteIDs: usedInviteIDs,
                      pendingAcceptances: pendingAcceptances.values.sorted { $0.acceptanceID < $1.acceptanceID },
                      pairings: pairings.values.sorted { $0.pairingID < $1.pairingID },
                      sessions: sessionHistory.values.sorted { $0.sessionID < $1.sessionID },
                      requests: requests.values.sorted { $0.requestID < $1.requestID },
                      approvals: approvals.values.sorted { $0.approvalID < $1.approvalID },
                      usedApprovalIDs: usedApprovalIDs,
                      usedApprovalNonces: usedApprovalNonces,
                      usedConsentNonces: usedConsentNonces,
                      relationshipConsents: relationshipConsents.values.sorted { $0.relationshipID < $1.relationshipID },
                      operationRecords: operationRecords.values.sorted { $0.operationID < $1.operationID })
    }

    public func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
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
        return try InboxResponse(ownerIdentityID: query.identityID, revision: revision,
                                 requests: values.sorted { $0.createdAt < $1.createdAt })
    }

    public func consent(relationshipID: String) throws -> RelationshipConsent {
        lock.lock(); defer { lock.unlock() }
        guard let consent = relationshipConsents[relationshipID] else { throw CompanionError.notFound }
        return consent
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

    public func submit(_ operation: SignedOperation) throws -> RelayResponse {
        lock.lock(); defer { lock.unlock() }
        try operation.validateSignature()
        let digest = CompanionCanonical.digest(operation.body)
        if let record = operationRecords[operation.operationID] {
            guard record.signerIdentityID == operation.signer.identityID,
                  record.kind == operation.kind,
                  record.bodyDigest == digest,
                  record.expectedRevision == operation.expectedRevision else {
                throw CompanionError.operationConflict
            }
            return try RelayResponse(operationID: operation.operationID,
                                     revision: record.revision, result: record.response)
        }
        if let expectedRevision = operation.expectedRevision, expectedRevision != revision {
            throw CompanionError.staleRevision(expected: expectedRevision, actual: revision)
        }
        guard revision < UInt64.max else { throw CompanionError.malformed("revision exhausted") }
        try charge(operation.signer.identityID)
        let result = try apply(operation)
        revision = try checkedIncrement(revision, name: "relay revision")
        let record = try RelayOperationRecord(operationID: operation.operationID,
                                              signerIdentityID: operation.signer.identityID,
                                              kind: operation.kind, bodyDigest: digest,
                                              revision: revision, response: result,
                                              expectedRevision: operation.expectedRevision,
                                              signedOperation: try CompanionCanonical.encoded(operation))
        operationRecords[operation.operationID] = record
        return try RelayResponse(operationID: operation.operationID, revision: revision, result: result)
    }

    private func apply(_ operation: SignedOperation) throws -> RelayResult {
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
            // The invite is a one-use capability at confirmation time, not at
            // acceptance time. Check and consume it while holding the relay
            // lock, and invalidate every competing pending acceptance below.
            guard !usedInviteIDs.contains(signed.confirmation.inviteID) else { throw CompanionError.replay }
            guard let acceptance = pendingAcceptances[signed.confirmation.acceptanceID],
                  acceptance.inviteID == signed.confirmation.inviteID,
                  acceptance.approver.identityID == signed.confirmation.approverIdentityID,
                  let invitation = invitations[acceptance.inviteID], currentTime < invitation.payload.expiresAt,
                  signed.confirmation.issuedAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.expired }
            guard verify(signed.signature, domain: "\(CompanionCanonical.version).confirmation", fields: signed.confirmation.signingFields(), key: owner.publicKey) else { throw CompanionError.invalidSignature }
            guard acceptance.verificationCode == signed.confirmation.verificationCode,
                  PairingAcceptance.code(invite: invitation.payload, approver: acceptance.approver) == signed.confirmation.verificationCode else { throw CompanionError.wrongVerificationCode }
            usedInviteIDs.insert(acceptance.inviteID)
            // Other receivers may have accepted the same link before the
            // owner confirmation arrived. None may be confirmed later.
            pendingAcceptances = pendingAcceptances.filter { $0.value.inviteID != acceptance.inviteID }
            let pairingID = base64URL(Data(SHA256.hash(data: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).pairing", fields: [acceptance.inviteID, acceptance.approver.identityID])))).prefix(32).description
            let pairing = try Pairing(pairingID: pairingID, owner: owner, approver: acceptance.approver, epoch: 1, createdAt: currentTime, state: .active)
            pairings[pairingID] = pairing
            return .pairing(pairing)

        case "consent":
            let mutation = try decode(RelationshipConsentMutation.self, operation.body)
            guard mutation.owner == owner,
                  let pairing = pairings[mutation.pairingID], pairing.owner == owner,
                  pairing.approver == mutation.approver,
                  pairing.epoch == mutation.pairEpoch, pairing.state == .active,
                  mutation.relationshipID == mutation.pairingID,
                  mutation.issuedAt <= currentTime.addingTimeInterval(60) else {
                throw CompanionError.wrongTarget
            }
            guard mutation.scopes.scopes.allSatisfy(\.isR5) else { throw CompanionError.unsupportedScope }
            let signerIsOwner = operation.signer == owner
            let signerIsApprover = operation.signer == pairing.approver
            guard (mutation.action == .ownerGrant || mutation.action == .ownerRevoke) ? signerIsOwner : signerIsApprover else {
                throw CompanionError.unauthorized
            }
            let nonceKey = base64URL(mutation.nonce)
            guard !usedConsentNonces.contains(nonceKey) else { throw CompanionError.replay }
            var consent: RelationshipConsent
            if let existing = relationshipConsents[mutation.relationshipID] {
                consent = existing
            } else {
                consent = try RelationshipConsent(relationshipID: mutation.relationshipID, pairingID: pairing.pairingID,
                                                  pairEpoch: pairing.epoch, owner: owner, approver: pairing.approver,
                                                  ownerState: .revoked, approverState: .revoked,
                                                  updatedAt: currentTime, generation: 0)
            }
            guard consent.generation < UInt64.max else { throw CompanionError.malformed("consent generation exhausted") }
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
            consent.updatedAt = currentTime
            try consent.advanceGeneration()
            try consent.validate()
            usedConsentNonces.insert(nonceKey)
            relationshipConsents[mutation.relationshipID] = consent
            // The generation change and terminal invalidation are one relay
            // transaction. A lost acknowledgement or later regrant cannot
            // revive an accepted request from the prior generation.
            invalidateOutstandingAuthority(pairingID: pairing.pairingID)
            return .consent(consent)

        case "session":
            let session = try decode(ActiveSession.self, operation.body)
            guard operation.signer == owner, session.owner == owner, session.startsAt <= currentTime.addingTimeInterval(60),
                  session.endsAt > currentTime else { throw CompanionError.invalidTransition }
            try session.validate()
            // Replacing the active set makes every old request stale, even when
            // the new session happens to use the same human-readable policy.
            sessions[owner.identityID] = session
            sessionHistory[session.sessionID] = session
            expireRequests(supersededBy: session)
            return .session(session)

        case "request":
            let request = try decode(TrustedRequest.self, operation.body)
            guard operation.signer == owner, request.owner == owner,
                  let session = sessions[owner.identityID], session.sessionID == request.sessionID,
                  session.activeSetID == request.activeSetID, session.isActive(at: currentTime),
                  request.createdAt <= currentTime.addingTimeInterval(60),
                  currentTime < request.expiresAt else { throw CompanionError.expired }
            try request.validateShape()
            try validateRequestPairing(request, session: session)
            for binding in request.targetBindings {
                try requireActiveScope(.receiveRequests, for: binding)
                try requireActiveScope(.approveEarlyEnd, for: binding)
            }
            guard requests[request.requestID] == nil else { throw CompanionError.replay }
            requests[request.requestID] = request
            return .request(request)

        case "approval":
            let approval = try decode(Approval.self, operation.body)
            guard operation.signer == approval.approver else { throw CompanionError.unauthorized }
            try approval.validateSignature()
            guard approvals[approval.approvalID] == nil,
                  !usedApprovalIDs.contains(approval.approvalID),
                  approval.nonce.count >= 16, approval.nonce.count <= 64,
                  !usedApprovalNonces.contains(base64URL(approval.nonce)) else { throw CompanionError.replay }
            guard let request = requests[approval.requestID] else { throw CompanionError.notFound }
            var currentRequest = request; updateExpiry(&currentRequest)
            requests[request.requestID] = currentRequest
            guard currentRequest.effectiveStatus(at: currentTime) == .pending else {
                if currentRequest.status == .expired { throw CompanionError.expired }
                throw CompanionError.wrongTarget
            }
            guard currentRequest.sessionID == approval.sessionID, currentRequest.activeSetID == approval.activeSetID,
                  let target = currentRequest.binding(for: approval.approver.identityID),
                  target.pairingID == approval.pairingID,
                  target.pairEpoch == approval.pairEpoch,
                  target.consentGeneration == approval.consentGeneration,
                  let pairing = pairings[approval.pairingID], pairing.owner == owner,
                  pairing.approver == approval.approver, pairing.epoch == approval.pairEpoch,
                  pairing.state == .active,
                  relationshipConsents[approval.pairingID]?.generation == approval.consentGeneration else { throw CompanionError.wrongTarget }
            guard request.purpose == .approveEarlyEnd,
                  relationshipConsents[approval.pairingID]?.authorizes(.receiveRequests) == true,
                  relationshipConsents[approval.pairingID]?.authorizes(.approveEarlyEnd) == true else {
                throw CompanionError.consentRequired
            }
            guard approval.issuedAt <= currentTime.addingTimeInterval(60) else { throw CompanionError.expired }
            guard currentRequest.decisions[approval.approver.identityID] == .pending else { throw CompanionError.replay }
            approvals[approval.approvalID] = approval
            usedApprovalNonces.insert(base64URL(approval.nonce))
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
            guard let livePairing = pairings[acceptedApproval.pairingID], livePairing.owner == owner,
                  livePairing.state == .active, livePairing.epoch == acceptedApproval.pairEpoch else {
                throw CompanionError.revokedPairing
            }
            var currentRequest = request; updateExpiry(&currentRequest)
            requests[request.requestID] = currentRequest
            let currentSession = sessions[owner.identityID]
            if currentRequest.status == .expired { throw CompanionError.expired }
            guard currentRequest.effectiveStatus(at: currentTime) == .approved,
                  currentSession?.isActive(at: currentTime) == true,
                  currentRequest.sessionID == currentSession?.sessionID,
                  currentRequest.activeSetID == currentSession?.activeSetID,
                  acceptedApproval.requestID == currentRequest.requestID,
                  acceptedApproval.sessionID == currentRequest.sessionID,
                  acceptedApproval.activeSetID == currentRequest.activeSetID,
                  currentRequest.binding(for: acceptedApproval.approver.identityID)?.pairingID == acceptedApproval.pairingID,
                  currentRequest.binding(for: acceptedApproval.approver.identityID)?.pairEpoch == acceptedApproval.pairEpoch,
                  currentRequest.decisions[acceptedApproval.approver.identityID] == .approved,
                  !usedApprovalIDs.contains(acceptedApproval.approvalID),
                  !usedApprovalIDs.contains(use.useID),
                  use.approval.requestID == use.requestID,
                  use.approval.decision == .approved else { throw CompanionError.replay }
            guard let pairing = pairings[acceptedApproval.pairingID], pairing.owner == owner,
                  pairing.state == .active, pairing.epoch == acceptedApproval.pairEpoch,
                  pairing.approver == acceptedApproval.approver,
                  relationshipConsents[acceptedApproval.pairingID]?.generation == acceptedApproval.consentGeneration,
                  relationshipConsents[acceptedApproval.pairingID]?.authorizes(.approveEarlyEnd) == true,
                  relationshipConsents[acceptedApproval.pairingID]?.authorizes(.receiveRequests) == true else {
                throw CompanionError.revokedPairing
            }
            try acceptedApproval.validateSignature()
            usedApprovalIDs.insert(acceptedApproval.approvalID); usedApprovalIDs.insert(use.useID)
            return .verification(ApprovalVerification(approval: acceptedApproval, verifiedAt: currentTime, useID: use.useID))

        case "cancel":
            let reference = try decode(RequestReference.self, operation.body)
            guard operation.signer == owner, var request = requests[reference.requestID], request.owner == owner else { throw CompanionError.unauthorized }
            updateExpiry(&request)
            requests[reference.requestID] = request
            guard request.effectiveStatus(at: currentTime) == .pending || request.effectiveStatus(at: currentTime) == .approved else {
                if request.status == .expired { throw CompanionError.expired }
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

        case "replace_pairing":
            let proposal = try decode(PairingReplacement.self, operation.body)
            guard operation.signer == owner, proposal.owner == owner,
                  let previous = pairings[proposal.previousPairingID],
                  previous.owner == owner, previous.state == .active,
                  previous.epoch < UInt64.max else { throw CompanionError.revokedPairing }
            let replacement = try PairingReplacement(
                replacementID: proposal.replacementID, previousPairing: previous,
                replacementPairingID: proposal.replacementPairingID,
                replacement: proposal.replacement, replacementEpoch: proposal.replacementEpoch,
                issuedAt: proposal.issuedAt, signature: proposal.signature)
            try replacement.validateSignature()
            guard pairings[replacement.replacementPairingID] == nil else { throw CompanionError.replay }
            var revoked = previous
            revoked.state = .revoked
            if var consent = relationshipConsents[previous.pairingID] {
                try consent.advanceGeneration()
                consent.ownerScopes = []; consent.approverScopes = []
                consent.ownerState = .revoked; consent.approverState = .revoked
                consent.updatedAt = currentTime
                try consent.validate()
                relationshipConsents[previous.pairingID] = consent
            }
            invalidateOutstandingAuthority(pairingID: previous.pairingID)
            let activated = try Pairing(pairingID: replacement.replacementPairingID, owner: owner,
                                    approver: replacement.replacement,
                                    epoch: replacement.replacementEpoch,
                                    createdAt: currentTime, state: .active)
            // Both writes are protected by the relay lock and happen before
            // the durable receipt is recorded and acknowledged.
            pairings[previous.pairingID] = revoked
            pairings[activated.pairingID] = activated
            return .pairing(activated)

        case "revoke":
            let reference = try decode(PairingReference.self, operation.body)
            guard operation.signer == owner, var pairing = pairings[reference.pairingID], pairing.owner == owner,
                  pairing.epoch == reference.epoch else { throw CompanionError.unauthorized }
            pairing.state = .revoked; pairings[reference.pairingID] = pairing
            if var consent = relationshipConsents[reference.pairingID] {
                try consent.advanceGeneration()
                consent.ownerScopes = []; consent.approverScopes = []
                consent.ownerState = .revoked; consent.approverState = .revoked
                consent.updatedAt = currentTime
                try consent.validate()
                relationshipConsents[reference.pairingID] = consent
            }
            invalidateOutstandingAuthority(pairingID: reference.pairingID)
            return .acknowledgement

        case "ack":
            guard operation.signer == owner, operation.body == Data("{}".utf8) else {
                throw CompanionError.malformed("ack must have an empty payload")
            }
            return .acknowledgement

        default:
            throw CompanionError.malformed("unknown operation")
        }
    }

    private func requireActiveScope(_ scope: CompanionScope, for binding: RequestTargetBinding) throws {
        guard scope.isR5, binding.consentGeneration > 0,
              let consent = relationshipConsents[binding.pairingID],
              consent.pairEpoch == binding.pairEpoch,
              consent.generation == binding.consentGeneration,
              consent.approver.identityID == binding.approverIdentityID else {
            throw CompanionError.consentRequired
        }
        guard consent.authorizes(scope) else { throw CompanionError.consentRequired }
    }

    private func validateRequestPairing(_ request: TrustedRequest, session: ActiveSession) throws {
        guard request.targetBindings.count == request.targetedApproverIDs.count,
              let primary = pairings[request.pairingID], primary.owner == owner,
              primary.approver.identityID == request.targetedApproverIDs.first,
              primary.state == .active, primary.epoch == request.pairEpoch else { throw CompanionError.revokedPairing }
        for binding in request.targetBindings {
            guard let pairing = pairings[binding.pairingID], pairing.owner == owner,
                  pairing.approver.identityID == binding.approverIdentityID,
                  pairing.epoch == binding.pairEpoch, pairing.state == .active,
                  relationshipConsents[binding.pairingID]?.generation == binding.consentGeneration else {
                throw CompanionError.wrongTarget
            }
        }
        guard request.expiresAt <= session.endsAt else { throw CompanionError.expired }
    }

    /// Terminally invalidates every request carrying authority for a pairing.
    /// Approval rows remain immutable audit artifacts, but no request or
    /// approval from the old generation can pass the use reducer.
    private func invalidateOutstandingAuthority(pairingID: String) {
        for key in requests.keys {
            var request = requests[key]!
            let targetsPairing = request.targetBindings.contains { $0.pairingID == pairingID }
            if targetsPairing && request.status != .cancelled && request.status != .declined && request.status != .expired {
                request.status = .expired
            }
            requests[key] = request
        }
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
        guard request.status != .cancelled && request.status != .declined,
              request.status != .expired else { return }
        let sessionEnded = sessionHistory[request.sessionID].map { currentTime >= $0.endsAt } ?? false
        if currentTime >= request.expiresAt || sessionEnded {
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

private func decodeSignedOperation(_ data: Data) throws -> SignedOperation {
    do { return try JSONDecoder().decode(SignedOperation.self, from: data) }
    catch { throw CompanionError.malformed("invalid retained signed operation") }
}

private func requestImmutableFieldsMatch(_ current: TrustedRequest, _ initial: TrustedRequest) -> Bool {
    current.requestID == initial.requestID && current.owner == initial.owner &&
    current.pairingID == initial.pairingID && current.pairEpoch == initial.pairEpoch &&
    current.consentGeneration == initial.consentGeneration && current.sessionID == initial.sessionID &&
    current.activeSetID == initial.activeSetID && current.purpose == initial.purpose &&
    current.targetedApproverIDs == initial.targetedApproverIDs &&
    current.targetBindings == initial.targetBindings && current.message == initial.message &&
    current.createdAt == initial.createdAt && current.expiresAt == initial.expiresAt
}
