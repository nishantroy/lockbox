import XCTest
@testable import CompanionKit

final class TrustMergeTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func identity(_ seed: UInt8, role: CompanionRole) throws -> DeviceIdentity {
        let key = Data(repeating: seed, count: 32)
        return try DeviceIdentity(identityID: DeviceIdentity.makeID(key), role: role, publicKey: key)
    }

    private func pairing(owner: DeviceIdentity, approver: DeviceIdentity, epoch: UInt64 = 1,
                         state: PairingState = .active, id: String = "pairing-1") throws -> Pairing {
        try Pairing(pairingID: id, owner: owner, approver: approver, epoch: epoch, createdAt: t, state: state)
    }

    private func consent(owner: DeviceIdentity, approver: DeviceIdentity, pairingID: String = "pairing-1",
                         epoch: UInt64 = 1, generation: UInt64 = 1) throws -> RelationshipConsent {
        try RelationshipConsent(relationshipID: pairingID, pairingID: pairingID, pairEpoch: epoch,
                                owner: owner, approver: approver, ownerScopes: [.approveEarlyEnd],
                                approverScopes: [.approveEarlyEnd], ownerState: .active, approverState: .active,
                                updatedAt: t, generation: generation)
    }

    // MARK: - Owner role never adds

    func testOwnerRoleNeverAddsANewPairingFromTheInbox() throws {
        let owner = try identity(1, role: .owner)
        let attacker = try identity(2, role: .trustedApprover)
        let malicious = try pairing(owner: owner, approver: attacker)
        let decision = CompanionTrustMerge.decide(pairing: malicious, viewerIdentityID: owner.identityID,
                                                  existingPairing: nil)
        guard case .rejected = decision else { return XCTFail("expected rejection, got \(decision)") }
    }

    func testOwnerRoleUpdatesOnlyItsOwnExistingPairing() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let existing = try pairing(owner: owner, approver: approver, epoch: 1)
        let advanced = try pairing(owner: owner, approver: approver, epoch: 2)
        let decision = CompanionTrustMerge.decide(pairing: advanced, viewerIdentityID: owner.identityID,
                                                  existingPairing: existing)
        guard case .update(let value) = decision else { return XCTFail("expected update, got \(decision)") }
        XCTAssertEqual(value.epoch, 2)
    }

    // MARK: - Approver key cannot be swapped

    func testApproverKeySwapOnExistingPairingIsRejected() throws {
        let owner = try identity(1, role: .owner)
        let realApprover = try identity(2, role: .trustedApprover)
        let attacker = try identity(3, role: .trustedApprover)
        let existing = try pairing(owner: owner, approver: realApprover)
        let swapped = try pairing(owner: owner, approver: attacker)
        let decision = CompanionTrustMerge.decide(pairing: swapped, viewerIdentityID: owner.identityID,
                                                  existingPairing: existing)
        guard case .rejected = decision else { return XCTFail("expected rejection, got \(decision)") }
    }

    func testOwnerKeySwapOnExistingPairingIsRejected() throws {
        let owner = try identity(1, role: .owner)
        let attackerOwner = try identity(4, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let existing = try pairing(owner: owner, approver: approver)
        let swapped = try pairing(owner: attackerOwner, approver: approver)
        // Viewed from the approver's identity, since the owner field changed.
        let decision = CompanionTrustMerge.decide(pairing: swapped, viewerIdentityID: approver.identityID,
                                                  existingPairing: existing)
        guard case .rejected = decision else { return XCTFail("expected rejection, got \(decision)") }
    }

    // MARK: - Epoch and state field lock

    func testEpochCannotRegress() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let existing = try pairing(owner: owner, approver: approver, epoch: 3)
        let lower = try pairing(owner: owner, approver: approver, epoch: 2)
        let decision = CompanionTrustMerge.decide(pairing: lower, viewerIdentityID: owner.identityID,
                                                  existingPairing: existing)
        guard case .rejected = decision else { return XCTFail("expected rejection, got \(decision)") }
    }

    func testStateCanMoveActiveToRevokedButNotBack() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let active = try pairing(owner: owner, approver: approver, state: .active)
        let revoked = try pairing(owner: owner, approver: approver, state: .revoked)

        let toRevoked = CompanionTrustMerge.decide(pairing: revoked, viewerIdentityID: owner.identityID,
                                                   existingPairing: active)
        guard case .update(let value) = toRevoked else { return XCTFail("expected update to revoked, got \(toRevoked)") }
        XCTAssertEqual(value.state, .revoked)

        let backToActive = CompanionTrustMerge.decide(pairing: active, viewerIdentityID: owner.identityID,
                                                       existingPairing: revoked)
        guard case .rejected = backToActive else { return XCTFail("expected rejection, got \(backToActive)") }
    }

    func testIdenticalPairingIsUnchanged() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let existing = try pairing(owner: owner, approver: approver)
        let decision = CompanionTrustMerge.decide(pairing: existing, viewerIdentityID: owner.identityID,
                                                  existingPairing: existing)
        XCTAssertEqual(decision, .unchanged)
    }

    // MARK: - Nothing is added from the inbox (no pending acceptances since pairing v3)

    func testNoRoleAddsAFirstSeenPairingFromTheInbox() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let newPairing = try pairing(owner: owner, approver: approver)
        for viewer in [owner, approver] {
            let decision = CompanionTrustMerge.decide(pairing: newPairing, viewerIdentityID: viewer.identityID,
                                                      existingPairing: nil)
            guard case .rejected = decision else { return XCTFail("expected rejection for \(viewer.role), got \(decision)") }
        }
    }

    func testFriendStillAdvancesAPairingItAlreadyStored() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let stored = try pairing(owner: owner, approver: approver, epoch: 1)
        let revoked = try pairing(owner: owner, approver: approver, epoch: 2, state: .revoked)
        let decision = CompanionTrustMerge.decide(pairing: revoked, viewerIdentityID: approver.identityID, existingPairing: stored)
        guard case .update(let value) = decision else { return XCTFail("expected update, got \(decision)") }
        XCTAssertEqual(value.state, .revoked)
    }

    func testPairingNotNamingTheViewerIsRejected() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let stranger = try identity(6, role: .trustedApprover)
        let unrelated = try pairing(owner: owner, approver: approver)
        let decision = CompanionTrustMerge.decide(pairing: unrelated, viewerIdentityID: stranger.identityID,
                                                  existingPairing: nil)
        guard case .rejected = decision else { return XCTFail("expected rejection, got \(decision)") }
    }

    // MARK: - Consent validation

    func testConsentMustMatchStoredPairingExactly() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let attacker = try identity(3, role: .trustedApprover)
        let stored = try pairing(owner: owner, approver: approver)

        let matching = try consent(owner: owner, approver: approver)
        guard case .accepted = CompanionTrustMerge.decide(consent: matching, for: stored, existingConsent: nil) else {
            return XCTFail("expected acceptance")
        }

        let wrongApprover = try consent(owner: owner, approver: attacker)
        guard case .rejected = CompanionTrustMerge.decide(consent: wrongApprover, for: stored, existingConsent: nil) else {
            return XCTFail("expected rejection for mismatched approver")
        }

        let wrongEpoch = try consent(owner: owner, approver: approver, epoch: 2)
        guard case .rejected = CompanionTrustMerge.decide(consent: wrongEpoch, for: stored, existingConsent: nil) else {
            return XCTFail("expected rejection for mismatched epoch")
        }

        let wrongPairingID = try consent(owner: owner, approver: approver, pairingID: "other-pairing")
        guard case .rejected = CompanionTrustMerge.decide(consent: wrongPairingID, for: stored, existingConsent: nil) else {
            return XCTFail("expected rejection for mismatched pairing ID")
        }
    }

    func testConsentGenerationCannotRegress() throws {
        let owner = try identity(1, role: .owner)
        let approver = try identity(2, role: .trustedApprover)
        let stored = try pairing(owner: owner, approver: approver)
        let existing = try consent(owner: owner, approver: approver, generation: 5)

        let lower = try consent(owner: owner, approver: approver, generation: 4)
        guard case .rejected = CompanionTrustMerge.decide(consent: lower, for: stored, existingConsent: existing) else {
            return XCTFail("expected rejection for a lower generation")
        }

        let same = try consent(owner: owner, approver: approver, generation: 5)
        guard case .accepted = CompanionTrustMerge.decide(consent: same, for: stored, existingConsent: existing) else {
            return XCTFail("expected acceptance for an equal generation")
        }

        let higher = try consent(owner: owner, approver: approver, generation: 6)
        guard case .accepted = CompanionTrustMerge.decide(consent: higher, for: stored, existingConsent: existing) else {
            return XCTFail("expected acceptance for a higher generation")
        }
    }
}
