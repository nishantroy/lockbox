import Foundation
import CryptoKit

/// Notification suppression is a private, local presentation choice. It does
/// not hide requests from the relay, alter expiry, or grant an approver power.
public struct QuietHoursPolicy: Codable, Hashable, Sendable {
    public let startMinute: Int
    public let endMinute: Int
    public let suppressApproverNotifications: Bool
    /// Deliberately no engagement score, usage score, or social ranking.
    public var score: Int? { nil }

    public init(startMinute: Int, endMinute: Int, suppressApproverNotifications: Bool) throws {
        guard (0..<1_440).contains(startMinute), (0..<1_440).contains(endMinute), startMinute != endMinute else {
            throw CompanionError.malformed("invalid quiet hours")
        }
        self.startMinute = startMinute; self.endMinute = endMinute
        self.suppressApproverNotifications = suppressApproverNotifications
    }

    public func suppressesNotifications(at date: Date, calendar: Calendar = .current) -> Bool {
        guard suppressApproverNotifications else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let value = hour * 60 + minute
        return startMinute < endMinute
            ? value >= startMinute && value < endMinute
            : value >= startMinute || value < endMinute
    }
}

/// Optional mutual pact. Each commitment is signed by, and contains only the
/// profile digest of, its own participant. Acceptance is a record of consent;
/// this type intentionally has no start/extend/enforcement operation.
public struct PactCommitment: Codable, Hashable, Sendable {
    public let pactID: String
    public let participant: DeviceIdentity
    public let periodStart: Date
    public let periodEnd: Date
    public let profileCommitment: Data
    public let signature: Data

    public init(pactID: String, participant: DeviceIdentity, periodStart: Date, periodEnd: Date,
                profileCommitment: Data, signature: Data) throws {
        try requireIdentifier(pactID, name: "pact ID")
        guard periodEnd > periodStart, periodEnd.timeIntervalSince(periodStart) <= CompanionLimits.maxSessionLifetime,
              profileCommitment.count == 32, signature.isEmpty || signature.count == 64 else {
            throw CompanionError.malformed("invalid pact commitment")
        }
        try participant.validate(); try requireTimestamp(periodStart, name: "pact start"); try requireTimestamp(periodEnd, name: "pact end")
        self.pactID = pactID; self.participant = participant; self.periodStart = periodStart; self.periodEnd = periodEnd
        self.profileCommitment = profileCommitment; self.signature = signature
    }

    public func signingFields() -> [String] {
        [pactID, participant.identityID, base64URL(participant.publicKey), String(milliseconds(periodStart)),
         String(milliseconds(periodEnd)), base64URL(profileCommitment)]
    }

    public func validateSignature() throws {
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: participant.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: "\(CompanionCanonical.version).pact", fields: signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }
}

public enum PactStatus: String, Codable, Sendable { case proposed, accepted, cancelled, expired }

public struct BedtimePact: Codable, Hashable, Sendable {
    public let pactID: String
    public let proposer: DeviceIdentity
    public let participant: DeviceIdentity
    public let proposerCommitment: PactCommitment
    public var participantCommitment: PactCommitment?
    public let expiresAt: Date
    public var status: PactStatus

    public init(pactID: String, proposer: DeviceIdentity, participant: DeviceIdentity,
                proposerCommitment: PactCommitment, expiresAt: Date) throws {
        guard proposer.role == .trustedApprover, participant.role == .trustedApprover,
              proposer != participant, proposerCommitment.participant == proposer,
              expiresAt > proposerCommitment.periodStart,
              expiresAt.timeIntervalSince(proposerCommitment.periodStart) <= CompanionLimits.maxRequestLifetime else {
            throw CompanionError.malformed("invalid pact")
        }
        try proposerCommitment.validateSignature()
        self.pactID = pactID; self.proposer = proposer; self.participant = participant
        self.proposerCommitment = proposerCommitment; self.participantCommitment = nil
        self.expiresAt = expiresAt; self.status = .proposed
    }

    public func accepting(_ commitment: PactCommitment, at now: Date) throws -> BedtimePact {
        guard status == .proposed, now < expiresAt, commitment.pactID == pactID,
              commitment.participant == participant,
              commitment.periodStart == proposerCommitment.periodStart,
              commitment.periodEnd == proposerCommitment.periodEnd else { throw CompanionError.invalidTransition }
        try commitment.validateSignature()
        var copy = self; copy.participantCommitment = commitment; copy.status = .accepted
        return copy
    }

    public func cancelling(at now: Date) throws -> BedtimePact {
        guard status == .proposed, now < expiresAt else { throw CompanionError.invalidTransition }
        var copy = self; copy.status = .cancelled; return copy
    }

    public func effectiveStatus(at now: Date) -> PactStatus {
        status == .proposed && now >= expiresAt ? .expired : status
    }
}

public enum PactFactory {
    public static func commitment(pactID: String, signer: DeviceSigner, periodStart: Date, periodEnd: Date,
                                  profile: Data) throws -> PactCommitment {
        let digest = Data(SHA256.hash(data: profile))
        let unsigned = try PactCommitment(pactID: pactID, participant: signer.identity, periodStart: periodStart,
                                          periodEnd: periodEnd, profileCommitment: digest, signature: Data())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).pact", fields: unsigned.signingFields())
        return try PactCommitment(pactID: pactID, participant: signer.identity, periodStart: periodStart,
                                  periodEnd: periodEnd, profileCommitment: digest, signature: signature)
    }
}
