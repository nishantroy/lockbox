import Foundation

#if canImport(CompanionKit)
import CompanionKit

/// Local-only registry entry for one paired relationship. The relay (v1) has
/// no "list my pairings" endpoint outside of `/v1/inbox`'s `pairings`/
/// `consents` arrays, so the device's own cache — refreshed on every inbox
/// fetch through `CompanionTrustMerge`'s field-locked rules, and updated
/// whenever a mutation this device makes succeeds — is the only place this
/// information lives on this device. The inbox itself is treated as an
/// untrusted hint, never an authority: see `CompanionTrustMerge` for exactly
/// what a relay is and is not allowed to change here.
struct CompanionPerson: Codable, Identifiable, Hashable {
    enum LocalRole: String, Codable {
        /// This pairing is for *my* lockbox; `pairing.approver` is the
        /// trusted person who can help me.
        case iAmOwner
        /// This pairing is for *their* lockbox; `pairing.owner` is the
        /// person I am helping.
        case iAmApprover
    }

    var id: String { pairing.pairingID }
    var nickname: String
    var localRole: LocalRole
    var pairing: Pairing
    var consent: RelationshipConsent?

    var hasGrantedApproveEarlyEnd: Bool { consent?.ownerScopes.contains(.approveEarlyEnd) ?? false }
    var hasGrantedReceiveRequests: Bool { consent?.ownerScopes.contains(.receiveRequests) ?? false }
    var hasAcceptedApproveEarlyEnd: Bool { consent?.approverScopes.contains(.approveEarlyEnd) ?? false }
    var hasAcceptedReceiveRequests: Bool { consent?.approverScopes.contains(.receiveRequests) ?? false }

    /// The relay requires **both** `approveEarlyEnd` and `receiveRequests`
    /// bilaterally active before it will accept a request/approval for this
    /// pairing, so "fully trusted" means both, not just `approveEarlyEnd`.
    var isFullyTrustedForEarlyEnd: Bool {
        guard let consent else { return false }
        return consent.authorizes(.approveEarlyEnd) && consent.authorizes(.receiveRequests)
    }
}

/// One request as seen by this device, from whichever side it participates
/// as. A request created on this device (`isMine == true`) shows status only;
/// a request naming this device's approver identity shows approve/decline
/// when this identity has not yet decided.
struct CompanionInboxItem: Identifiable {
    let request: TrustedRequest
    let viewerIdentityID: String

    var id: String { request.requestID + "#" + viewerIdentityID }
    var isMine: Bool { request.owner.identityID == viewerIdentityID }
    var myDecision: ApproverDecision? { request.decisions[viewerIdentityID] }
    var status: TrustedRequestStatus { request.effectiveStatus(at: Date()) }
}

/// Drives the People tab. Companion pairing/consent/requests never touch
/// `FamilyControls` or `ManagedSettings` directly. Coupling to the lock
/// itself is deliberately narrow: reading
/// `ScreenTimeCoordinator.companionActiveSessionIdentity` (read-only) so an
/// owner can name the current exact session in a request (R5 Slice B1), and
/// — only when the developer gate
/// (`CompanionCoordinator.friendApprovalCanEndLocksEnabled`) is on —
/// calling `ScreenTimeCoordinator.prepareFriendRelease`/`applyFriendRelease`/
/// `abandonFriendRelease` to actually end one exact session from a verified
/// approval (R5 Slice B2c). This coordinator still owns every network call,
/// signature and `OwnerApprovalCheck`; `ScreenTimeCoordinator` only ever
/// records/applies/abandons the durable intent under its own transaction
/// lock and clock.
@MainActor
final class CompanionCoordinator: ObservableObject {
    private static let keychainService = "com.phone-lockbox.companion.keys"
    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private static let peopleDefaultsKey = "com.phone-lockbox.companion.people.v1"
    /// Replaces the earlier `acceptedInviteOwners.v1` key (a bare
    /// `Set<DeviceIdentity>`), which let *any* owner this device had ever
    /// accepted an invite from justify an unbounded number of first-seen
    /// pairings. This is prototype-only local state, so the old key is
    /// simply abandoned rather than migrated.
    private static let pendingAcceptancesDefaultsKey = "com.phone-lockbox.companion.pendingAcceptances.v1"
    private static let ownerIdentityDefaultsKey = "com.phone-lockbox.companion.identity.owner.v1"
    private static let approverIdentityDefaultsKey = "com.phone-lockbox.companion.identity.approver.v1"
    private static let relayBaseURLDefaultsKey = "com.phone-lockbox.companion.relayBaseURL.v1"
    static let defaultRelayBaseURLString = "http://127.0.0.1:8002"
    private static let acceptanceLinkPrefix = "PLBX-ACCEPT:"
    /// R5 Slice B2c developer gate. Defaults to **off**; see
    /// `docs/r5-b2-plan.md` ("Developer gate"). Persisted in the App Group
    /// suite (falls back to `false` when storage is unavailable, same as
    /// every other companion feature).
    private static let friendApprovalGateDefaultsKey = "com.phone-lockbox.companion.friendApprovalCanEndLocks.v1"
    /// R5 Slice B2c review, P2-6: `[requestID: useID]`.
    private static let useIDsByRequestIDDefaultsKey = "com.phone-lockbox.companion.friendReleaseUseIDs.v1"
    private static let appGroupUnavailableMessage =
        "The shared App Group storage is unavailable. Companion features are disabled on this device."

