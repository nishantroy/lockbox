import Foundation

#if canImport(CompanionKit)
import CompanionKit

/// Local-only registry entry for one paired relationship. The relay (v1) has
/// no "list my pairings" or "read consent" endpoint, so the device's own
/// cache of `Pairing`/`RelationshipConsent` — updated whenever a mutation
/// succeeds — is the only place this information lives on this device. This
/// mirrors the architecture note that the owner's device, not the relay, is
/// the thing this prototype trusts to remember its own state.
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

    var hasGrantedApproveEarlyEnd: Bool {
        consent?.ownerScopes.contains(.approveEarlyEnd) ?? false
    }

    var hasAcceptedApproveEarlyEnd: Bool {
        consent?.approverScopes.contains(.approveEarlyEnd) ?? false
    }

    var isFullyTrustedForEarlyEnd: Bool {
        consent?.authorizes(.approveEarlyEnd) ?? false
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
    private static let ownerIdentityDefaultsKey = "com.phone-lockbox.companion.identity.owner.v1"
    private static let approverIdentityDefaultsKey = "com.phone-lockbox.companion.identity.approver.v1"
    private static let relayBaseURLDefaultsKey = "com.phone-lockbox.companion.relayBaseURL.v1"
    static let defaultRelayBaseURLString = "http://127.0.0.1:8002"
    private static let acceptanceLinkPrefix = "PLBX-ACCEPT:"

    @Published private(set) var ownerIdentity: DeviceIdentity?
    @Published private(set) var approverIdentity: DeviceIdentity?
    @Published private(set) var people: [CompanionPerson] = []
    @Published private(set) var inboxItems: [CompanionInboxItem] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var pendingInvitation: Invitation?
    @Published var pendingAcceptance: PairingAcceptance?

    /// Developer-only setting. Defaults to the local relay in
    /// `docs/r5-relay-plan.md`; on a device, set it to the Mac's LAN address.
    @Published var relayBaseURLString: String {
        didSet { sharedDefaults.set(relayBaseURLString, forKey: Self.relayBaseURLDefaultsKey) }
    }

    private let keyStore: any DeviceKeyStore
    private let sharedDefaults: UserDefaults
    private let anchorStore: any RollbackAnchorStore
    private let makeSession: @Sendable () -> URLSession

    init(keyStore: (any DeviceKeyStore)? = nil,
        sharedDefaults: UserDefaults? = nil,
        makeSession: @escaping @Sendable () -> URLSession = { URLSession(configuration: .ephemeral) }) {
        self.keyStore = keyStore ?? KeychainDeviceKeyStore(service: Self.keychainService)
        let defaults = sharedDefaults ?? UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        self.sharedDefaults = defaults
        self.anchorStore = UserDefaultsRollbackAnchorStore(defaults: defaults)
        self.relayBaseURLString = defaults.string(forKey: Self.relayBaseURLDefaultsKey) ?? Self.defaultRelayBaseURLString
        self.makeSession = makeSession
        loadIdentities()
        loadPeople()
    }

    // MARK: - Identity and persistence

    private func loadIdentities() {
        ownerIdentity = decodedIdentity(forKey: Self.ownerIdentityDefaultsKey)
        approverIdentity = decodedIdentity(forKey: Self.approverIdentityDefaultsKey)
    }

    private func decodedIdentity(forKey key: String) -> DeviceIdentity? {
        guard let data = sharedDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
    }

    private func ensureIdentity(role: CompanionRole) throws -> DeviceIdentity {
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
        guard let data = sharedDefaults.data(forKey: Self.peopleDefaultsKey),
              let decoded = try? JSONDecoder().decode([CompanionPerson].self, from: data) else { return }
        people = decoded
    }

    private func savePeople() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(people) else { return }
        sharedDefaults.set(data, forKey: Self.peopleDefaultsKey)
    }

    private func upsertPerson(pairing: Pairing, localRole: CompanionPerson.LocalRole, nickname: String? = nil,
                              consent: RelationshipConsent? = nil) {
        if let index = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID }) {
            people[index].pairing = pairing
            if let consent { people[index].consent = consent }
            if let nickname { people[index].nickname = nickname }
        } else {
            let name = nickname ?? (localRole == .iAmOwner ? "Trusted person" : "Person you're helping")
            people.append(CompanionPerson(nickname: name, localRole: localRole, pairing: pairing, consent: consent))
        }
        savePeople()
    }

    // MARK: - Transport

    private func makeClient(signer: DeviceSigner) -> AsyncCompanionClient {
        let baseURL = URL(string: relayBaseURLString) ?? URL(string: Self.defaultRelayBaseURLString)!
        let ownerID = ownerIdentity?.identityID
        let transport = HTTPCompanionTransport(baseURL: baseURL, session: makeSession(), anchorStore: anchorStore,
                                               enforceStateRoot: false, fallbackOwnerIdentityID: { ownerID })
        return AsyncCompanionClient(signer: signer, transport: transport)
    }

    private func signer(for identity: DeviceIdentity) throws -> DeviceSigner {
        try DeviceSigner(identity: identity, keyStore: keyStore)
    }

    private func fail(_ error: Error) {
        lastError = Self.describe(error)
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
        case .keyUnavailable: return "This device's companion key is unavailable and needs to be re-paired."
        case .expired: return "That invitation or request has expired."
        case .wrongVerificationCode: return "That code doesn't match. Double-check it with the other person."
        case .revokedPairing: return "That pairing has been revoked."
        case .rateLimited: return "Too many attempts. Wait a moment and try again."
        case .consentRequired: return "That person hasn't accepted early-end trust yet."
        default: return "The relay rejected that action (\(error.transportCode))."
        }
    }

    // MARK: - Invite / accept / confirm

    func createInvite() async {
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let invitation = try await client.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date())
            pendingInvitation = invitation
            lastError = nil
        } catch { fail(error) }
    }

    /// Parses a link produced by `Invitation.shareLink`.
    func decodeInvitation(from link: String) -> Invitation? {
        try? Invitation.fromShareLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func acceptInvite(_ invitation: Invitation) async {
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let acceptance = try await client.accept(invitation, acceptanceID: UUID().uuidString, now: Date())
            pendingAcceptance = acceptance
            lastError = nil
        } catch { fail(error) }
    }

    /// A share-friendly encoding of a `PairingAcceptance`, analogous to
    /// `Invitation.shareLink`. There is no relay endpoint to list pending
    /// acceptances (v1 has only operations/inbox/health), so the friend
    /// shares this back to the owner out of band, the same way the invite
    /// itself was shared.
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

    func confirmAcceptance(_ acceptance: PairingAcceptance, nickname: String) async {
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let pairing = try await client.confirm(acceptance, verificationCode: acceptance.verificationCode, now: Date())
            upsertPerson(pairing: pairing, localRole: .iAmOwner,
                        nickname: nickname.isEmpty ? nil : nickname)
            pendingAcceptance = nil
            lastError = nil
        } catch { fail(error) }
    }

    // MARK: - Consent

    func grantEarlyEndTrust(_ person: CompanionPerson) async {
        guard person.localRole == .iAmOwner else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let consent = try await client.grantScopes(pairing: person.pairing, scopes: [.approveEarlyEnd, .receiveRequests])
            upsertPerson(pairing: person.pairing, localRole: .iAmOwner, consent: consent)
            lastError = nil
        } catch { fail(error) }
    }

    func acceptEarlyEndTrust(_ person: CompanionPerson) async {
        guard person.localRole == .iAmApprover else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let consent = try await client.acceptScopes(pairing: person.pairing, scopes: [.approveEarlyEnd, .receiveRequests])
            upsertPerson(pairing: person.pairing, localRole: .iAmApprover, consent: consent)
            lastError = nil
        } catch { fail(error) }
    }

    func revokeEarlyEndTrust(_ person: CompanionPerson) async {
        do {
            let identity = try ensureIdentity(role: person.localRole == .iAmOwner ? .owner : .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let consent = try await client.revokeScopes(pairing: person.pairing, scopes: [.approveEarlyEnd, .receiveRequests])
            upsertPerson(pairing: person.pairing, localRole: person.localRole, consent: consent)
            lastError = nil
        } catch { fail(error) }
    }

    func revokePairing(_ person: CompanionPerson) async {
        guard person.localRole == .iAmOwner else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            try await client.revoke(person.pairing)
            people.removeAll { $0.id == person.id }
            savePeople()
            lastError = nil
        } catch { fail(error) }
    }

    func rename(_ person: CompanionPerson, to nickname: String) {
        guard let index = people.firstIndex(where: { $0.id == person.id }), !nickname.isEmpty else { return }
        people[index].nickname = nickname
        savePeople()
    }

    // MARK: - Ask to end early (owner) / approve-decline (friend)

    var trustedApprovers: [CompanionPerson] {
        people.filter { $0.localRole == .iAmOwner && $0.isFullyTrustedForEarlyEnd }
    }

    func requestEarlyEnd(sessionID: String, activeSetID: String, start: Date, end: Date,
                        to targets: [CompanionPerson]) async {
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
            _ = try await client.requestUnlock(requestID: UUID().uuidString, pairings: targets.map(\.pairing),
                                               consents: targets.compactMap(\.consent), session: session,
                                               targets: targets.map { $0.pairing.approver.identityID },
                                               validFor: max(60, end.timeIntervalSince(Date())))
            lastError = nil
            await refreshInbox()
        } catch { fail(error) }
    }

    func respond(_ item: CompanionInboxItem, decision: ApproverDecision) async {
        guard !item.isMine,
              let targetBinding = item.request.binding(for: item.viewerIdentityID),
              let person = people.first(where: { $0.pairing.pairingID == targetBinding.pairingID }) else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            _ = try await client.submitApproval(request: item.request, pairing: person.pairing, decision: decision)
            lastError = nil
            await refreshInbox()
        } catch { fail(error) }
    }

    // MARK: - Foreground refresh

    func refreshInbox() async {
        isRefreshing = true
        defer { isRefreshing = false }
        var items: [CompanionInboxItem] = []
        if let ownerIdentity, let signer = try? signer(for: ownerIdentity) {
            let client = makeClient(signer: signer)
            if let requests = try? await client.fetchInbox() {
                items += requests.map { CompanionInboxItem(request: $0, viewerIdentityID: ownerIdentity.identityID) }
            }
        }
        if let approverIdentity, let signer = try? signer(for: approverIdentity) {
            let client = makeClient(signer: signer)
            if let requests = try? await client.fetchInbox() {
                items += requests.map { CompanionInboxItem(request: $0, viewerIdentityID: approverIdentity.identityID) }
            }
        }
        inboxItems = items.sorted { $0.request.createdAt > $1.request.createdAt }
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
