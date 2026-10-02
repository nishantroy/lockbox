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

/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b"): one
/// relay-delivered `SignedAcceptance` this device has already verified with
/// `OwnerAcceptanceCheck` against an invite **this device created** and
/// still has stored locally. Only an instance of this type may ever be
/// shown to the owner or confirmed — a `SignedAcceptance` that failed
/// verification, or whose `inviteID` has no matching local invite, never
/// becomes one (see `CompanionCoordinator.verifyPendingAcceptances`).
struct VerifiedPendingAcceptance: Identifiable, Equatable {
    let signedAcceptance: SignedAcceptance
    /// The six-digit code this device independently derived while verifying
    /// `signedAcceptance` — passed straight to `confirm(_:verificationCode:)`
    /// so the owner never reads or types a code.
    let expectedVerificationCode: String

    var id: String { signedAcceptance.acceptance.acceptanceID }
    var acceptance: PairingAcceptance { signedAcceptance.acceptance }
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
    /// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", item 1):
    /// every `Invitation` this device created, keyed by `inviteID`, kept
    /// until it is consumed (confirmed or explicitly discarded via "Not
    /// them") or has expired. This is the local trust anchor for
    /// `OwnerAcceptanceCheck` — a relay-delivered `SignedAcceptance` is only
    /// ever verified (and shown) against an invite found here, never merely
    /// inferred from the acceptance itself.
    private static let storedInvitesDefaultsKey = "com.phone-lockbox.companion.storedInvites.v1"
    private static let ownerIdentityDefaultsKey = "com.phone-lockbox.companion.identity.owner.v1"
    private static let approverIdentityDefaultsKey = "com.phone-lockbox.companion.identity.approver.v1"
    private static let relayBaseURLDefaultsKey = "com.phone-lockbox.companion.relayBaseURL.v1"
    static let defaultRelayBaseURLString = "https://relay.example.com"
    /// Builds 16–17 defaulted to the local development relay. A stored value
    /// equal to it is treated as "never customised" and follows the default.
    static let legacyLocalRelayBaseURLString = "http://127.0.0.1:8002"
    /// Scheme for `Invitation.shareLink`/`.fromShareLink(_:)` (registered in
    /// `project.yml`'s `CFBundleURLTypes` alongside `phonelockbox`).
    static let companionLinkScheme = "phone-lockbox-companion"
    /// Shown for any `phone-lockbox-companion://...` link this device
    /// doesn't recognize (review P2-1), and for a recognized invite link
    /// whose payload doesn't actually decode once looked at (review P2-2,
    /// `AcceptInviteCard`). Same wording in both cases: "an invite link" is
    /// the only kind of companion link a person can currently receive.
    static let invalidInviteLinkMessage = "This invite link isn't valid."
    /// R5 pairing v2 P2b, UX fix item 7: shown instead of silently
    /// prefilling an expired invite link, so an expired invite reads as an
    /// explicit, actionable message rather than a link that simply does
    /// nothing useful once accepted.
    static let expiredInviteLinkMessage = "This invite has expired; ask for a new one."
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
    /// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", UX fix
    /// item 7): set by `ContentView.onOpenURL` via
    /// `handleIncomingCompanionLink` when it recognizes a decodable,
    /// not-yet-expired `phone-lockbox-companion://invite/...` link. Drives a
    /// top-of-page "You've been invited" prompt in `PeopleView` (Accept /
    /// Not now) in front of the user, rather than silently prefilling a
    /// field below the fold. Opening the link never itself accepts anything
    /// — Accept still requires an explicit tap, which clears this.
    @Published var incomingInvite: Invitation?
    /// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", item 2):
    /// every acceptance from the owner's latest inbox fetch that this
    /// device could verify with `OwnerAcceptanceCheck` against an invite it
    /// created and still has stored locally. Replaced wholesale on every
    /// successful owner-anchored `refreshInbox()` (never merged — the inbox
    /// is the authority on what is *currently* pending); left unchanged on a
    /// failed fetch.
    @Published private(set) var pendingOwnerAcceptances: [VerifiedPendingAcceptance] = []
    /// R5 Slice B2a: the relay-stored `Approval` for each request this
    /// device's owner identity has fetched in its own anchored inbox,
    /// keyed by `requestID`. Populated alongside `inboxItems` on every
    /// `refreshInbox()`/`endLockNow` fetch; used only for People tab display
    /// (approver name) and to find the approval to act on. Never trusted as
    /// an authorization decision by itself — `OwnerApprovalCheck.verify` and
    /// the relay's own `use` check are the actual authorities.
    @Published private(set) var approvalsByRequestID: [String: Approval] = [:]