    @Published private(set) var ownerIdentity: DeviceIdentity?
    @Published private(set) var approverIdentity: DeviceIdentity?
    @Published private(set) var people: [CompanionPerson] = []
    @Published private(set) var inboxItems: [CompanionInboxItem] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// A non-blocking notice that the relay sent pairing/consent data this
    /// device rejected as untrusted. Refresh still completes normally;
    /// rejected entries are simply skipped. Distinct from `lastError`, which
    /// is reserved for actual failures (transport, key, anchor).
    @Published private(set) var inboxDataNotice: String?
    /// Set only when a signer's private key could not be loaded from the
    /// Keychain, so the People tab can offer a distinct "re-pair" affordance
    /// instead of a generic error.
    @Published private(set) var needsRepair = false
    @Published var pendingInvitation: Invitation?
    @Published var pendingAcceptance: PairingAcceptance?
    /// R5 Slice B2a: the relay-stored `Approval` for each request this
    /// device's owner identity has fetched in its own anchored inbox,
    /// keyed by `requestID`. Populated alongside `inboxItems` on every
    /// `refreshInbox()`/`endLockNow` fetch; used only for People tab display
    /// (approver name) and to find the approval to act on. Never trusted as
    /// an authorization decision by itself — `OwnerApprovalCheck.verify` and
    /// the relay's own `use` check are the actual authorities.
    @Published private(set) var approvalsByRequestID: [String: Approval] = [:]

    /// Developer-only setting. Defaults to the local relay in
    /// `docs/r5-relay-plan.md`; on a device, set it to the Mac's LAN address.
    @Published var relayBaseURLString: String {
        didSet { sharedDefaults?.set(relayBaseURLString, forKey: Self.relayBaseURLDefaultsKey) }
    }

    /// R5 Slice B2c developer gate: "Friend approval can end locks
    /// (prototype)" in Settings. Defaults to **off**. When off, the People
    /// tab behaves exactly as in B1 — approved requests show status only,
    /// and `endLockNow`/the foreground replay never act. Mutating this
    /// never itself ends a lock.
    @Published var friendApprovalCanEndLocksEnabled: Bool {
        didSet { sharedDefaults?.set(friendApprovalCanEndLocksEnabled, forKey: Self.friendApprovalGateDefaultsKey) }
    }

    private let keyStore: any DeviceKeyStore
    /// `nil` when the App Group suite could not be opened. When `nil`, no
    /// identity or Keychain key is ever created, no pairing data is ever
    /// persisted or read, and every public action below is a no-op that
    /// leaves `lastError` exactly as it is — there is deliberately no
    /// fallback to a random/ephemeral suite or to `.standard`.
    private let sharedDefaults: UserDefaults?
    private let anchorStore: (any RollbackAnchorStore)?
    private let makeSession: @Sendable () -> URLSession
    /// R5 Slice B2c review, P1-1: the single in-flight friend-release
    /// `Task`, shared by `endLockNow` and `replayPendingFriendRelease`.
    private var friendReleaseFlight: Task<Void, Never>?
    /// R5 Slice B2c review, P2-6: the `useID` this coordinator generated for
    /// each `requestID` it has attempted `endLockNow` for, so a later
    /// released marker can be attributed to the exact request that caused
    /// it (not merely the session). Persisted so this survives relaunch.
    private var useIDsByRequestID: [String: String] = [:]

    /// `false` only when the App Group suite is unavailable. The People tab
    /// should treat every companion action as disabled in that state.
    var isAvailable: Bool { sharedDefaults != nil }

    init(keyStore: (any DeviceKeyStore)? = nil,
        sharedDefaults: UserDefaults? = nil,
        makeSession: @escaping @Sendable () -> URLSession = { URLSession(configuration: .ephemeral) }) {
        self.keyStore = keyStore ?? KeychainDeviceKeyStore(service: Self.keychainService)
        let resolvedDefaults = sharedDefaults ?? UserDefaults(suiteName: Self.appGroupIdentifier)
        self.sharedDefaults = resolvedDefaults
        self.anchorStore = resolvedDefaults.map { UserDefaultsRollbackAnchorStore(defaults: $0) }
        self.makeSession = makeSession
        if let resolvedDefaults {
            self.relayBaseURLString = resolvedDefaults.string(forKey: Self.relayBaseURLDefaultsKey) ?? Self.defaultRelayBaseURLString
            self.friendApprovalCanEndLocksEnabled = resolvedDefaults.object(forKey: Self.friendApprovalGateDefaultsKey) as? Bool ?? false
            self.lastError = nil
        } else {
            // Fail visibly and stay disabled — never substitute a random
            // ephemeral suite or `.standard`, and never create identities or
            // Keychain keys without durable, App Group-backed storage to
            // remember them in.
            self.relayBaseURLString = Self.defaultRelayBaseURLString
            self.friendApprovalCanEndLocksEnabled = false
            self.lastError = Self.appGroupUnavailableMessage
        }
        if resolvedDefaults != nil {
            loadIdentities()
            loadPeople()
            loadPendingAcceptances()
            pendingAcceptances = CompanionTrustMerge.pruneExpiredPendingAcceptances(pendingAcceptances, now: Date())
            savePendingAcceptances()
            loadUseIDsByRequestID()
        }
    }

    // MARK: - Identity and persistence

    private var pendingAcceptances: [CompanionPendingAcceptance] = []

    private func loadIdentities() {
        ownerIdentity = decodedIdentity(forKey: Self.ownerIdentityDefaultsKey)
        approverIdentity = decodedIdentity(forKey: Self.approverIdentityDefaultsKey)
    }

    private func decodedIdentity(forKey key: String) -> DeviceIdentity? {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
    }

    private func ensureIdentity(role: CompanionRole) throws -> DeviceIdentity {
        guard let sharedDefaults else { throw CompanionError.malformed("companion storage is unavailable") }
        let key = role == .owner ? Self.ownerIdentityDefaultsKey : Self.approverIdentityDefaultsKey
        if let existing = decodedIdentity(forKey: key) {
            // A missing private key is a repair state, not silently
            // regenerated. Surface it as an error from the caller's signer
            // construction rather than minting a new identity here.
            return existing
        }
        let manager = IdentityManager(keyStore: keyStore)
        let stored = try manager.create(role: role)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        sharedDefaults.set(try encoder.encode(stored.identity), forKey: key)
        if role == .owner { ownerIdentity = stored.identity } else { approverIdentity = stored.identity }
        return stored.identity
    }

