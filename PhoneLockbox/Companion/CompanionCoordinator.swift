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
/// `ScreenTimeCoordinator`, `FamilyControls`, or `ManagedSettings` — the only
/// coupling to the lock itself is reading
/// `ScreenTimeCoordinator.companionActiveSessionIdentity` (read-only) so an
/// owner can name the current exact session in a request. This slice (B1)
/// never calls `useApproval`/consumes an approval into the lock lifecycle;
/// that is Slice B2, reviewed separately.
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

    /// Developer-only setting. Defaults to the local relay in
    /// `docs/r5-relay-plan.md`; on a device, set it to the Mac's LAN address.
    @Published var relayBaseURLString: String {
        didSet { sharedDefaults?.set(relayBaseURLString, forKey: Self.relayBaseURLDefaultsKey) }
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
            self.lastError = nil
        } else {
            // Fail visibly and stay disabled — never substitute a random
            // ephemeral suite or `.standard`, and never create identities or
            // Keychain keys without durable, App Group-backed storage to
            // remember them in.
            self.relayBaseURLString = Self.defaultRelayBaseURLString
            self.lastError = Self.appGroupUnavailableMessage
        }
        if resolvedDefaults != nil {
            loadIdentities()
            loadPeople()
            loadPendingAcceptances()
            pendingAcceptances = CompanionTrustMerge.pruneExpiredPendingAcceptances(pendingAcceptances, now: Date())
            savePendingAcceptances()
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