    /// Developer-only setting. Defaults to the deployed prototype relay
    /// (`docs/r5-relay-plan.md`, Deployment); override it for local relay work.
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
    /// R5 Slice B2c review, R2-3: the `requestID` the current
    /// `friendReleaseFlight` is actually working on, set only by the call
    /// that *starts* the flight (never by one that joins it).
    private var friendReleaseFlightRequestID: String?
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
            let stored = resolvedDefaults.string(forKey: Self.relayBaseURLDefaultsKey)
            self.relayBaseURLString = (stored == nil || stored == Self.legacyLocalRelayBaseURLString) ? Self.defaultRelayBaseURLString : stored!
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
        #if DEBUG
        // UI-test-only override: `-relayBaseURL <url>` is a standard Xcode
        // launch-argument pair, read once at launch so a scripted UI test
        // can point this coordinator at a local relay without touching the
        // Developer settings UI. Never compiled into a release build, and
        // never consulted outside DEBUG even if a release binary somehow
        // launched with this argument.
        if let override = Self.relayBaseURLLaunchArgumentOverride() {
            self.relayBaseURLString = override
        }
        // UI-test-only full reset: `-resetCompanionStateForUITests` clears
        // this app's companion identity (the Keychain-held private keys),
        // every companion App Group key, and the rollback anchors, before
        // anything below loads them — so a UI test gets a brand-new
        // owner/approver identity and a clean anchor on every launch,
        // regardless of what a previous (possibly interrupted) test run,
        // or another process sharing the same local relay's Postgres, left
        // behind. Without this, a real relay-state regression (for
        // example, another test suite truncating the shared local
        // database) is correctly, but unhelpfully, reported as
        // `CompanionError.relayRollback` against a stale identity's
        // leftover anchor. Never compiled into a release build, and never
        // reachable from any production UI.
        if ProcessInfo.processInfo.arguments.contains("-resetCompanionStateForUITests") {
            Self.resetCompanionStateForUITests(keyStore: self.keyStore, sharedDefaults: resolvedDefaults, anchorStore: self.anchorStore)
        }
        #endif
        if resolvedDefaults != nil {
            loadIdentities()
            loadPeople()
            loadPendingAcceptances()
            pendingAcceptances = CompanionTrustMerge.pruneExpiredPendingAcceptances(pendingAcceptances, now: Date())
            savePendingAcceptances()
            loadStoredInvites()
            pruneStoredInvites(now: Date())
            loadUseIDsByRequestID()
        }
    }

    // MARK: - Identity and persistence

    private var pendingAcceptances: [CompanionPendingAcceptance] = []
    /// Every `Invitation` this device created, keyed by `inviteID`. See
    /// `storedInvitesDefaultsKey`.
    private var storedInvites: [String: Invitation] = [:]

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

    private func loadStoredInvites() {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: Self.storedInvitesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: Invitation].self, from: data) else { return }
        storedInvites = decoded
    }

    private func saveStoredInvites() {
        guard let sharedDefaults else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(storedInvites) else { return }
        sharedDefaults.set(data, forKey: Self.storedInvitesDefaultsKey)
    }

    /// Drops any stored invite that has expired as of `now`. An expired
    /// invite can never again be confirmed (`OwnerAcceptanceCheck.verify`
    /// itself rejects it), so keeping it around serves no purpose.
    private func pruneStoredInvites(now: Date) {
        let before = storedInvites.count
        storedInvites = storedInvites.filter { now < $0.value.payload.expiresAt }
        if storedInvites.count != before { saveStoredInvites() }
    }

    /// Removes one invite from the local store — called once it is
    /// consumed (confirmed) or explicitly discarded ("Not them"). There is
    /// no relay "cancel invite" endpoint in this protocol version
    /// (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", item 4): discarding the
    /// invite locally is sufficient on its own, because `OwnerAcceptanceCheck
    /// .verify` requires an invite **this device still has stored**, so once
    /// it is gone, nothing — including the same acceptance reappearing on a
    /// later inbox fetch — can ever be confirmed from it again on this
    /// device. The invite also still expires naturally relay-side, which
    /// independently removes it from `InboxResponse.pendingAcceptances` (see
    /// `OwnerAcceptanceCheck`'s own expiry check and the P2a retention
    /// rules), so this is belt-and-suspenders rather than the only
    /// protection.
    private func discardStoredInvite(inviteID: String) {
        guard storedInvites.removeValue(forKey: inviteID) != nil else { return }
        saveStoredInvites()
        if pendingInvitation?.payload.inviteID == inviteID { pendingInvitation = nil }
    }

    /// Owner-review follow-up (P2-7): caps `storedInvites` so creating many
    /// invites over a long device lifetime cannot grow it unboundedly.
    /// Drops the oldest (by `issuedAt`) once the count exceeds the cap — a
    /// dropped invite simply can no longer be confirmed on this device
    /// (same practical effect as "Not them" or natural expiry); this is a
    /// defensive bound, not expected to matter in ordinary prototype use.
    /// Mutates `storedInvites` only — callers are responsible for
    /// `saveStoredInvites()`.
    private static let maxStoredInvites = 20

    private func trimStoredInvitesIfNeeded() {
        guard storedInvites.count > Self.maxStoredInvites else { return }
        let overflow = storedInvites.count - Self.maxStoredInvites
        let oldestFirst = storedInvites.values.sorted { $0.payload.issuedAt < $1.payload.issuedAt }
        for invitation in oldestFirst.prefix(overflow) {
            storedInvites.removeValue(forKey: invitation.payload.inviteID)
        }
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

    /// Keeps `useIDsByRequestID` from growing unboundedly and drops entries
    /// for requests this device's owner identity no longer sees in its own
    /// ledger at all (R5 Slice B2c review, R2-4). Called after every
    /// successful owner-anchored inbox fetch with that fetch's own
    /// `response.requests`, never with a helper-side listing.
    private func pruneUseIDsByRequestID(presentRequestIDs: Set<String>) {
        let before = useIDsByRequestID
        useIDsByRequestID = useIDsByRequestID.filter { presentRequestIDs.contains($0.key) }
        if useIDsByRequestID.count > 64 {
            // Dictionaries carry no reliable ordering, so this is a
            // defensive cap on pathological growth, not a precise
            // least-recently-used eviction; the filter above already
            // handles the common case of stale/purged requests.
            let overflow = useIDsByRequestID.count - 64
            for key in useIDsByRequestID.keys.prefix(overflow) {
                useIDsByRequestID.removeValue(forKey: key)
            }
        }
        if useIDsByRequestID != before {
            saveUseIDsByRequestID()
        }
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
        #if DEBUG
        // Opus review of 70c7d27 (docs follow-up): `.unavailable` and
        // `.timedOut` share one user-facing banner ("Couldn't reach the
        // relay…"), so a transient flake's exact transport-level cause is
        // otherwise unrecoverable after the fact. This never reaches a
        // release build.
        switch error {
        case CompanionTransportError.unavailable:
            print("[CompanionCoordinator] transport error: .unavailable")
        case CompanionTransportError.timedOut:
            print("[CompanionCoordinator] transport error: .timedOut")
        default:
            break
        }
        #endif
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
            return "Couldn't reach the relay. Check your connection and try again."
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

    #if DEBUG
    /// Reads a `-relayBaseURL <url>` launch-argument pair, if present and a
    /// valid URL. DEBUG-only — see the call site in `init`.
    private static func relayBaseURLLaunchArgumentOverride() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-relayBaseURL"), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return URL(string: value) != nil ? value : nil
    }

    /// Backs the `-resetCompanionStateForUITests` launch argument. Deletes
    /// any existing owner/approver private key from the Keychain, clears
    /// every companion App Group key this coordinator owns (identities,
    /// paired people, pending acceptances, the friend-approval gate, and
    /// the friend-release use-ID map), and resets every rollback-anchor
    /// checkpoint. Deliberately leaves `relayBaseURLDefaultsKey` alone — the
    /// `-relayBaseURL` override above already governs that independently.
    /// Best-effort: a failure to delete one Keychain item does not stop the
    /// rest of the reset.
    private static func resetCompanionStateForUITests(keyStore: any DeviceKeyStore, sharedDefaults: UserDefaults?,
                                                      anchorStore: (any RollbackAnchorStore)?) {
        guard let sharedDefaults else { return }
        for key in [ownerIdentityDefaultsKey, approverIdentityDefaultsKey] {
            guard let data = sharedDefaults.data(forKey: key),
                  let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) else { continue }
            try? keyStore.deletePrivateKey(for: identity.identityID)
        }
        for key in [ownerIdentityDefaultsKey, approverIdentityDefaultsKey, peopleDefaultsKey,
                    pendingAcceptancesDefaultsKey, storedInvitesDefaultsKey, friendApprovalGateDefaultsKey,
                    useIDsByRequestIDDefaultsKey] {
            sharedDefaults.removeObject(forKey: key)
        }
        try? anchorStore?.resetAll()
    }
    #endif

    // MARK: - Invite / accept / confirm

    /// Claims any `phone-lockbox-companion://...` link for companion
    /// handling (review P2-1): the Quick Action parser must never see one of
    /// these, valid or not, since the two schemes share a host app and a
    /// malformed companion link must not silently fall through to Lockbox
    /// navigation. Returns `true` for every URL with this scheme (so the
    /// caller always switches to the People tab), `false` only when the
    /// scheme doesn't match at all.
    ///
    /// A recognized, decodable `.../invite/...` link
    /// (`Invitation.shareLink`'s format) that has not yet expired sets
    /// `incomingInvite`, which `PeopleView` shows as a top-of-page "You've
    /// been invited" prompt in front of the user (R5 pairing v2 UX fix item
    /// 7) — never silently prefilled into a field below the fold. This
    /// never accepts anything by itself — accepting still requires an
    /// explicit tap on that prompt's Accept button.
    ///
    /// An undecodable payload or an unrecognized host reports the same
    /// companion-specific `lastError` (review P2-2: `AcceptInviteCard`'s
    /// manual "Accept invite" is disabled whenever `decodeInvitation` fails,
    /// which would otherwise leave no feedback at all); an invite that
    /// decodes but has already expired reports a distinct, actionable
    /// message instead of being silently dropped. Neither case, nor the
    /// success case, ever *clears* an existing `lastError` that this call
    /// didn't itself cause — opening a valid link must not paper over an
    /// unrelated companion error already showing (R5 pairing v2 UX fix item
    /// 7).
    @discardableResult
    func handleIncomingCompanionLink(_ url: URL) -> Bool {
        guard url.scheme == Self.companionLinkScheme else { return false }
        guard url.host == "invite", let invitation = decodeInvitation(from: url.absoluteString) else {
            lastError = Self.invalidInviteLinkMessage
            return true
        }
        guard Date() < invitation.payload.expiresAt else {
            lastError = Self.expiredInviteLinkMessage
            return true
        }
        incomingInvite = invitation
        return true
    }

    func createInvite() async {
        guard isAvailable else { return }
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let invitation = try await client.createInvite(inviteID: UUID().uuidString, validFor: 3_600, now: Date())
            pendingInvitation = invitation
            // Stored locally so a later relay-delivered acceptance can be
            // verified against this exact invite (R5 pairing v2 P2b, item
            // 1) — never trusted from the relay/acceptance alone.
            storedInvites[invitation.payload.inviteID] = invitation
            trimStoredInvitesIfNeeded()
            saveStoredInvites()
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Parses a link produced by `Invitation.shareLink`.
    func decodeInvitation(from link: String) -> Invitation? {
        try? Invitation.fromShareLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    #if DEBUG
    /// Test-only seam (owner-review follow-up, P2-9): reads `storedInvites`
    /// directly, without a network round trip through `createInvite()`.
    /// Never used by production code paths — only `PhoneLockboxTests`.
    var storedInvitesForTesting: [String: Invitation] { storedInvites }

    /// Test-only seam: mirrors `createInvite()`'s storage side effects
    /// (insert, trim to `maxStoredInvites`, persist) without any network
    /// call, so `PhoneLockboxTests` can exercise persistence/pruning/
    /// capping directly.
    func insertStoredInviteForTesting(_ invitation: Invitation) {
        storedInvites[invitation.payload.inviteID] = invitation
        trimStoredInvitesIfNeeded()
        saveStoredInvites()
    }

    /// Test-only seam: ensures (creating if necessary) this device's owner
    /// identity, exactly as `createInvite()`/`confirmPendingAcceptance()`
    /// do internally — purely local Keychain + App Group work, no network.
    @discardableResult
    func ensureOwnerIdentityForTesting() throws -> DeviceIdentity {
        try ensureIdentity(role: .owner)
    }

    /// Test-only seam: seeds `people` directly with an already-confirmed
    /// pairing, without any network call — used by `PhoneLockboxTests` to
    /// set up a pairing-ID conflict scenario for
    /// `upsertConfirmedPairing`/P2-10.
    func testOnlySeedConfirmedPairing(_ pairing: Pairing, nickname: String) {
        people.append(CompanionPerson(nickname: nickname, localRole: .iAmOwner, pairing: pairing, consent: nil))
        savePeople()
    }
    #endif

    func acceptInvite(_ invitation: Invitation) async {
        guard isAvailable else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let client = makeClient(signer: try signer(for: identity))
            let acceptanceID = UUID().uuidString
            _ = try await client.accept(invitation, acceptanceID: acceptanceID, now: Date())
            // Persisted so a later inbox-reported pairing can be checked
            // against this exact accept attempt — see `CompanionTrustMerge`
            // and `CompanionPendingAcceptance`. The record is consumed
            // (removed) once its pairing is learned from the inbox, and is
            // also what `hasPendingApproverAcceptance` reads below — unlike
            // a transient in-memory flag, this survives a relaunch and
            // clears itself exactly when the pairing is actually learned
            // (owner-review follow-up, P2-5).
            let record = try CompanionPendingAcceptance(ownerIdentity: invitation.payload.owner, acceptanceID: acceptanceID,
                                                        approverIdentity: identity, createdAt: Date())
            pendingAcceptances.append(record)
            savePendingAcceptances()
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    /// Owner-review follow-up (P2-5): whether this device, acting as
    /// approver, has at least one outstanding "I accepted an invite,
    /// waiting for the owner to confirm" record. Backed by the persisted
    /// `pendingAcceptances` list — survives a relaunch, and clears itself
    /// once the matching pairing is actually learned from the inbox
    /// (`applyInboxSnapshot`'s `.add` case consumes the record) or the
    /// record goes stale (`pruneExpiredPendingAcceptances`, run at launch
    /// and on every `refreshInbox()`). `AcceptInviteCard` uses this instead
    /// of a transient in-memory flag that reset on every relaunch.
    var hasPendingApproverAcceptance: Bool { !pendingAcceptances.isEmpty }

    /// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b", items 2–3):
    /// pure, local binding of relay-delivered acceptances to this device's
    /// own stored invites. Every entry in `signed` is checked with
    /// `OwnerAcceptanceCheck.verify` against `storedInvites[inviteID]` —
    /// never merely against the acceptance's own claimed `inviteID` without
    /// a matching local record, and never against any other device's
    /// invite. Anything that fails verification or has no matching local
    /// invite is silently dropped rather than shown. `internal` (not
    /// `private`) so `PhoneLockboxTests` can exercise this binding directly
    /// without a network round trip.
    static func verifyPendingAcceptances(_ signed: [SignedAcceptance], storedInvites: [String: Invitation],
                                         ownerIdentity: DeviceIdentity, now: Date) -> [VerifiedPendingAcceptance] {
        signed.compactMap { entry in
            guard let invite = storedInvites[entry.acceptance.inviteID] else { return nil }
            guard let code = try? OwnerAcceptanceCheck.verify(signedAcceptance: entry, invite: invite,
                                                              ownerIdentity: ownerIdentity, now: now) else { return nil }
            return VerifiedPendingAcceptance(signedAcceptance: entry, expectedVerificationCode: code)
        }
    }

    /// P1-1 (Opus review of 70c7d27): the exact assignment-time guard
    /// `refreshInbox()` applies to a previously computed
    /// `pendingOwnerAcceptances` candidate list, right before ever
    /// publishing it — re-verifies every entry against the instance's
    /// *current* `storedInvites` (pure, no I/O), so a concurrent "Not
    /// them"/confirm that discarded one of those invites during an earlier
    /// `await` in that same refresh cycle can never be undone by this
    /// assignment resurrecting a card already resolved. `internal` (not
    /// `private`) so `PhoneLockboxTests` can exercise this exact guard
    /// directly, without a network round trip.
    func reverifyPendingOwnerAcceptancesAtAssignmentTime(_ computed: [VerifiedPendingAcceptance],
                                                         ownerIdentity: DeviceIdentity, now: Date) -> [VerifiedPendingAcceptance] {
        Self.verifyPendingAcceptances(computed.map(\.signedAcceptance), storedInvites: storedInvites,
                                      ownerIdentity: ownerIdentity, now: now)
    }

    #if DEBUG
    /// Test-only override for `confirmPendingAcceptance`'s `client.confirm`
    /// call (owner-review follow-up, P2-9) — mirrors `useApprovalOverride`
    /// (R5 Slice B2c). Defaults to the real network round trip. `#if DEBUG`
    /// (second owner-review follow-up): never compiled into a release
    /// build, same reasoning as every other test-only seam in this file.
    var confirmPendingAcceptanceOverride: (@MainActor (_ acceptance: PairingAcceptance, _ verificationCode: String) async throws -> Pairing)?
    #endif

    private func confirmViaRelay(_ acceptance: PairingAcceptance, verificationCode: String) async throws -> Pairing {
        let identity = try ensureIdentity(role: .owner)
        let client = makeClient(signer: try signer(for: identity))
        return try await client.confirm(acceptance, verificationCode: verificationCode, now: Date())
    }

    /// The owner taps **Confirm** on a verified pending-acceptance card,
    /// after optionally naming the person and choosing whether to grant
    /// early-end trust immediately. No code is read or typed — the code
    /// `item` carries is the one this device itself derived while verifying
    /// it (`OwnerAcceptanceCheck`). On success, the invite is discarded
    /// (consumed) and the card removed immediately, without waiting for the
    /// next refresh.
    ///
    /// P1-1 (Opus review of 70c7d27): re-verifies `item` against the
    /// *current* `storedInvites` and `ownerIdentity` before ever contacting
    /// the relay — never trusts the `item` the view was handed, which could
    /// be stale if "Not them" discarded its invite elsewhere (or during an
    /// earlier `await` in this very refresh cycle) between when the card
    /// was shown and this tap. If it no longer verifies, the card is
    /// dropped and nothing is confirmed — never merely a presence check,
    /// the same full `OwnerAcceptanceCheck` the inbox refresh itself runs.
    ///
    /// `grantEarlyEndTrust`, when true (the pending-acceptance card's
    /// default), immediately performs the same owner-side consent grant the
    /// person row's "Can approve early end"/"Receives my requests" toggles
    /// do — both scopes, in one round trip — right after `confirm` succeeds.
    /// This never makes the friend fully trusted by itself: `authorizes`
    /// requires the scope on **both** sides, and the friend still has to
    /// separately accept on their own device (consent stays bilateral; see
    /// `docs/r5-pairing-v2-plan.md`'s P2b follow-up — and the owner-decision
    /// note there that this on-by-default pattern is R5-scopes-only and must
    /// not be reused for R6 status sharing). A failed grant never un-confirms
    /// the pairing — it only surfaces `lastError`, and the per-scope toggles
    /// on the person row remain the fallback path. P2-10: a pairing-ID
    /// conflict (`upsertConfirmedPairing` returning `false`) skips the grant
    /// entirely and leaves `lastError` exactly as that conflict set it —
    /// granting trust for whatever *other* person happens to share the
    /// pairing ID, or silently clearing the conflict warning, would both be
    /// wrong.
    func confirmPendingAcceptance(_ item: VerifiedPendingAcceptance, nickname: String, grantEarlyEndTrust: Bool) async {
        guard isAvailable else { return }
        guard let ownerIdentity,
              let invite = storedInvites[item.acceptance.inviteID],
              (try? OwnerAcceptanceCheck.verify(signedAcceptance: item.signedAcceptance, invite: invite,
                                                ownerIdentity: ownerIdentity, now: Date())) != nil else {
            pendingOwnerAcceptances.removeAll { $0.id == item.id }
            return
        }
        do {
            let pairing: Pairing
            #if DEBUG
            if let confirmPendingAcceptanceOverride {
                pairing = try await confirmPendingAcceptanceOverride(item.acceptance, item.expectedVerificationCode)
            } else {
                pairing = try await confirmViaRelay(item.acceptance, verificationCode: item.expectedVerificationCode)
            }
            #else
            pairing = try await confirmViaRelay(item.acceptance, verificationCode: item.expectedVerificationCode)
            #endif
            let upserted = upsertConfirmedPairing(pairing, nickname: nickname.isEmpty ? nil : nickname)
            discardStoredInvite(inviteID: item.acceptance.inviteID)
            pendingOwnerAcceptances.removeAll { $0.id == item.id }
            guard upserted else { return }
            lastError = nil; needsRepair = false
            if grantEarlyEndTrust {
                await grantOwnerTrustAfterConfirm(pairingID: pairing.pairingID)
            }
        } catch { fail(error) }
    }

    #if DEBUG
    /// Test-only override for `grantOwnerTrustAfterConfirm`'s
    /// `client.grantScopes` call (owner-review follow-up, P2-9). `#if
    /// DEBUG` (second owner-review follow-up): never compiled into a
    /// release build.
    var grantOwnerTrustAfterConfirmOverride: (@MainActor (_ pairing: Pairing, _ scopes: [CompanionScope]) async throws -> RelationshipConsent)?
    #endif

    private func grantScopesViaRelay(pairing: Pairing, scopes: [CompanionScope]) async throws -> RelationshipConsent {
        let identity = try ensureIdentity(role: .owner)
        let client = makeClient(signer: try signer(for: identity))
        return try await client.grantScopes(pairing: pairing, scopes: scopes)
    }

    /// Follow-up to `confirmPendingAcceptance`: grants both owner scopes
    /// (`approveEarlyEnd`, `receiveRequests`) for the just-confirmed pairing
    /// in one round trip. Mirrors `setOwnerGrant`'s shape (read the current
    /// owner scope set, union in what's wanted, resubmit the full set) but
    /// grants both at once rather than one at a time, since this always
    /// runs immediately after a fresh `confirm` with no existing consent to
    /// race against. A failure here is reported through `fail(error)` like
    /// any other action — it never reverts the pairing confirm that already
    /// succeeded, and the person row's own toggles remain available to grant
    /// (or retry) afterward regardless of how this ends.
    private func grantOwnerTrustAfterConfirm(pairingID: String) async {
        guard let person = people.first(where: { $0.pairing.pairingID == pairingID }) else { return }
        do {
            var scopes = Set(person.consent?.ownerScopes ?? [])
            scopes.formUnion([.approveEarlyEnd, .receiveRequests])
            let consent: RelationshipConsent
            #if DEBUG
            if let grantOwnerTrustAfterConfirmOverride {
                consent = try await grantOwnerTrustAfterConfirmOverride(person.pairing, Array(scopes))
            } else {
                consent = try await grantScopesViaRelay(pairing: person.pairing, scopes: Array(scopes))
            }
            #else
            consent = try await grantScopesViaRelay(pairing: person.pairing, scopes: Array(scopes))
            #endif
            applyOwnConsentUpdate(consent, forPairingID: pairingID)
            lastError = nil; needsRepair = false
        } catch {
            fail(error)
        }
    }

    /// The owner taps **Not them**: hides this acceptance locally (removed
    /// immediately, not merely until the next refresh) and discards the
    /// stored invite it answered, so nothing further can ever be confirmed
    /// from it on this device again (see `discardStoredInvite`'s doc
    /// comment for why no relay call is needed). Never contacts the relay —
    /// there is no cancel-invite endpoint in this protocol version to call.
    func dismissPendingAcceptance(_ item: VerifiedPendingAcceptance) {
        pendingOwnerAcceptances.removeAll { $0.id == item.id }
        discardStoredInvite(inviteID: item.acceptance.inviteID)
    }

    /// Only path that may create an `.iAmOwner` person entry — a direct
    /// result of this device's own `confirm()` call (already checked against
    /// the acceptance by `validateConfirmResponse` inside `confirm` itself),
    /// never the inbox. Still never replaces an existing entry whose owner
    /// or approver differs, as a last line of defense against a pairing-ID
    /// collision or a caller bug. Returns `false` on that conflict (P2-10)
    /// so the caller can skip anything that assumes the upsert actually
    /// happened — `confirmPendingAcceptance`'s early-end grant in
    /// particular, which must never land on whatever *other* person happens
    /// to share the conflicting pairing ID.
    @discardableResult
    private func upsertConfirmedPairing(_ pairing: Pairing, nickname: String?) -> Bool {
        if let index = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID }) {
            guard people[index].pairing.owner == pairing.owner, people[index].pairing.approver == pairing.approver else {
                lastError = "The relay returned a pairing that conflicts with one already stored; ignoring it."
                return false
            }
            people[index].pairing = pairing
            if let nickname { people[index].nickname = nickname }
        } else {
            people.append(CompanionPerson(nickname: nickname ?? "Trusted person", localRole: .iAmOwner,
                                          pairing: pairing, consent: nil))
        }
        savePeople()
        return true
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
    ///
    /// `approvalID`, when given, pins selection to that *exact* approval
    /// rather than merely the first one found for `requestID` (R5 Slice B2c
    /// review, R2-5) — required for a foreground replay, which must never
    /// silently substitute a newer approval for the one a pending intent
    /// was actually prepared against.
    static func selectFriendRelease(
        response: InboxResponse,
        requestID: String,
        approvalID: String? = nil,
        people: [CompanionPerson],
        ownerIdentity: DeviceIdentity
    ) throws -> (request: TrustedRequest, approval: Approval, trustedApprover: OwnerApprovalCheck.TrustedApprover) {
        guard let request = response.requests.first(where: { $0.requestID == requestID }) else {
            throw CompanionError.notFound
        }
        let matchedApproval: Approval?
        if let approvalID {
            matchedApproval = response.approvals?.first(where: { $0.requestID == requestID && $0.approvalID == approvalID })
        } else {
            matchedApproval = response.approvals?.first(where: { $0.requestID == requestID })
        }
        guard let approval = matchedApproval else {
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
        if friendReleaseFlight != nil, friendReleaseFlightRequestID != item.request.requestID {
            // R5 Slice B2c review (R2-3): joining another request's
            // in-flight work would silently wait and then surface whatever
            // error that unrelated flight produces. Say so plainly instead
            // of joining — only a flight for this *same* request is worth
            // waiting on.
            lastError = Self.prepareNoOpMessage(.conflictingPendingIntent)
            return
        }
        await runSingleFlightFriendRelease(requestID: item.request.requestID) { [weak self] in
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
            pruneUseIDsByRequestID(presentRequestIDs: Set(response.requests.map(\.requestID)))
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
        guard isAvailable, let pending = coordinator.pendingFriendReleaseIntent, ownerIdentity != nil else { return }
        await runSingleFlightFriendRelease(requestID: pending.requestID) { [weak self] in
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
        pruneUseIDsByRequestID(presentRequestIDs: Set(response.requests.map(\.requestID)))
        // R5 Slice B2c review (P2-2, pinned precisely by R2-5): re-select
        // and re-verify from scratch (never trust the approval cached when
        // this intent was first prepared), pinning selection itself to the
        // *exact* `approvalID` this intent was prepared against — never
        // just the first approval found for the request, which could by
        // then be a newer, different approval. `approver.identityID` is
        // checked too, as defense in depth.
        guard let (request, approval, _) = try? Self.selectFriendRelease(
            response: response, requestID: pending.requestID, approvalID: pending.approvalID,
            people: people, ownerIdentity: ownerIdentity
        ), approval.approver.identityID == pending.approverIdentityID else {
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
    /// releases anything by itself. Refuses while a friend-release flight is
    /// in progress (R5 Slice B2c review, R2-2) — `hasFriendReleaseFlightInFlight`
    /// also disables the Settings button for the same reason, but this guard
    /// keeps the method itself safe even if called directly (for example a
    /// confirmation dialog that was already showing when a flight started).
    func discardPendingFriendRelease(coordinator: any FriendReleaseLifecycle) {
        guard !hasFriendReleaseFlightInFlight else { return }
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
                    // R5 Slice B2c review (P1-1, tightened by R2-1): a
                    // verified `use` followed by `.noMatchingPendingIntent`
                    // most often means a concurrent flight already applied
                    // this exact release (the intent it was keyed on is
                    // already gone). Confirm via the durable released
                    // marker's cause *and* its exact `useID` -- `.usedToEnd`
                    // alone only proves *some* friend approval released this
                    // session, not that it was *this* `useID` -- before
                    // reporting success instead of a confusing "already
                    // ended".
                    if reason == .noMatchingPendingIntent,
                       coordinator.friendReleaseSessionState(sessionID: request.sessionID) == .usedToEnd,
                       coordinator.friendReleaseUseID(forSessionID: request.sessionID) == useID {
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

    #if DEBUG
    /// Submits `use` for the given approval/request/useID using this
    /// device's owner signer. Defaults to the real `AsyncCompanionClient
    /// .useApproval` round trip (built via `makeClient`); overridable only
    /// for tests (R5 Slice B2c review, P1-3) so `finishFriendRelease`'s
    /// branching can be exercised without a network transport. `#if DEBUG`
    /// (owner-review follow-up): never compiled into a release build, same
    /// as every other test-only override in this file.
    var useApprovalOverride: (@MainActor (_ approval: Approval, _ request: TrustedRequest, _ useID: String) async throws -> ApprovalVerification)?
    #endif

    private func submitUse(_ approval: Approval, request: TrustedRequest, useID: String) async throws -> ApprovalVerification {
        #if DEBUG
        if let override = useApprovalOverride {
            return try await override(approval, request, useID)
        }
        #endif
        guard let ownerIdentity else { throw CompanionError.unauthorized }
        let client = makeClient(signer: try signer(for: ownerIdentity))
        return try await client.useApproval(approval, request: request, useID: useID)
    }

    /// Ensures `endLockNow` and the foreground replay never race each other
    /// into two concurrent `use` submissions: only one friend-release flight
    /// runs at a time, and a second caller awaits the one already running
    /// instead of starting its own (R5 Slice B2c review, P1-1). `internal`
    /// (not `private`) so `PhoneLockboxTests` can exercise it directly.
    /// `requestID`, when given, tags the flight this call *starts* (a
    /// caller that instead *joins* an existing flight does not change its
    /// tag) — `endLockNow` reads `friendReleaseFlightRequestID` to tell
    /// "the same request is already in flight" from "a different one is"
    /// (R2-3).
    func runSingleFlightFriendRelease(requestID: String? = nil, _ work: @escaping () async -> Void) async {
        if let inFlight = friendReleaseFlight {
            // R5 Slice B2c review (R2-3/determinism): incremented
            // synchronously, before any suspension point, so a caller
            // waiting on this count (tests) sees it the instant a joiner
            // commits to waiting rather than starting its own flight.
            friendReleaseFlightJoinCount += 1
            await inFlight.value
            return
        }
        friendReleaseFlightRequestID = requestID
        let task = Task { await work() }
        friendReleaseFlight = task
        hasFriendReleaseFlightInFlight = true
        await task.value
        friendReleaseFlight = nil
        friendReleaseFlightRequestID = nil
        hasFriendReleaseFlightInFlight = false
    }

    /// `true` while a friend-release flight (`endLockNow`/the foreground
    /// replay) is running. `@Published` so the Settings "Discard pending
    /// friend release" button can disable itself while one is in flight
    /// (R5 Slice B2c review, R2-2); also used directly by
    /// `PhoneLockboxTests`.
    @Published private(set) var hasFriendReleaseFlightInFlight = false

    /// Test-only: incremented each time a caller joins an already-in-flight
    /// friend-release flight instead of starting its own (R5 Slice B2c
    /// review, determinism fix for the single-flight test).
    private(set) var friendReleaseFlightJoinCount = 0

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
        pruneStoredInvites(now: Date())
        var items: [CompanionInboxItem] = []
        var encounteredError: Error?
        var anyFetchSucceeded = false
        var rejectionCount = 0
        // `nil` until a successful owner-anchored fetch computes it; applied
        // to `pendingOwnerAcceptances` below only then, so a failed fetch
        // leaves the previous (already-verified) cards exactly as they were
        // rather than clearing them. `newPendingOwnerAcceptancesOwnerIdentity`
        // captures the exact owner identity used to compute it, so the P1-1
        // re-verification below never depends on `self.ownerIdentity`
        // possibly having changed in the meantime.
        var newPendingOwnerAcceptances: [VerifiedPendingAcceptance]?
        var newPendingOwnerAcceptancesOwnerIdentity: DeviceIdentity?

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
                pruneUseIDsByRequestID(presentRequestIDs: Set(response.requests.map(\.requestID)))
                // R5 pairing v2 (Slice P2b, item 2): verify every relay-
                // delivered acceptance against this device's own stored
                // invites before it can ever be shown.
                newPendingOwnerAcceptances = Self.verifyPendingAcceptances(
                    response.pendingAcceptances ?? [], storedInvites: storedInvites,
                    ownerIdentity: ownerIdentity, now: Date()
                )
                newPendingOwnerAcceptancesOwnerIdentity = ownerIdentity
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

        // P1-1 (Opus review of 70c7d27): `newPendingOwnerAcceptances` above
        // was computed against a snapshot of `storedInvites` taken before
        // the approver-fetch `await` just above — if a concurrent "Not
        // them"/confirm (a separate `Task`, e.g. a user's tap) discarded one
        // of those invites during that await, assigning the stale list
        // wholesale would resurrect (or keep showing) a card that was
        // already resolved. `reverifyPendingOwnerAcceptancesAtAssignmentTime`
        // closes that window by re-verifying in full against the *current*
        // `storedInvites` — pure and local, no I/O — right before this
        // assignment, rather than merely filtering by invite-ID presence,
        // which would miss a concurrent expiry too.
        if let newPendingOwnerAcceptances, let capturedOwnerIdentity = newPendingOwnerAcceptancesOwnerIdentity {
            pendingOwnerAcceptances = reverifyPendingOwnerAcceptancesAtAssignmentTime(
                newPendingOwnerAcceptances, ownerIdentity: capturedOwnerIdentity, now: Date()
            )
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
