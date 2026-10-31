import Foundation
@testable import CompanionKit

/// Pairs `approver` with `owner` through the pairing-v3 flow: the owner
/// creates an invite, the friend looks the token up and accepts. The result is
/// an active pairing whose consent is already active on both sides
/// (generation 2), exactly what the old invite/accept/confirm/grant/accept
/// sequence produced.
@discardableResult
func pairV3(owner: CompanionClient, approver: CompanionClient, inviteID: String, acceptanceID: String,
            now: Date, nonce: Data? = nil, token: String? = nil,
            ownerName: String? = nil, approverName: String? = nil) throws -> Pairing {
    let issued = try owner.createInvite(inviteID: inviteID, validFor: 3_600, now: now, nonce: nonce,
                                        token: token, ownerDisplayName: ownerName)
    let invitation = try approver.lookupInvite(token: issued.token)
    return try approver.acceptInvite(invitation, token: issued.token, approverDisplayName: approverName,
                                     acceptanceID: acceptanceID, now: now)
}

/// Async sibling for the HTTP-client tests.
@discardableResult
func pairV3(owner: AsyncCompanionClient, approver: AsyncCompanionClient, inviteID: String, acceptanceID: String,
            now: Date, nonce: Data? = nil, token: String? = nil,
            ownerName: String? = nil, approverName: String? = nil) async throws -> Pairing {
    let issued = try await owner.createInvite(inviteID: inviteID, validFor: 3_600, now: now, nonce: nonce,
                                              token: token, ownerDisplayName: ownerName)
    let invitation = try await approver.lookupInvite(token: issued.token)
    return try await approver.acceptInvite(invitation, token: issued.token, approverDisplayName: approverName,
                                           acceptanceID: acceptanceID, now: now)
}
