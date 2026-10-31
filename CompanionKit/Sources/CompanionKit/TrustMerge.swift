import Foundation

/// Pure, side-effect-free trust rules for folding an untrusted relay inbox
/// snapshot (`InboxResponse.pairings`/`consents`, relay contract v1.1) into a
/// device's local cache. The inbox is a hint, not an authority: a relay can
/// lie, so nothing here can add a pairing at all. Since pairing v3 a pairing
/// reaches a device only from its own `acceptInvite` response (friend) or from
/// `JoinedAcceptanceCheck` against an invite it issued (owner); this merge
/// only ever *advances* a pairing that is already stored.
///
/// This type has no knowledge of `UserDefaults`, `Keychain`, or any app-level
/// registry shape — it only compares `Pairing`/`RelationshipConsent` values —
/// so it can be exercised directly by tests without any app scaffolding.
///
/// Known gap, deferred by design: this merge never learns a
/// `replace_pairing`/`PairingReplacement` outcome (a re-paired identity gets
/// a brand-new `pairingID`, which needs its own invite to be trusted, same as
/// any other unrelated new pairing).
public enum CompanionTrustDecision: Equatable, Sendable {
    /// The incoming pairing is identical to what is already stored; nothing
    /// to persist.
    case unchanged
    /// A local record exists and the incoming pairing is a permitted
    /// advance of it (epoch non-decreasing, `.active` → `.revoked` only).
    case update(Pairing)
    /// Untrusted or malformed; must be skipped without disturbing any
    /// existing local record.
    case rejected(String)
}

public enum CompanionConsentDecision: Equatable, Sendable {
    case accepted(RelationshipConsent)
    case rejected(String)
}

public enum CompanionTrustMerge {
    /// Neither `Pairing` nor `PairingConfirmation` carries a signature field
    /// in this protocol version (`Pairing` is a plain relay-produced record;
    /// `PairingConfirmation` is the *owner's own* signed operation, which
    /// this device already trusts because it produced it). There is
    /// therefore no signature to verify here today — authenticity instead
    /// comes entirely from the field-lock and first-use rules below, plus
    /// the transport's rollback anchor. If a future protocol version adds a
    /// signature to either type, it must be verified before any decision
    /// below is trusted.
    ///
    /// Decides what, if anything, to do with one relay-reported `pairing`.
    ///
    /// - Parameters:
    ///   - pairing: One entry from `InboxResponse.pairings`.
    ///   - viewerIdentityID: The local identity that fetched this inbox.
    ///   - existingPairing: This device's own stored copy for the same
    ///     `pairingID`, if any.
    public static func decide(pairing: Pairing, viewerIdentityID: String, existingPairing: Pairing?) -> CompanionTrustDecision {
        guard (try? pairing.validate()) != nil else {
            return .rejected("pairing failed structural validation")
        }
        let isOwner = pairing.owner.identityID == viewerIdentityID
        let isApprover = pairing.approver.identityID == viewerIdentityID
        guard isOwner || isApprover else {
            return .rejected("pairing does not name this identity")
        }

        if let existingPairing {
            guard existingPairing.owner == pairing.owner, existingPairing.approver == pairing.approver,
                  pairing.epoch >= existingPairing.epoch else {
                return .rejected("pairing changed a locked field (owner, approver, or epoch regressed)")
            }
            switch (existingPairing.state, pairing.state) {
            case (.active, .active), (.revoked, .revoked), (.active, .revoked):
                break
            case (.revoked, .active):
                return .rejected("pairing cannot move from revoked back to active")
            }
            if existingPairing.epoch == pairing.epoch, existingPairing.state == pairing.state {
                return .unchanged
            }
            return .update(pairing)
        }

        // No local record yet: a pairing is never created from the inbox. The
        // friend stores the response to its own `acceptInvite`; the owner adds
        // a person only through `JoinedAcceptanceCheck`.
        return .rejected("a pairing is never added from the relay inbox")
    }

    /// Decides whether an incoming `consent` may replace `existingConsent`
    /// for the given (already-trusted) `pairing`.
    public static func decide(consent: RelationshipConsent, for pairing: Pairing,
                              existingConsent: RelationshipConsent?) -> CompanionConsentDecision {
        guard (try? consent.validate()) != nil else {
            return .rejected("consent failed structural validation")
        }
        guard consent.pairingID == pairing.pairingID, consent.pairEpoch == pairing.epoch,
              consent.owner == pairing.owner, consent.approver == pairing.approver else {
            return .rejected("consent does not match the stored pairing's ID, epoch, owner, or approver")
        }
        guard consent.generation >= (existingConsent?.generation ?? 0) else {
            return .rejected("consent generation regressed")
        }
        return .accepted(consent)
    }
}