    private func loadPeople() {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: Self.peopleDefaultsKey),
              let decoded = try? JSONDecoder().decode([CompanionPerson].self, from: data) else { return }
        people = decoded
    }

    private func savePeople() {
        guard let sharedDefaults else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(people) else { return }
        sharedDefaults.set(data, forKey: Self.peopleDefaultsKey)
    }

    private func loadPendingAcceptances() {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: Self.pendingAcceptancesDefaultsKey),
              let decoded = try? JSONDecoder().decode([CompanionPendingAcceptance].self, from: data) else { return }
        pendingAcceptances = decoded
    }

    private func savePendingAcceptances() {
        guard let sharedDefaults else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(pendingAcceptances) else { return }
        sharedDefaults.set(data, forKey: Self.pendingAcceptancesDefaultsKey)
    }

    private func loadUseIDsByRequestID() {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: Self.useIDsByRequestIDDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        useIDsByRequestID = decoded
    }

    private func saveUseIDsByRequestID() {
        guard let sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(useIDsByRequestID) else { return }
        sharedDefaults.set(data, forKey: Self.useIDsByRequestIDDefaultsKey)
    }

    /// R5 Slice B2c review, P2-6: records which `useID` this coordinator
    /// generated for `requestID`, so a later released marker can be
    /// attributed to the exact request that caused it.
    private func recordUseID(_ useID: String, forRequestID requestID: String) {
        useIDsByRequestID[requestID] = useID
        saveUseIDsByRequestID()
    }

    /// Looks up a known person's display name for `identityID`, wherever it
    /// appears as either side of a pairing this device knows about.
    func personName(forIdentityID identityID: String) -> String? {
        people.first { $0.pairing.owner.identityID == identityID || $0.pairing.approver.identityID == identityID }?.nickname
    }

    // MARK: - Transport

    private func makeClient(signer: DeviceSigner) -> AsyncCompanionClient {
        let baseURL = URL(string: relayBaseURLString) ?? URL(string: Self.defaultRelayBaseURLString)!
        let transport = HTTPCompanionTransport(baseURL: baseURL, session: makeSession(), anchorStore: anchorStore,
                                               enforceStateRoot: true)
        return AsyncCompanionClient(signer: signer, transport: transport)
    }

    private func signer(for identity: DeviceIdentity) throws -> DeviceSigner {
        try DeviceSigner(identity: identity, keyStore: keyStore)
    }

    private func fail(_ error: Error) {
        needsRepair = Self.isKeyUnavailable(error)
        lastError = Self.describe(error)
    }

    private static func isKeyUnavailable(_ error: Error) -> Bool {
        switch error {
        case CompanionError.keyUnavailable: return true
        case CompanionTransportError.server(.keyUnavailable): return true
        default: return false
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CompanionTransportError.unavailable, CompanionTransportError.timedOut:
            return "Couldn't reach the local relay. Check the Developer relay address and that it's running."
        case CompanionTransportError.malformedResponse:
            return "The relay sent back something this prototype couldn't read."
        case CompanionTransportError.server(let inner):
            return describeCompanionError(inner)
        case let inner as CompanionError:
            return describeCompanionError(inner)
        default:
            return "Something went wrong: \(error.localizedDescription)"
        }
    }

    private static func describeCompanionError(_ error: CompanionError) -> String {
        switch error {
        case .keyUnavailable:
            return "This device's companion key is unavailable and needs to be re-paired."
        case .expired: return "That invitation or request has expired."
        case .wrongVerificationCode: return "That code doesn't match. Double-check it with the other person."
        case .revokedPairing: return "That pairing has been revoked."
        case .rateLimited: return "Too many attempts. Wait a moment and try again."
        case .consentRequired: return "That person hasn't accepted early-end trust yet."
        case .malformed(let detail) where detail.localizedCaseInsensitiveContains("state root")
            || detail.localizedCaseInsensitiveContains("owner identity")
            || detail.localizedCaseInsensitiveContains("anchor"):
            return "The relay's response failed an integrity check (\(detail)). Treating this as untrusted; nothing was changed here."
        // R5 Slice B2c: both are integrity-fatal (`AsyncCompanionClient.UseFailureDisposition`)
        // and never retried or abandoned automatically — see `finishFriendRelease`.
        case .relayRollback:
            return "This device's own record of the relay disagrees with what it just reported. Nothing was changed; this needs attention before trying again."
        case .responseVerificationFailed:
            return "The relay's response to that action failed a local safety check. Nothing was changed; this needs attention before trying again."
        default: return "The relay rejected that action (\(error.transportCode))."
        }
    }

    // MARK: - Invite / accept / confirm

    func createInvite() async {
        guard isAvailable else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let invitation = try await client.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date())
            pendingInvitation = invitation
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Parses a link produced by `Invitation.shareLink`.
    func decodeInvitation(from link: String) -> Invitation? {
        try? Invitation.fromShareLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func acceptInvite(_ invitation: Invitation) async {
        guard isAvailable else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let acceptanceID = UUID().uuidString
            let acceptance = try await client.accept(invitation, acceptanceID: acceptanceID, now: Date())
            pendingAcceptance = acceptance
            // Persisted so a later inbox-reported pairing can be checked
            // against this exact accept attempt — see `CompanionTrustMerge`
            // and `CompanionPendingAcceptance`. The record is consumed
            // (removed) once its pairing is learned from the inbox.
            let record = try CompanionPendingAcceptance(ownerIdentity: invitation.payload.owner, acceptanceID: acceptanceID,
                                                        approverIdentity: identity, createdAt: Date())
            pendingAcceptances.append(record)
            savePendingAcceptances()
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// A share-friendly encoding of a `PairingAcceptance`, analogous to
    /// `Invitation.shareLink`. There is no relay endpoint to list pending
    /// acceptances (v1 has only operations/inbox/health), so the friend
    /// shares this back to the owner out of band, the same way the invite
    /// itself was shared. It never includes the verification code in a form
    /// meant to be read visually — the owner types the code the friend reads
    /// aloud, so a copied link alone cannot complete pairing.
    func acceptanceShareText(_ acceptance: PairingAcceptance) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(acceptance)) ?? Data()
        return Self.acceptanceLinkPrefix + data.base64EncodedString()
    }

    func decodeAcceptance(from text: String) -> PairingAcceptance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.acceptanceLinkPrefix),
              let data = Data(base64Encoded: String(trimmed.dropFirst(Self.acceptanceLinkPrefix.count))) else { return nil }
        return try? JSONDecoder().decode(PairingAcceptance.self, from: data)
    }

    /// `typedVerificationCode` is whatever the owner typed after hearing the
    /// friend read their six digits aloud — never the code decoded from
    /// `acceptance` itself. This checks the typed code locally against
    /// `acceptance.verificationCode` before signing or contacting the relay
    /// (a fast, honest "that doesn't match" instead of a wasted round trip);
    /// the relay's own `wrongVerificationCode` check on `confirm` remains
    /// the actual authority, since `acceptance` itself could in principle be
    /// stale by the time this runs.
    func confirmAcceptance(_ acceptance: PairingAcceptance, typedVerificationCode: String, nickname: String) async {
        guard isAvailable else { return }
        guard typedVerificationCode == acceptance.verificationCode else {
            lastError = "That code doesn't match. Double-check it with the other person."
            return
        }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let pairing = try await client.confirm(acceptance, verificationCode: typedVerificationCode, now: Date())
            upsertConfirmedPairing(pairing, nickname: nickname.isEmpty ? nil : nickname)
            pendingAcceptance = nil
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Only path that may create an `.iAmOwner` person entry — a direct
    /// result of this device's own `confirm()` call (already checked against
    /// the acceptance by `validateConfirmResponse` inside `confirm` itself),
    /// never the inbox. Still never replaces an existing entry whose owner
    /// or approver differs, as a last line of defense against a pairing-ID
    /// collision or a caller bug.
    private func upsertConfirmedPairing(_ pairing: Pairing, nickname: String?) {
        if let index = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID }) {
            guard people[index].pairing.owner == pairing.owner, people[index].pairing.approver == pairing.approver else {
                lastError = "The relay returned a pairing that conflicts with one already stored; ignoring it."
                return
            }
            people[index].pairing = pairing
            if let nickname { people[index].nickname = nickname }
        } else {
            people.append(CompanionPerson(nickname: nickname ?? "Trusted person", localRole: .iAmOwner,
                                          pairing: pairing, consent: nil))
        }
        savePeople()
    }

    // MARK: - Consent (two independent scopes, per person)

    /// Owner side: grant or revoke exactly one scope for `person`, leaving
    /// the other scope's grant untouched. `grantScopes`/`acceptScopes`
    /// replace the full scope set, so this reads the current set from cached
    /// consent, adds/removes just `scope`, and resubmits; `revokeScopes` is
    /// already subtractive.
    func setOwnerGrant(_ scope: CompanionScope, enabled: Bool, for person: CompanionPerson) async {
        guard isAvailable, person.localRole == .iAmOwner else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let consent: RelationshipConsent
            if enabled {
                var scopes = Set(person.consent?.ownerScopes ?? [])
                scopes.insert(scope)
                consent = try await client.grantScopes(pairing: person.pairing, scopes: Array(scopes))
            } else {
                consent = try await client.revokeScopes(pairing: person.pairing, scopes: [scope])
            }
            applyOwnConsentUpdate(consent, forPairingID: person.pairing.pairingID)
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Approver side: accept or revoke exactly one scope for `person`.
    func setApproverAccept(_ scope: CompanionScope, enabled: Bool, for person: CompanionPerson) async {
        guard isAvailable, person.localRole == .iAmApprover else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let consent: RelationshipConsent
            if enabled {
                var scopes = Set(person.consent?.approverScopes ?? [])
                scopes.insert(scope)
                consent = try await client.acceptScopes(pairing: person.pairing, scopes: Array(scopes))
            } else {
                consent = try await client.revokeScopes(pairing: person.pairing, scopes: [scope])
            }
            applyOwnConsentUpdate(consent, forPairingID: person.pairing.pairingID)
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Even a consent returned in direct response to this device's own
    /// signed mutation still comes from the relay over the wire, so it is
    /// routed through the same `CompanionTrustMerge.decide(consent:)` check
    /// as inbox-observed consent (matching pairing ID/epoch/owner/approver,
    /// generation never regressing) rather than stored as-is.
    private func applyOwnConsentUpdate(_ consent: RelationshipConsent, forPairingID pairingID: String) {
        guard let index = people.firstIndex(where: { $0.pairing.pairingID == pairingID }) else { return }
        switch CompanionTrustMerge.decide(consent: consent, for: people[index].pairing, existingConsent: people[index].consent) {
        case .accepted(let accepted):
            people[index].consent = accepted
            savePeople()
        case .rejected(let reason):
            lastError = "The relay returned unexpected consent data (\(reason)); ignoring it."
        }
    }

    func revokePairing(_ person: CompanionPerson) async {
        guard isAvailable, person.localRole == .iAmOwner else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            try await client.revoke(person.pairing)
            // Marked revoked in place rather than deleted, so a later inbox
            // fetch that still lists this pairing (now `.revoked` there too)
            // can only confirm the same state through `CompanionTrustMerge`'s
            // field lock — never resurrect it as a fresh, unrevoked entry.
            if let index = people.firstIndex(where: { $0.id == person.id }) {
                people[index].pairing.state = .revoked
            }
            savePeople()
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    func rename(_ person: CompanionPerson, to nickname: String) {
        guard isAvailable, let index = people.firstIndex(where: { $0.id == person.id }), !nickname.isEmpty else { return }
        people[index].nickname = nickname
        savePeople()
    }

    // MARK: - Ask to end early (owner) / approve-decline (friend)

    var trustedApprovers: [CompanionPerson] {
        people.filter { $0.localRole == .iAmOwner && $0.pairing.state == .active && $0.isFullyTrustedForEarlyEnd }
    }

    func requestEarlyEnd(sessionID: String, activeSetID: String, start: Date, end: Date,
                        to targets: [CompanionPerson]) async {
        guard isAvailable else { return }
        guard !targets.isEmpty, targets.allSatisfy({ $0.localRole == .iAmOwner && $0.isFullyTrustedForEarlyEnd }) else {
            lastError = "Choose at least one trusted person who has accepted early-end trust."
            return
        }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let session = try ActiveSession(owner: identity, sessionID: sessionID, activeSetID: activeSetID,
                                            startsAt: start, endsAt: end)
            _ = try await client.publishSession(session)
            let validFor = min(max(60, end.timeIntervalSince(Date())), CompanionLimits.maxRequestLifetime)
            _ = try await client.requestUnlock(requestID: UUID().uuidString, pairings: targets.map(\.pairing),
                                               consents: targets.compactMap(\.consent), session: session,
                                               targets: targets.map { $0.pairing.approver.identityID },
                                               validFor: validFor)
            lastError = nil; needsRepair = false
            await refreshInbox()
        } catch { fail(error) }
    }

    func respond(_ item: CompanionInboxItem, decision: ApproverDecision) async {
        guard isAvailable else { return }
        guard !item.isMine else {
            lastError = "This is your own request; there's nothing for you to approve here."
            return
        }
        guard let targetBinding = item.request.binding(for: item.viewerIdentityID) else {
            lastError = "This request doesn't target this device's identity."
            return
        }
        guard let person = people.first(where: { $0.pairing.pairingID == targetBinding.pairingID }) else {
            lastError = "No known pairing matches this request. Pull to refresh and try again."
            return
        }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            _ = try await client.submitApproval(request: item.request, pairing: person.pairing, decision: decision)
            lastError = nil; needsRepair = false
            await refreshInbox()
        } catch { fail(error) }
    }

    // MARK: - End lock now (R5 Slice B2c)
    //
    // Gated by `friendApprovalCanEndLocksEnabled` (off by default). No
    // release ever happens without a verified `use` response: `coordinator
    // .applyFriendRelease` is only ever called after `useApproval` has
    // returned and been locally re-verified by `AsyncCompanionClient` itself.

    /// Per-request People tab state (R5 Slice B2c review, P2-6): keyed by
    /// the request, not merely the session it targets, so two different
    /// requests that happen to target the same session are never confused
    /// with each other.
    enum FriendReleaseRequestState: Equatable {
        case eligible
        case finishing
        case usedToEnd
        case alreadyEnded
    }

    /// Whether the People tab's gate-on "End lock now" row should be shown
    /// at all for this item. A pure, testable predicate (R5 Slice B2c
    /// review, P2-10) kept in sync with the view by construction — the view
    /// calls this instead of inlining the same three conditions.
    static func shouldShowFriendReleaseAction(for item: CompanionInboxItem, gateEnabled: Bool) -> Bool {
        gateEnabled && item.isMine && item.status == .approved
    }

    /// The state `FriendReleaseActionView` renders for one inbox item,
    /// independent of the developer gate (the gate only decides whether the
    /// *row* appears at all; `.finishing` is shown regardless — P2-12).
    func friendReleaseRequestState(for item: CompanionInboxItem, coordinator: any FriendReleaseLifecycle) -> FriendReleaseRequestState {
        if let pending = coordinator.pendingFriendReleaseIntent, pending.requestID == item.request.requestID {
            return .finishing
        }
        switch coordinator.friendReleaseSessionState(sessionID: item.request.sessionID) {
        case .eligible, .finishing:
            // `.finishing` here means a *different* request's intent is
            // pending against the same session; this request itself is
            // still eligible (a tap will get a calm "already in progress"
            // no-op from `prepareFriendRelease`, never a confusing state).
            return .eligible
        case .usedToEnd:
            // Only attribute the release to *this* request if the useID
            // this coordinator generated for it is the one that actually
            // released the session — another request's approval could have
            // released the same session instead.
            if let ourUseID = useIDsByRequestID[item.request.requestID],
               coordinator.friendReleaseUseID(forSessionID: item.request.sessionID) == ourUseID {
                return .usedToEnd
            }
            return .alreadyEnded
        case .alreadyEnded:
            return .alreadyEnded
        }
    }

    /// Pure selection + local authorization check for `endLockNow`/the
    /// foreground replay: finds the named request and its delivered
    /// approval in an already-fetched owner-anchored inbox response,
    /// resolves the approver's locally cached pairing/consent, and runs
    /// `OwnerApprovalCheck.verify` before any mutation or network `use`
    /// call. No I/O — every input is already in hand. `internal` (not
    /// `private`) so `PhoneLockboxTests` can exercise it directly (R5 Slice
    /// B2c review, P1-3).
    static func selectFriendRelease(
        response: InboxResponse,
        requestID: String,
        people: [CompanionPerson],
        ownerIdentity: DeviceIdentity
    ) throws -> (request: TrustedRequest, approval: Approval, trustedApprover: OwnerApprovalCheck.TrustedApprover) {
        guard let request = response.requests.first(where: { $0.requestID == requestID }) else {
            throw CompanionError.notFound
        }
        guard let approval = response.approvals?.first(where: { $0.requestID == requestID }) else {
            throw CompanionError.notFound
        }
        guard let targetBinding = request.binding(for: approval.approver.identityID),
              let person = people.first(where: { $0.pairing.pairingID == targetBinding.pairingID }),
              let consent = person.consent else {
            throw CompanionError.unknownIdentity
        }
        let trustedApprover = OwnerApprovalCheck.TrustedApprover(pairing: person.pairing, consent: consent)
        try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trustedApprover, ownerIdentity: ownerIdentity)
        return (request, approval, trustedApprover)
    }

    /// The owner taps **End lock now** on their own approved request. Checks
    /// the approval against this device's own trusted-person cache with
    /// `OwnerApprovalCheck` (never trusting the inbox fetch alone), persists
    /// a durable intent through `coordinator.prepareFriendRelease`, then
    /// submits `use` and applies the release once verified. Every step uses
    /// the **latest** owner-anchored inbox fetch, never a possibly stale
    /// cached `item`/`approvalsByRequestID` entry. Single-flight with the
    /// foreground replay (R5 Slice B2c review, P1-1): a second call while
    /// one is already running joins it instead of starting a duplicate.
    func endLockNow(_ item: CompanionInboxItem, coordinator: any FriendReleaseLifecycle) async {
        guard isAvailable, friendApprovalCanEndLocksEnabled else { return }
        await runSingleFlightFriendRelease { [weak self] in
            await self?.performEndLockNow(item, coordinator: coordinator)
        }
    }

    private func performEndLockNow(_ item: CompanionInboxItem, coordinator: any FriendReleaseLifecycle) async {
        guard item.isMine else {
            lastError = "This is a request you're helping with, not your own request."
            return
        }
        guard let ownerIdentity, item.request.owner == ownerIdentity else {
            lastError = "This request doesn't belong to this device's owner identity."
            return
        }
        do {
            let signer = try signer(for: ownerIdentity)
            let client = makeClient(signer: signer)
            let response = try await client.fetchInboxResponse()
            for approval in response.approvals ?? [] { approvalsByRequestID[approval.requestID] = approval }
            _ = applyInboxSnapshot(response, viewerIdentity: ownerIdentity)
            let (request, approval, _) = try Self.selectFriendRelease(
                response: response, requestID: item.request.requestID, people: people, ownerIdentity: ownerIdentity
            )
            guard let sessionUUID = UUID(uuidString: request.sessionID) else {
                lastError = "This request's session identifier could not be read."
                return
            }
            // R5 Slice B2c review (P2-3): the gate may have been turned off
            // during the inbox round trip above; re-check immediately before
            // ever persisting a durable intent.
            guard friendApprovalCanEndLocksEnabled else { return }
            let useID = UUID().uuidString
            recordUseID(useID, forRequestID: request.requestID)
            let prepareOutcome = try coordinator.prepareFriendRelease(
                sessionID: sessionUUID,
                activeSetID: request.activeSetID,
                requestID: request.requestID,
                approvalID: approval.approvalID,
                useID: useID,
                approverIdentityID: approval.approver.identityID
            )
            switch prepareOutcome {
            case .recorded:
                lastError = nil
            case .noOp(let reason):
                lastError = Self.prepareNoOpMessage(reason)
                return
            }
            await finishFriendRelease(request: request, approval: approval, useID: useID, coordinator: coordinator)
        } catch {
            fail(error)
        }
    }

    /// Foreground replay: if a friend-release intent is durably pending (the
    /// app was interrupted after `prepareFriendRelease` but before a verified
    /// `use`), re-verifies it against the latest inbox and retries `use`
    /// with the same `useID`, then finishes the release. Safe to call
    /// unconditionally on every foreground/pull-to-refresh — it never starts
    /// a new release; only an explicit `endLockNow` tap does that.
    /// Deliberately not gated on `friendApprovalCanEndLocksEnabled`:
    /// finishing a use the owner already started is the one automatic step
    /// the plan allows, regardless of the gate's current value. Single-
    /// flight with `endLockNow` (P1-1): joins an in-flight call instead of
    /// racing it into a second `use` submission.
    func replayPendingFriendRelease(coordinator: any FriendReleaseLifecycle) async {
        guard isAvailable, coordinator.pendingFriendReleaseIntent != nil, ownerIdentity != nil else { return }
        await runSingleFlightFriendRelease { [weak self] in
            await self?.performReplayPendingFriendRelease(coordinator: coordinator)
        }
    }

    private func performReplayPendingFriendRelease(coordinator: any FriendReleaseLifecycle) async {
        // Re-read the pending intent now that this call actually owns the
        // single flight: it may have been resolved by whichever call this
        // one joined above.
        guard let pending = coordinator.pendingFriendReleaseIntent, let ownerIdentity else { return }
        let response: InboxResponse
        do {
            let signer = try signer(for: ownerIdentity)
            let client = makeClient(signer: signer)
            response = try await client.fetchInboxResponse()
        } catch {
            // A transport/local failure fetching the inbox is not surfaced
            // as a blocking error on every foreground; it is retried on the
            // next foreground or explicit tap.
            return
        }
        for approval in response.approvals ?? [] { approvalsByRequestID[approval.requestID] = approval }
        _ = applyInboxSnapshot(response, viewerIdentity: ownerIdentity)
        // R5 Slice B2c review (P2-2): re-select and re-verify from scratch
        // (never trust the approval cached when this intent was first
        // prepared), and additionally pin the result to the *exact*
        // approval/approver this intent was prepared against -- a request
        // can in principle carry a newer approval by the time of a replay,
        // and that must never be substituted in silently.
        guard let (request, approval, _) = try? Self.selectFriendRelease(
            response: response, requestID: pending.requestID, people: people, ownerIdentity: ownerIdentity
        ), approval.approvalID == pending.approvalID,
              approval.approver.identityID == pending.approverIdentityID else {
            // R5 Slice B2c review (P2-5): calm, explicit status rather than
            // silence, since this can otherwise look like nothing is
            // happening indefinitely. Never abandons automatically --
            // `discardPendingFriendRelease` is the explicit developer
            // escape hatch for a durably stuck intent.
            lastError = Self.pendingReleaseUnavailableMessage
            return
        }
        await finishFriendRelease(request: request, approval: approval, useID: pending.useID, coordinator: coordinator)
    }

    /// Developer-only escape hatch (R5 Slice B2c review, P2-5): clears a
    /// durably pending friend-release intent without ever submitting `use`.
    /// For the case where the request/approval it depends on will never
    /// reappear in the inbox (declined elsewhere, expired, purged). Never
    /// releases anything by itself.
    func discardPendingFriendRelease(coordinator: any FriendReleaseLifecycle) {
        guard let pending = coordinator.pendingFriendReleaseIntent else { return }
        do {
            _ = try coordinator.abandonFriendRelease(useID: pending.useID)
            lastError = nil
        } catch {
            lastError = "Couldn't discard the pending request: \(error.localizedDescription)"
        }
    }

    static let pendingReleaseUnavailableMessage = "This request is no longer available; the lock stays on until it ends."

    /// Shared tail of `endLockNow`/`replayPendingFriendRelease`: submits
    /// `use` (via `submitUse`, overridable in tests), classifies any failure
    /// with `AsyncCompanionClient.UseFailureDisposition`, and applies the
    /// release only on a verified response. `internal` (not `private`) so
    /// `PhoneLockboxTests` can exercise its branching directly (R5 Slice B2c
    /// review, P1-3).
    func finishFriendRelease(request: TrustedRequest, approval: Approval, useID: String, coordinator: any FriendReleaseLifecycle) async {
        do {
            let verification = try await submitUse(approval, request: request, useID: useID)
            _ = verification
            do {
                let applyOutcome = try coordinator.applyFriendRelease(useID: useID)
                switch applyOutcome {
                case .released:
                    lastError = nil
                case .noOp(let reason):
                    // R5 Slice B2c review (P1-1): a verified `use` followed
                    // by `.noMatchingPendingIntent` most often means a
                    // concurrent flight already applied this exact release
                    // (the intent it was keyed on is already gone) --
                    // confirm via the durable released marker and report
                    // success, not a confusing "already ended".
                    if reason == .noMatchingPendingIntent,
                       coordinator.friendReleaseSessionState(sessionID: request.sessionID) == .usedToEnd {
                        lastError = nil
                    } else {
                        lastError = Self.applyNoOpMessage(reason)
                    }
                }
            } catch {
                fail(error)
            }
        } catch {
            switch AsyncCompanionClient.UseFailureDisposition.classify(error) {
            case .retryable:
                lastError = "Couldn't reach the relay. Pull to refresh to finish."
            case .definitive:
                let message = Self.definitiveUseFailureMessage(error)
                do {
                    _ = try coordinator.abandonFriendRelease(useID: useID)
                    lastError = message
                } catch let abandonError {
                    // R5 Slice B2c review (P2-8): handle/report rather than
                    // silently swallow -- the pending intent may now be
                    // stuck until a developer uses "Discard pending friend
                    // release".
                    lastError = "\(message) This device could not clear the pending request locally (\(abandonError.localizedDescription)); use Discard pending friend release in Settings if it stays stuck."
                }
            case .integrityFatal:
                lastError = "The relay's response failed an integrity check. Nothing was changed here; this needs attention before trying again."
            }
        }
    }

    /// Submits `use` for the given approval/request/useID using this
    /// device's owner signer. Defaults to the real `AsyncCompanionClient
    /// .useApproval` round trip (built via `makeClient`); overridable only
    /// for tests (R5 Slice B2c review, P1-3) so `finishFriendRelease`'s
    /// branching can be exercised without a network transport.
    var useApprovalOverride: (@MainActor (_ approval: Approval, _ request: TrustedRequest, _ useID: String) async throws -> ApprovalVerification)?

    private func submitUse(_ approval: Approval, request: TrustedRequest, useID: String) async throws -> ApprovalVerification {
        if let override = useApprovalOverride {
            return try await override(approval, request, useID)
        }
        guard let ownerIdentity else { throw CompanionError.unauthorized }
        let client = makeClient(signer: try signer(for: ownerIdentity))
        return try await client.useApproval(approval, request: request, useID: useID)
    }

    /// Ensures `endLockNow` and the foreground replay never race each other
    /// into two concurrent `use` submissions: only one friend-release flight
    /// runs at a time, and a second caller awaits the one already running
    /// instead of starting its own (R5 Slice B2c review, P1-1). `internal`
    /// (not `private`) so `PhoneLockboxTests` can exercise it directly.
    func runSingleFlightFriendRelease(_ work: @escaping () async -> Void) async {
        if let inFlight = friendReleaseFlight {
            await inFlight.value
            return
        }
        let task = Task { await work() }
        friendReleaseFlight = task
        await task.value
        friendReleaseFlight = nil
    }

    /// Test-only visibility into whether a friend-release flight is
    /// currently running.
    var hasFriendReleaseFlightInFlight: Bool { friendReleaseFlight != nil }

    /// Copy for `prepareFriendRelease`'s no-op outcomes — shown immediately
    /// after an owner's tap, before any network call. `internal` (not
    /// `private`) so `PhoneLockboxTests` can assert this mapping directly.
    static func prepareNoOpMessage(_ reason: RuntimeFriendRelease.NoOpReason) -> String {
        switch reason {
        case .alreadyEnded: return "This lock already ended."
        case .activeSetMismatch: return "This approval is for a different lock."
        case .conflictingPendingIntent: return "Another end-lock request is already in progress."
        case .noMatchingPendingIntent: return "This lock already ended."
        }
    }

    /// Copy for `applyFriendRelease`'s no-op outcomes — every one is
    /// terminal (the durable intent is already cleared); never retried.
    /// `internal` (not `private`) so `PhoneLockboxTests` can assert this
    /// mapping directly.
    static func applyNoOpMessage(_ reason: RuntimeFriendRelease.NoOpReason) -> String {
        switch reason {
        case .alreadyEnded: return "This lock already ended."
        case .activeSetMismatch: return "Your locks changed; ask again."
        case .conflictingPendingIntent: return "This lock already ended."
        case .noMatchingPendingIntent: return "This lock already ended."
        }
    }

    /// Calm, specific copy for a **definitive** `use` rejection (R5 Slice
    /// B2c review, P2-8), falling back to the generic `describe(_:)` for
    /// any code not named here.
    static func definitiveUseFailureMessage(_ error: Error) -> String {
        let companionError: CompanionError?
        switch error {
        case let direct as CompanionError:
            companionError = direct
        case let transport as CompanionTransportError:
            if case .server(let inner) = transport { companionError = inner } else { companionError = nil }
        default:
            companionError = nil
        }
        switch companionError {
        case .replay:
            return "This approval was already used."
        case .expired:
            return "This approval expired; ask again."
        case .revokedPairing, .consentRequired:
            return "This friend can no longer approve early ends."
        default:
            return Self.describe(error)
        }
    }

    // MARK: - Foreground refresh

    /// Fetches this device's owner and/or approver inbox and, from each
    /// response's `pairings`/`consents` (relay contract v1.1), folds them
    /// into the local person registry through `CompanionTrustMerge`'s
    /// field-locked, untrusted-by-default rules. When the App Group is
    /// unavailable this is a no-op that leaves `lastError` exactly as it is.
    func refreshInbox() async {
        guard isAvailable else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let prunedCount = pendingAcceptances.count
        pendingAcceptances = CompanionTrustMerge.pruneExpiredPendingAcceptances(pendingAcceptances, now: Date())
        if pendingAcceptances.count != prunedCount { savePendingAcceptances() }
        var items: [CompanionInboxItem] = []
        var encounteredError: Error?
        var anyFetchSucceeded = false
        var rejectionCount = 0

        if let ownerIdentity {
            do {
                let signer = try signer(for: ownerIdentity)
                let client = makeClient(signer: signer)
                let response = try await client.fetchInboxResponse()
                items += response.requests.map { CompanionInboxItem(request: $0, viewerIdentityID: ownerIdentity.identityID) }
                // Owner-fetch only (contract v1.2); never present on a helper
                // fetch. Merged in (never wiped by a failed/helper-only
                // fetch) — display-only, see `approvalsByRequestID`.
                for approval in response.approvals ?? [] { approvalsByRequestID[approval.requestID] = approval }
                rejectionCount += applyInboxSnapshot(response, viewerIdentity: ownerIdentity)
                anyFetchSucceeded = true
            } catch { encounteredError = error }
        }
        if let approverIdentity {
            do {
                let signer = try signer(for: approverIdentity)
                let client = makeClient(signer: signer)
                let response = try await client.fetchInboxResponse()
                items += response.requests.map { CompanionInboxItem(request: $0, viewerIdentityID: approverIdentity.identityID) }
                rejectionCount += applyInboxSnapshot(response, viewerIdentity: approverIdentity)
                anyFetchSucceeded = true
            } catch { encounteredError = error }
        }

        inboxItems = items.sorted { $0.request.createdAt > $1.request.createdAt }
        inboxDataNotice = rejectionCount > 0
            ? "The relay returned unexpected pairing or consent data; \(rejectionCount) item(s) were ignored."
            : nil
        if let encounteredError {
            fail(encounteredError)
        } else if anyFetchSucceeded || (ownerIdentity == nil && approverIdentity == nil) {
            lastError = nil; needsRepair = false
        }
    }

    /// Applies `CompanionTrustMerge`'s decision for every pairing/consent in
    /// one inbox response. Returns the number of rejected (untrusted or
    /// malformed) entries so the caller can surface a single non-blocking
    /// notice; a rejection never aborts the rest of the refresh.
    @discardableResult
    private func applyInboxSnapshot(_ response: InboxResponse, viewerIdentity: DeviceIdentity) -> Int {
        guard let pairings = response.pairings else { return 0 }
        var consentsByPairingID: [String: RelationshipConsent] = [:]
        for consent in response.consents ?? [] { consentsByPairingID[consent.pairingID] = consent }

        var rejections = 0
        for pairing in pairings {
            let existingIndex = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID })
            let existingPairing = existingIndex.map { people[$0].pairing }
            let decision = CompanionTrustMerge.decide(pairing: pairing, viewerIdentityID: viewerIdentity.identityID,
                                                      existingPairing: existingPairing,
                                                      pendingAcceptances: pendingAcceptances)
            let resolvedPairing: Pairing?
            switch decision {
            case .unchanged:
                resolvedPairing = existingPairing
            case .update(let updated):
                if let existingIndex { people[existingIndex].pairing = updated }
                resolvedPairing = updated
            case .add(let added, let consumedAcceptanceID):
                let localRole: CompanionPerson.LocalRole = added.owner.identityID == viewerIdentity.identityID ? .iAmOwner : .iAmApprover
                let name = localRole == .iAmOwner ? "Trusted person" : "Person you're helping"
                people.append(CompanionPerson(nickname: name, localRole: localRole, pairing: added, consent: nil))
                // Consumed so this record cannot justify a second, different
                // pairing later.
                pendingAcceptances.removeAll { $0.acceptanceID == consumedAcceptanceID }
                savePendingAcceptances()
                resolvedPairing = added
            case .rejected:
                rejections += 1
                resolvedPairing = nil
            }

            guard let resolvedPairing,
                  let currentIndex = people.firstIndex(where: { $0.pairing.pairingID == resolvedPairing.pairingID }) else { continue }
            guard let candidateConsent = consentsByPairingID[resolvedPairing.pairingID] else { continue }
            switch CompanionTrustMerge.decide(consent: candidateConsent, for: resolvedPairing, existingConsent: people[currentIndex].consent) {
            case .accepted(let accepted):
                people[currentIndex].consent = accepted
            case .rejected:
                rejections += 1
            }
        }
        if rejections > 0 || !pairings.isEmpty { savePeople() }
        return rejections
    }

    // MARK: - Developer

    /// Deletes every on-device rollback-anchor checkpoint. This is a
    /// deliberate escape hatch for development/testing only: after a reset,
    /// the next response for a given owner is treated as the first one seen,
    /// so a real regression or fork in the interim would no longer be
    /// detected. It never touches paired-people data or consent.
    func resetRelayAnchors() {
        guard let anchorStore else {
            lastError = Self.appGroupUnavailableMessage
            return
        }
        do {
            try RollbackAnchor(store: anchorStore).resetAll()
            lastError = nil
        } catch {
            lastError = "Couldn't reset relay anchors: \(error.localizedDescription)"
        }
    }
}
#else
/// The parent app links CompanionKit separately. Keeping this fallback lets
/// the existing app continue to build before that package dependency lands.
@MainActor
final class CompanionCoordinator: ObservableObject {
    @Published private(set) var lastError: String? = "CompanionKit is not linked in this build."
}
#endif
