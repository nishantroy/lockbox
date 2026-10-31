import Foundation

#if canImport(CompanionKit)
import CompanionKit

/// A failure on this device before anything is sent to the relay. These must
/// never read as "couldn't reach the relay" (build-22 QA): that message is for
/// transport errors only.
enum CompanionLocalError: Error, Equatable {
    /// The App Group suite (where identities and people are kept) can't be used.
    case storageUnavailable
    /// This device's signing key couldn't be created or saved in the Keychain.
    case identityStorage

    var message: String {
        switch self {
        case .storageUnavailable:
            return "Phone Lockbox couldn't use its storage, so nothing was sent. Quit and reopen the app, then try again."
        case .identityStorage:
            return "Couldn't save this device's secure key, so nothing was sent. Try again; if your phone is locked, unlock it first."
        }
    }
}

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
    /// The name shown for this person. Seeded from the display name carried
    /// by the pairing itself (the friend's name on the owner side, the
    /// owner's name on the friend side); editable locally via `rename`.
    var nickname: String
    var localRole: LocalRole
    var pairing: Pairing
    var consent: RelationshipConsent?
    /// Owner side only. `true` once `JoinedAcceptanceCheck` proved, against an
    /// invite this device issued, that the relay-reported pairing came from
    /// the holder of the link (pairing v3). A person that is not verified is
    /// never shown as trusted, never asked, and never has an approval
    /// accepted from them. Pairings stored by an earlier build decode as
    /// `false` (they have no acceptance to verify; the owner re-invites).
    var joinVerified: Bool

    init(nickname: String, localRole: LocalRole, pairing: Pairing, consent: RelationshipConsent?, joinVerified: Bool = false) {
        self.nickname = nickname; self.localRole = localRole; self.pairing = pairing
        self.consent = consent; self.joinVerified = joinVerified
    }

    private enum CodingKeys: String, CodingKey { case nickname, localRole, pairing, consent, joinVerified }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nickname = try c.decode(String.self, forKey: .nickname)
        localRole = try c.decode(LocalRole.self, forKey: .localRole)
        pairing = try c.decode(Pairing.self, forKey: .pairing)
        consent = try c.decodeIfPresent(RelationshipConsent.self, forKey: .consent)
        joinVerified = try c.decodeIfPresent(Bool.self, forKey: .joinVerified) ?? false
    }

    /// The counterpart's own name as carried by the pairing, with a plain
    /// fallback only for pairings made before names existed.
    static func defaultName(for pairing: Pairing, role: LocalRole) -> String {
        switch role {
        case .iAmOwner: return pairing.approverDisplayName ?? "Unnamed person"
        case .iAmApprover: return pairing.ownerDisplayName ?? "Someone"
        }
    }

    /// The other side's identity (the friend for an owner, the owner for a friend).
    var counterpartIdentityID: String {
        localRole == .iAmOwner ? pairing.approver.identityID : pairing.owner.identityID
    }

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

    /// Friend side: the consent record exists and this person has withdrawn
    /// their own side (they used "Stop being a trusted person").
    var approverStoppedHelping: Bool {
        localRole == .iAmApprover && consent != nil && !hasAcceptedApproveEarlyEnd && !hasAcceptedReceiveRequests
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

/// Friend side: the invite link this device opened, as the People tab shows it.
struct IncomingInvite {
    let invitation: Invitation
    /// The link token. Needed by the accept proof; held in memory only.
    let token: String
    /// The inviter's name as signed into the invite, if they set one.
    var ownerName: String { invitation.payload.ownerDisplayName ?? "Someone" }
}

/// Friend side: where an opened invite link is in the "look up, then Accept"
/// flow. There is no waiting state after Accept; the pairing is active the
/// moment the relay answers.
enum IncomingInviteState {
    case none
    case loading
    case ready(IncomingInvite)
    /// Calm, final message (expired, already used, not valid, rate limited).
    case failed(String)
}

/// Owner side: a one-time "‹Name› joined" notice, kept until dismissed.
struct JoinedNotice: Identifiable, Equatable {
    let id: String   // pairing ID
    let name: String
}

/// Friend side: a one-time "You're now a trusted person for ‹Name›" notice,
/// kept until dismissed.
struct AcceptedNotice: Identifiable, Equatable {
    let id: String   // pairing ID
    let ownerName: String
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
    /// Keys abandoned by pairing v3 (pending acceptances and plain stored
    /// invites). Removed on launch; the invite secret now lives in the Keychain.
    private static let legacyDefaultsKeys = ["com.phone-lockbox.companion.pendingAcceptances.v1",
                                             "com.phone-lockbox.companion.storedInvites.v1"]
    /// The one stored name (P3d): used on the owner's invites and on the
    /// friend's acceptances.
    private static let displayNameDefaultsKey = "com.phone-lockbox.companion.displayName.v1"
    /// Pre-P3d separate names, migrated into `displayNameDefaultsKey` (owner name first).
    private static let ownerDisplayNameDefaultsKey = "com.phone-lockbox.companion.ownerDisplayName.v1"
    private static let approverDisplayNameDefaultsKey = "com.phone-lockbox.companion.approverDisplayName.v1"
    private static let seenJoinedDefaultsKey = "com.phone-lockbox.companion.joinedSeen.v1"
    private static let seenAcceptedDefaultsKey = "com.phone-lockbox.companion.acceptedSeen.v1"
    /// Invite links stay valid for an hour.
    static let inviteLifetime: TimeInterval = 3_600
    /// An unused invite is kept this long after it expires (the relay purges
    /// its token rows after 30 days), so a late acceptance can still verify.
    private static let inviteRetentionAfterExpiry: TimeInterval = 30 * 24 * 3_600
    private static let maxUnmatchedInvites = 20
    private static let ownerIdentityDefaultsKey = "com.phone-lockbox.companion.identity.owner.v1"
    private static let approverIdentityDefaultsKey = "com.phone-lockbox.companion.identity.approver.v1"
    private static let relayBaseURLDefaultsKey = "com.phone-lockbox.companion.relayBaseURL.v1"
    static let defaultRelayBaseURLString = "https://relay.example.com"
    /// Builds 16–17 defaulted to the local development relay. A stored value
    /// equal to it is treated as "never customised" and follows the default.
    static let legacyLocalRelayBaseURLString = "http://127.0.0.1:8002"
    /// Scheme for `InviteToken.shareLink(token:)` (registered in
    /// `project.yml`'s `CFBundleURLTypes` alongside `phonelockbox`).
    static let companionLinkScheme = "phone-lockbox-companion"
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
    /// Owner side: the invite just created, whose link the owner shares.
    /// Held in memory (and in the Keychain via `issuedInvites`); never log it.
    @Published private(set) var pendingInvite: IssuedInvite?
    /// Friend side: the invite link this device opened (see `IncomingInviteState`).
    @Published var incomingInvite: IncomingInviteState = .none
    /// The user's own name, shown to trusted people on invites and requests.
    @Published private(set) var displayName = ""
    /// Calm notice when the relay reported something the owner device could not verify.
    @Published private(set) var integrityNotice: String?
    @Published private(set) var joinedNotices: [JoinedNotice] = []
    @Published private(set) var acceptedNotices: [AcceptedNotice] = []
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
    /// Single-flight inbox refresh (see `refreshInbox`).
    private var refreshFlight: Task<Void, Never>?
    private var refreshNeedsAnotherPass = false
    private var inviteLookupTask: Task<Void, Never>?
    private let inviteStore: any IssuedInviteStore
    private var seenJoinedPairingIDs: Set<String> = []
    private var seenAcceptedPairingIDs: Set<String> = []
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
        inviteStore: (any IssuedInviteStore)? = nil,
        makeSession: @escaping @Sendable () -> URLSession = { URLSession(configuration: .ephemeral) }) {
        // An injected key store means a test: never touch the real Keychain then.
        self.inviteStore = inviteStore ?? (keyStore == nil ? KeychainIssuedInviteStore() : InMemoryIssuedInviteStore())
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
            Self.resetCompanionStateForUITests(keyStore: self.keyStore, sharedDefaults: resolvedDefaults, anchorStore: self.anchorStore,
                                               inviteStore: self.inviteStore)
        }
        #endif
        if resolvedDefaults != nil {
            loadIdentities()
            loadPeople()
            for key in Self.legacyDefaultsKeys { resolvedDefaults?.removeObject(forKey: key) }
            displayName = Self.migratedDisplayName(in: resolvedDefaults)
            if let data = resolvedDefaults?.data(forKey: Self.seenJoinedDefaultsKey),
               let ids = try? JSONDecoder().decode([String].self, from: data) { seenJoinedPairingIDs = Set(ids) }
            if let data = resolvedDefaults?.data(forKey: Self.seenAcceptedDefaultsKey),
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                seenAcceptedPairingIDs = Set(ids)
            } else {
                // First launch with accepted notices: pairings made before
                // this existed are not "new", so none of them shows a notice.
                seenAcceptedPairingIDs = Set(people.filter { $0.localRole == .iAmApprover }.map(\.id))
                saveSeenAcceptedPairingIDs()
            }
            loadIssuedInvites()
            // Stale secrets from a previous owner identity serve no purpose.
            if ownerIdentity == nil, !inviteStoreFailed, !issuedInvites.isEmpty {
                issuedInvites = [:]
                self.inviteStore.removeAll()
            }
            discardInvitesOfRemovedPeople()
            pruneIssuedInvites(now: Date())
            restorePendingInvite()
            recomputeJoinedNotices()
                        loadUseIDsByRequestID()
        }
    }

    // MARK: - Identity and persistence

    /// Every invite this device issued (invitation and token), keyed by
    /// `inviteID`, persisted in the Keychain through `inviteStore`.
    private var issuedInvites: [String: IssuedInvite] = [:]

    private func loadIdentities() {
        ownerIdentity = decodedIdentity(forKey: Self.ownerIdentityDefaultsKey)
        approverIdentity = decodedIdentity(forKey: Self.approverIdentityDefaultsKey)
    }

    private func decodedIdentity(forKey key: String) -> DeviceIdentity? {
        guard let sharedDefaults, let data = sharedDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
    }

    private func ensureIdentity(role: CompanionRole) throws -> DeviceIdentity {
        guard let sharedDefaults else { throw CompanionLocalError.storageUnavailable }
        let key = role == .owner ? Self.ownerIdentityDefaultsKey : Self.approverIdentityDefaultsKey
        if let existing = decodedIdentity(forKey: key) {
            // A missing private key is a repair state, not silently
            // regenerated. Surface it as an error from the caller's signer
            // construction rather than minting a new identity here.
            return existing
        }
        let manager = IdentityManager(keyStore: keyStore)
        let stored: StoredIdentity
        do { stored = try manager.create(role: role) } catch { throw CompanionLocalError.identityStorage }
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

    /// How the last read of the invite store went. While it is anything but
    /// `.readable`, nothing is written to the store and owner-side people keep
    /// whatever verified state they already had.
    enum InviteStoreStatus: Equatable {
        case readable
        /// Keychain locked (`errSecInteractionNotAllowed`): resolves after unlocking.
        case locked
        /// Another read error, usually transient.
        case unavailable
        /// The item no longer decodes: needs `resetUnreadableInviteStore()`.
        case corrupt
    }
    @Published private(set) var inviteStoreStatus: InviteStoreStatus = .readable
    var inviteStoreFailed: Bool { inviteStoreStatus != .readable }
    /// Owner side: the saved invites are damaged and offer a reset instead of a retry.
    var inviteStoreIsCorrupt: Bool { inviteStoreStatus == .corrupt }

    static let inviteStoreReadFailedMessage =
        "Couldn't read this device's saved invites just now. Your trusted people are unchanged; try again after unlocking your phone."
    static let inviteStoreUnavailableMessage =
        "Couldn't read this device's saved invites just now. Your trusted people are unchanged; try again in a moment."
    static let inviteStoreCorruptMessage =
        "Saved invites on this phone are damaged. Reset them to create new invites."

    /// The calm message for the current unreadable state (`nil` while readable
    /// and for `.corrupt`, which has its own card with the reset action).
    var inviteStoreProblemMessage: String? {
        switch inviteStoreStatus {
        case .readable, .corrupt: return nil
        case .locked: return Self.inviteStoreReadFailedMessage
        case .unavailable: return Self.inviteStoreUnavailableMessage
        }
    }

    private func loadIssuedInvites() {
        switch inviteStore.load() {
        case .found(let invites): issuedInvites = invites; inviteStoreStatus = .readable
        case .notFound: issuedInvites = [:]; inviteStoreStatus = .readable
        case .locked: issuedInvites = [:]; inviteStoreStatus = .locked
        case .failed: issuedInvites = [:]; inviteStoreStatus = .unavailable
        case .corrupt: issuedInvites = [:]; inviteStoreStatus = .corrupt
        }
        // The notice came from checking against invites that can't be read now; it is
        // recomputed from the next snapshot once they can.
        if inviteStoreFailed { integrityNotice = nil }
    }

    /// Retries a failed read. On success, restores what a successful read
    /// would have shown and finishes any removal that had to wait for it.
    private func retryInviteStoreReadIfNeeded() {
        guard inviteStoreFailed else { return }
        reloadInviteStore()
    }

    private func reloadInviteStore() {
        loadIssuedInvites()
        guard !inviteStoreFailed else { return }
        discardInvitesOfRemovedPeople()
        restorePendingInvite()
    }

    /// The recovery route for a damaged invite item: clears it. Only allowed
    /// while the item really is corrupt, so a locked phone can never lead to
    /// deleting good data.
    func resetUnreadableInviteStore() {
        guard inviteStoreStatus == .corrupt else { return }
        inviteStore.removeAll()
        issuedInvites = [:]
        inviteStoreStatus = .readable
        pendingInvite = nil
        lastError = nil
    }

    /// Never writes while the store is unreadable (it could overwrite the real item).
    @discardableResult
    private func saveIssuedInvites() -> Bool {
        guard !inviteStoreFailed else { return false }
        return inviteStore.save(issuedInvites)
    }

    /// Shows the newest unexpired, never-used invite's link again (after a
    /// relaunch, or once an unreadable store reads again). An invite that
    /// created a person, including one since removed, is consumed on the relay
    /// and is never offered again.
    private func restorePendingInvite() {
        guard pendingInvite == nil else { return }
        let now = Date()
        pendingInvite = issuedInvites.values
            .filter { now < $0.invitation.payload.expiresAt && !inviteCreatedAnyPerson($0) }
            .max { $0.invitation.payload.issuedAt < $1.invitation.payload.issuedAt }
    }

    /// Whether any owner-side person, active or since removed, came from this invite.
    private func inviteCreatedAnyPerson(_ issued: IssuedInvite) -> Bool {
        let inviteID = issued.invitation.payload.inviteID
        return people.contains {
            $0.localRole == .iAmOwner
                && Pairing.derivedID(inviteID: inviteID, approverIdentityID: $0.pairing.approver.identityID) == $0.pairing.pairingID
        }
    }

    /// Deletes the stored invites of every removed (revoked) owner-side person.
    /// Removal while the store was unreadable could not delete the token then;
    /// the revoked person stays in `people`, so this finishes the job after any
    /// successful read, including after a relaunch.
    private func discardInvitesOfRemovedPeople() {
        guard !inviteStoreFailed else { return }
        let before = issuedInvites.count
        for person in people where person.localRole == .iAmOwner && person.pairing.state == .revoked {
            for (id, issued) in issuedInvites where
                Pairing.derivedID(inviteID: issued.invitation.payload.inviteID, approverIdentityID: person.pairing.approver.identityID) == person.pairing.pairingID {
                issuedInvites.removeValue(forKey: id)
            }
        }
        if issuedInvites.count != before { saveIssuedInvites() }
        if let pendingInvite, issuedInvites[pendingInvite.invitation.payload.inviteID] == nil { self.pendingInvite = nil }
    }

    private func saveSeenAcceptedPairingIDs() {
        guard let sharedDefaults, let data = try? JSONEncoder().encode(seenAcceptedPairingIDs.sorted()) else { return }
        sharedDefaults.set(data, forKey: Self.seenAcceptedDefaultsKey)
    }

    private func saveSeenJoinedPairingIDs() {
        guard let sharedDefaults, let data = try? JSONEncoder().encode(seenJoinedPairingIDs.sorted()) else { return }
        sharedDefaults.set(data, forKey: Self.seenJoinedDefaultsKey)
    }

    /// Whether an active owner-side person was created by this invite
    /// (their pairing ID derives from this invite ID and their identity).
    private func inviteHasPerson(_ issued: IssuedInvite) -> Bool {
        let inviteID = issued.invitation.payload.inviteID
        return people.contains {
            $0.localRole == .iAmOwner && $0.pairing.state == .active
                && Pairing.derivedID(inviteID: inviteID, approverIdentityID: $0.pairing.approver.identityID) == $0.pairing.pairingID
        }
    }

    /// Keeps an invite for as long as a person created by it exists (the
    /// owner check needs it every fetch); drops unused invites a retention
    /// window after they expire, and caps how many unused ones are kept.
    private func pruneIssuedInvites(now: Date) {
        guard !inviteStoreFailed else { return }
        let before = issuedInvites.count
        var unmatched: [IssuedInvite] = []
        for (id, issued) in issuedInvites where !inviteHasPerson(issued) {
            if now > issued.invitation.payload.expiresAt.addingTimeInterval(Self.inviteRetentionAfterExpiry) {
                issuedInvites.removeValue(forKey: id)
            } else {
                unmatched.append(issued)
            }
        }
        if unmatched.count > Self.maxUnmatchedInvites {
            let oldest = unmatched.sorted { $0.invitation.payload.issuedAt < $1.invitation.payload.issuedAt }
            for issued in oldest.prefix(unmatched.count - Self.maxUnmatchedInvites) {
                issuedInvites.removeValue(forKey: issued.invitation.payload.inviteID)
            }
        }
        if issuedInvites.count != before { saveIssuedInvites() }
    }

    /// Deletes the invite(s) that created `pairing` (call when the person is removed).
    private func discardIssuedInvites(for pairing: Pairing) {
        for (id, issued) in issuedInvites where
            Pairing.derivedID(inviteID: issued.invitation.payload.inviteID, approverIdentityID: pairing.approver.identityID) == pairing.pairingID {
            issuedInvites.removeValue(forKey: id)
        }
        saveIssuedInvites()
        if let pendingInvite, issuedInvites[pendingInvite.invitation.payload.inviteID] == nil { self.pendingInvite = nil }
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

    private func makeClient(signer: DeviceSigner, now: @escaping @Sendable () -> Date = Date.init) -> AsyncCompanionClient {
        let baseURL = URL(string: relayBaseURLString) ?? URL(string: Self.defaultRelayBaseURLString)!
        let transport = HTTPCompanionTransport(baseURL: baseURL, session: makeSession(), anchorStore: anchorStore,
                                               enforceStateRoot: true)
        return AsyncCompanionClient(signer: signer, transport: transport, now: now)
    }

    private func signer(for identity: DeviceIdentity) throws -> DeviceSigner {
        try DeviceSigner(identity: identity, keyStore: keyStore)
    }

    private func fail(_ error: Error) {
        // A cancelled caller is not a relay failure and must never raise a
        // banner (see `refreshInbox`).
        if error is CancellationError {
            #if DEBUG
            print("[CompanionCoordinator] fail ignored (cancelled): \(String(reflecting: error))")
            #endif
            return
        }
        needsRepair = Self.isKeyUnavailable(error)
        lastError = Self.describe(error)
        #if DEBUG
        // P3-0: the user-facing banner collapses many distinct failures
        // (local validation, anchor/integrity checks, relay rejections) into
        // a few strings. This names the exact underlying error. Error cases
        // carry only codes/short detail strings -- never keys, signatures or
        // nonces.
        print("[CompanionCoordinator] fail: \(String(reflecting: error)) -> \"\(lastError ?? "")\"")
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

    static func describe(_ error: Error) -> String {
        switch error {
        case let local as CompanionLocalError:
            return local.message
        case CompanionTransportError.unavailable, CompanionTransportError.timedOut:
            return "Couldn't connect. Check your internet connection and try again."
        case CompanionTransportError.malformedResponse:
            return "Got a response this version can't read. Try again later."
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
        case .revokedPairing: return "That pairing has been revoked."
        case .rateLimited: return "Too many attempts. Wait a moment and try again."
        case .consentRequired: return "That person can't approve early ends right now."
        case .malformed(let detail) where detail.localizedCaseInsensitiveContains("state root")
            || detail.localizedCaseInsensitiveContains("owner identity")
            || detail.localizedCaseInsensitiveContains("anchor"):
            return "The server's response failed an integrity check (\(detail)). Treating this as untrusted; nothing was changed here."
        // R5 Slice B2c: both are integrity-fatal (`AsyncCompanionClient.UseFailureDisposition`)
        // and never retried or abandoned automatically — see `finishFriendRelease`.
        case .relayRollback:
            return "This device's own record of the server disagrees with what it just reported. Nothing was changed; this needs attention before trying again."
        case .responseVerificationFailed:
            return "The server's response to that action failed a local safety check. Nothing was changed; this needs attention before trying again."
        default: return "That didn't go through. Try again."
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
    /// paired people, the friend-approval gate, and
    /// the friend-release use-ID map), and resets every rollback-anchor
    /// checkpoint. Deliberately leaves `relayBaseURLDefaultsKey` alone — the
    /// `-relayBaseURL` override above already governs that independently.
    /// Best-effort: a failure to delete one Keychain item does not stop the
    /// rest of the reset.
    private static func resetCompanionStateForUITests(keyStore: any DeviceKeyStore, sharedDefaults: UserDefaults?,
                                                      anchorStore: (any RollbackAnchorStore)?, inviteStore: any IssuedInviteStore) {
        inviteStore.removeAll()
        guard let sharedDefaults else { return }
        for key in [ownerIdentityDefaultsKey, approverIdentityDefaultsKey] {
            guard let data = sharedDefaults.data(forKey: key),
                  let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) else { continue }
            try? keyStore.deletePrivateKey(for: identity.identityID)
        }
        for key in [ownerIdentityDefaultsKey, approverIdentityDefaultsKey, peopleDefaultsKey,
                    displayNameDefaultsKey, ownerDisplayNameDefaultsKey, approverDisplayNameDefaultsKey,
                    seenJoinedDefaultsKey, seenAcceptedDefaultsKey,
                    friendApprovalGateDefaultsKey, useIDsByRequestIDDefaultsKey] + legacyDefaultsKeys {
            sharedDefaults.removeObject(forKey: key)
        }
        try? anchorStore?.resetAll()
    }
    #endif

    #if DEBUG
    /// Test-only: replaces the relay `createInvite` call (inviteID, ownerName).
    var issueInviteOverride: (@MainActor (_ inviteID: String, _ ownerName: String) async throws -> IssuedInvite)?
    /// Test-only: replaces the owner-side relay `revoke` call.
    var revokePairingOverride: (@MainActor (_ pairing: Pairing) async throws -> Void)?
    /// Test-only: replaces the friend-side `revokeScopes` call.
    var revokeScopesOverride: (@MainActor (_ pairing: Pairing, _ scopes: [CompanionScope]) async throws -> RelationshipConsent)?
    /// Test-only seams (never compiled into release): inspect/seed state without a relay round trip.
    var issuedInvitesForTesting: [String: IssuedInvite] { issuedInvites }
    /// Seeds an invite as if it had just been issued. Does not prune: a test
    /// seeding an old invite (issued in the past) must be able to attach its
    /// person first; launch/refresh pruning is tested separately.
    func insertIssuedInviteForTesting(_ issued: IssuedInvite) {
        issuedInvites[issued.invitation.payload.inviteID] = issued
        saveIssuedInvites()
    }
    /// Re-reads the invite store (as a refresh would) and reports what happened.
    func reloadInviteStoreForTesting() { reloadInviteStore() }
    /// Seeds the Inbox without a relay round trip.
    func setInboxItemsForTesting(_ items: [CompanionInboxItem]) { inboxItems = items }
    func restorePendingInviteForTesting() { restorePendingInvite() }
    @discardableResult
    func ensureOwnerIdentityForTesting() throws -> DeviceIdentity { try ensureIdentity(role: .owner) }
    @discardableResult
    func ensureApproverIdentityForTesting() throws -> DeviceIdentity { try ensureIdentity(role: .trustedApprover) }
    func testOnlySeedPerson(_ pairing: Pairing, nickname: String, role: CompanionPerson.LocalRole,
                            consent: RelationshipConsent? = nil, joinVerified: Bool) {
        people.append(CompanionPerson(nickname: nickname, localRole: role, pairing: pairing, consent: consent, joinVerified: joinVerified))
        savePeople()
        recomputeJoinedNotices()
    }
    #endif

    // MARK: - Display names

    /// Trims and validates a display name with the protocol's own rules
    /// (`PairingFields.validateDisplayName`: 1...40 Unicode scalars, no
    /// control/bidi/invisible-only text). `nil` when it would be rejected.
    static func validatedDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? PairingFields.validateDisplayName(trimmed, name: "display name")) != nil else { return nil }
        return trimmed
    }

    /// The one stored name. Reads `displayNameDefaultsKey`; when it is not
    /// set yet, migrates the pre-P3d owner name, then the approver name, and
    /// removes the old keys.
    private static func migratedDisplayName(in defaults: UserDefaults?) -> String {
        guard let defaults else { return "" }
        defer {
            defaults.removeObject(forKey: ownerDisplayNameDefaultsKey)
            defaults.removeObject(forKey: approverDisplayNameDefaultsKey)
        }
        if let stored = defaults.string(forKey: displayNameDefaultsKey), let name = validatedDisplayName(stored) { return name }
        for key in [ownerDisplayNameDefaultsKey, approverDisplayNameDefaultsKey] {
            if let old = defaults.string(forKey: key), let name = validatedDisplayName(old) {
                defaults.set(name, forKey: displayNameDefaultsKey)
                return name
            }
        }
        return ""
    }

    /// The user's name: asked once (on the first Create or Accept) and
    /// editable in Settings. It is signed into each new invite and sent with
    /// each acceptance; invites already created keep the name they had.
    @discardableResult
    func setDisplayName(_ raw: String) -> Bool {
        guard let name = Self.validatedDisplayName(raw) else { return false }
        displayName = name
        sharedDefaults?.set(name, forKey: Self.displayNameDefaultsKey)
        return true
    }

    // MARK: - Invite (owner)

    func createInvite() async {
        guard isAvailable else { return }
        guard !displayName.isEmpty else {
            lastError = "Add your name so they know the invite is from you."
            return
        }
        retryInviteStoreReadIfNeeded()
        guard !inviteStoreFailed else {
            // A damaged store has its own card with the reset action.
            lastError = inviteStoreProblemMessage
            return
        }
        do {
            let identity = try ensureIdentity(role: .owner)
            let issued: IssuedInvite
            #if DEBUG
            if let issueInviteOverride {
                issued = try await issueInviteOverride(UUID().uuidString, displayName)
            } else {
                let client = makeClient(signer: try signer(for: identity))
                issued = try await client.createInvite(inviteID: UUID().uuidString, validFor: Self.inviteLifetime, now: Date(),
                                                       ownerDisplayName: displayName)
            }
            #else
            let client = makeClient(signer: try signer(for: identity))
            issued = try await client.createInvite(inviteID: UUID().uuidString, validFor: Self.inviteLifetime, now: Date(),
                                                   ownerDisplayName: displayName)
            #endif
            // Kept (token included, in the Keychain) for as long as the
            // pairing it creates exists: `JoinedAcceptanceCheck` needs it on
            // every inbox fetch to prove who joined.
            issuedInvites[issued.invitation.payload.inviteID] = issued
            pruneIssuedInvites(now: Date())
            // The link is shown only once it is safely stored; otherwise a
            // pairing could never be verified later.
            guard saveIssuedInvites() else {
                issuedInvites.removeValue(forKey: issued.invitation.payload.inviteID)
                lastError = "Couldn't save the invite securely on this device, so it wasn't shown. Try again."
                return
            }
            pendingInvite = issued
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    // MARK: - Joined notices (owner)

    /// Dismisses one "‹Name› joined" notice for good (tracked locally by pairing ID).
    func dismissJoinedNotice(id: String) {
        seenJoinedPairingIDs.insert(id)
        saveSeenJoinedPairingIDs()
        recomputeJoinedNotices()
    }

    private func recomputeJoinedNotices() {
        var newestByPerson: [String: CompanionPerson] = [:]
        for person in people where person.localRole == .iAmOwner && person.joinVerified
            && person.pairing.state == .active && !seenJoinedPairingIDs.contains(person.id) {
            if let existing = newestByPerson[person.counterpartIdentityID], existing.pairing.createdAt >= person.pairing.createdAt { continue }
            newestByPerson[person.counterpartIdentityID] = person
        }
        let updated = newestByPerson.values.sorted { $0.pairing.createdAt < $1.pairing.createdAt }
            .map { JoinedNotice(id: $0.id, name: $0.nickname) }
        if updated != joinedNotices { joinedNotices = updated }
        recomputeAcceptedNotices()
    }

    /// Dismisses one friend-side "You're now a trusted person" notice for good.
    func dismissAcceptedNotice(id: String) {
        seenAcceptedPairingIDs.insert(id)
        saveSeenAcceptedPairingIDs()
        recomputeAcceptedNotices()
    }

    private func recomputeAcceptedNotices() {
        var newestByOwner: [String: CompanionPerson] = [:]
        for person in people where person.localRole == .iAmApprover && person.pairing.state == .active
            && !person.approverStoppedHelping && !seenAcceptedPairingIDs.contains(person.id) {
            if let existing = newestByOwner[person.counterpartIdentityID], existing.pairing.createdAt >= person.pairing.createdAt { continue }
            newestByOwner[person.counterpartIdentityID] = person
        }
        let updated = newestByOwner.values.sorted { $0.pairing.createdAt < $1.pairing.createdAt }
            .map { AcceptedNotice(id: $0.id, ownerName: $0.nickname) }
        if updated != acceptedNotices { acceptedNotices = updated }
    }

    // MARK: - Incoming invite (friend): look up, then Accept

    /// Message for a link that is not a companion invite link at all.
    static let invalidInviteLinkMessage = "This invite link isn't valid."

    /// Claims any `phone-lockbox-companion://...` link for companion
    /// handling (the Quick Action parser must never see one of these, valid
    /// or not). Returns `true` for every URL with this scheme (so the caller
    /// always switches to the People tab), `false` only when the scheme
    /// doesn't match. A well-formed `.../i/<token>` link starts the invite
    /// lookup; opening a link never accepts anything by itself.
    @discardableResult
    func handleIncomingCompanionLink(_ url: URL) -> Bool {
        guard url.scheme == Self.companionLinkScheme else { return false }
        openInviteLink(url.absoluteString)
        return true
    }

    /// Starts the lookup for a pasted or opened invite link.
    @discardableResult
    func openInviteLink(_ link: String) -> Task<Void, Never>? {
        guard isAvailable else { incomingInvite = .failed(Self.appGroupUnavailableMessage); return nil }
        guard let token = InviteToken.token(fromShareLink: link) else {
            incomingInvite = .failed(Self.invalidInviteLinkMessage)
            return nil
        }
        incomingInvite = .loading
        inviteLookupTask?.cancel()
        let task = Task { [weak self] in if let self { await self.lookUpInvite(token: token) } }
        inviteLookupTask = task
        return task
    }

    #if DEBUG
    /// Test-only: replaces the relay lookup (same style as `useApprovalOverride`).
    var inviteLookupOverride: (@MainActor (_ token: String) async throws -> Invitation)?
    /// Test-only: replaces the relay accept call.
    var acceptInviteOverride: (@MainActor (_ invitation: Invitation, _ token: String, _ name: String) async throws -> Pairing)?
    #endif

    private func lookupViaRelay(token: String) async throws -> Invitation {
        // Lookup is unauthenticated: an ephemeral in-memory signer keeps this
        // device from minting a persistent friend identity until Accept.
        let ephemeral = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let client = makeClient(signer: ephemeral)
        return try await client.lookupInvite(token: token)
    }

    /// Looks the token up on the relay and verifies it (owner signature, still
    /// live, bound to this exact token; `Invitation.validate(at:matchingToken:)`).
    /// Any failure becomes a calm, final message on `incomingInvite`.
    func lookUpInvite(token: String) async {
        do {
            let invitation: Invitation
            #if DEBUG
            if let inviteLookupOverride {
                invitation = try await inviteLookupOverride(token)
            } else {
                invitation = try await lookupViaRelay(token: token)
            }
            #else
            invitation = try await lookupViaRelay(token: token)
            #endif
            try invitation.validate(at: Date(), matchingToken: token)
            guard !Task.isCancelled else { return }
            if let ownerIdentity, invitation.payload.owner == ownerIdentity {
                incomingInvite = .failed("This is your own invite link. Send it to the person you want to invite.")
                return
            }
            incomingInvite = .ready(IncomingInvite(invitation: invitation, token: token))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            incomingInvite = .failed(Self.describeInviteError(error))
        }
    }

    func dismissIncomingInvite() {
        inviteLookupTask?.cancel()
        incomingInvite = .none
    }

    /// Calm copy for an invite that can't be used. `not_found` covers both
    /// "already used" and "no such link" by design (no enumeration signal).
    static func describeInviteError(_ error: Error) -> String {
        var inner: CompanionError?
        switch error {
        case let direct as CompanionError: inner = direct
        case CompanionTransportError.server(let server): inner = server
        case CompanionTransportError.unavailable, CompanionTransportError.timedOut:
            return "Couldn't connect. Check your internet connection, then open the link again."
        default: break
        }
        switch inner {
        case .some(.notFound), .some(.replay):
            return "This invite was already used or has expired. Ask for a new link."
        case .some(.expired):
            return "This invite has expired. Ask for a new link."
        case .some(.rateLimited):
            return "Too many tries just now. Wait a minute, then open the link again."
        case .some(.malformed), .some(.invalidSignature), .some(.unauthorized):
            return invalidInviteLinkMessage
        default:
            return describe(error)
        }
    }

    /// Accept is the friend's one tap: it consents to both scopes, and the
    /// relay activates the pairing right away. The returned `Pairing` is
    /// stored directly; there is no waiting state and nothing for the owner
    /// to approve. Returns `true` on success.
    @discardableResult
    func acceptIncomingInvite(_ incoming: IncomingInvite, name: String) async -> Bool {
        guard isAvailable else { return false }
        guard let displayName = Self.validatedDisplayName(name) else {
            lastError = "Add your name so \(incoming.ownerName) knows it's you."
            return false
        }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let pairing: Pairing
            #if DEBUG
            if let acceptInviteOverride {
                pairing = try await acceptInviteOverride(incoming.invitation, incoming.token, displayName)
            } else {
                let client = makeClient(signer: try signer(for: identity))
                pairing = try await client.acceptInvite(incoming.invitation, token: incoming.token, approverDisplayName: displayName,
                                                        acceptanceID: UUID().uuidString, now: Date())
            }
            #else
            let client = makeClient(signer: try signer(for: identity))
            pairing = try await client.acceptInvite(incoming.invitation, token: incoming.token, approverDisplayName: displayName,
                                                        acceptanceID: UUID().uuidString, now: Date())
            #endif
            guard pairing.approver == identity, pairing.owner == incoming.invitation.payload.owner else {
                lastError = "The server returned a pairing that doesn't match this invite; ignoring it."
                return false
            }
            guard upsertAcceptedPairing(pairing) else { return false }
            setDisplayName(displayName)
            incomingInvite = .none
            lastError = nil; needsRepair = false
            return true
        } catch {
            if Self.keepsInviteOpen(after: error) {
                fail(error)
            } else {
                incomingInvite = .failed(Self.describeInviteError(error))
            }
            return false
        }
    }

    /// Transient problems (network, rate limit, cancelled) keep the invite
    /// on screen so the friend can just tap Accept again; anything final
    /// (used, expired, not found) replaces it with a clear message.
    private static func keepsInviteOpen(after error: Error) -> Bool {
        switch error {
        case CompanionTransportError.unavailable, CompanionTransportError.timedOut, is CancellationError: return true
        case CompanionError.rateLimited, CompanionTransportError.server(.rateLimited): return true
        case CompanionError.keyUnavailable, CompanionTransportError.server(.keyUnavailable): return true
        case CompanionError.relayRollback, CompanionError.responseVerificationFailed: return true
        // Local storage problems say nothing about the invite; let the friend retry.
        case is CompanionLocalError: return true
        default: return false
        }
    }

    /// Friend side: the pairing returned by `acceptInvite`, stored directly.
    @discardableResult
    private func upsertAcceptedPairing(_ pairing: Pairing) -> Bool {
        if let index = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID }) {
            // Advance-only: never overwrite an existing record with a different owner/approver or an older epoch.
            switch CompanionTrustMerge.decide(pairing: pairing, viewerIdentityID: pairing.approver.identityID,
                                              existingPairing: people[index].pairing) {
            case .update(let updated): people[index].pairing = updated
            case .unchanged: break
            case .rejected:
                lastError = "The server returned a pairing that conflicts with one already stored; ignoring it."
                return false
            }
        } else {
            people.append(CompanionPerson(nickname: CompanionPerson.defaultName(for: pairing, role: .iAmApprover),
                                          localRole: .iAmApprover, pairing: pairing, consent: nil))
        }
        savePeople()
        recomputeJoinedNotices()
        return true
    }

    // MARK: - People lists (one row per person)

    /// Newest active pairing per counterpart, so a friend who accepted twice
    /// (two invites) is one row, not two.
    private func dedupedActive(_ role: CompanionPerson.LocalRole, where include: (CompanionPerson) -> Bool = { _ in true }) -> [CompanionPerson] {
        var newest: [String: CompanionPerson] = [:]
        for person in people where person.localRole == role && person.pairing.state == .active && include(person) {
            if let existing = newest[person.counterpartIdentityID], existing.pairing.createdAt >= person.pairing.createdAt { continue }
            newest[person.counterpartIdentityID] = person
        }
        return newest.values.sorted { $0.pairing.createdAt < $1.pairing.createdAt }
    }

    /// Owner side: people proven to have joined through an invite this device issued.
    var trustedPeople: [CompanionPerson] { dedupedActive(.iAmOwner) { $0.joinVerified } }
    /// Friend side: the owners this device is a trusted person for.
    var helpingPeople: [CompanionPerson] { dedupedActive(.iAmApprover) }
    /// Owner side: active pairings from an earlier build that can't be verified.
    var hasUnverifiedOwnerPeople: Bool {
        people.contains { $0.localRole == .iAmOwner && $0.pairing.state == .active && !$0.joinVerified }
    }

    // MARK: - Opt out (friend)

    /// Friend side: withdraws both scopes ("Stop being a trusted person") in
    /// one call per pairing, for every active pairing with this owner (a
    /// friend who accepted twice has two).
    func stopBeingTrustedPerson(for person: CompanionPerson) async {
        guard isAvailable, person.localRole == .iAmApprover else { return }
        do {
            let identity = try ensureIdentity(role: .trustedApprover)
            let group = people.filter { $0.localRole == .iAmApprover && $0.pairing.state == .active
                && $0.pairing.owner.identityID == person.pairing.owner.identityID }
            var allApplied = true
            for member in group {
                let scopes: [CompanionScope] = [.approveEarlyEnd, .receiveRequests]
                let consent: RelationshipConsent
                #if DEBUG
                if let revokeScopesOverride {
                    consent = try await revokeScopesOverride(member.pairing, scopes)
                } else {
                    consent = try await makeClient(signer: try signer(for: identity)).revokeScopes(pairing: member.pairing, scopes: scopes)
                }
                #else
                consent = try await makeClient(signer: try signer(for: identity)).revokeScopes(pairing: member.pairing, scopes: scopes)
                #endif
                if !applyOwnConsentUpdate(consent, forPairingID: member.pairing.pairingID) { allApplied = false }
            }
            // A warning set by an ignored consent stays on screen.
            if allApplied { lastError = nil; needsRepair = false }
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
            if applyOwnConsentUpdate(consent, forPairingID: person.pairing.pairingID) { lastError = nil; needsRepair = false }
        } catch { fail(error) }
    }

    /// Even a consent returned in direct response to this device's own
    /// signed mutation still comes from the relay over the wire, so it is
    /// routed through the same `CompanionTrustMerge.decide(consent:)` check
    /// as inbox-observed consent (matching pairing ID/epoch/owner/approver,
    /// generation never regressing) rather than stored as-is.
    /// Returns `false` when the consent was ignored (and says why in
    /// `lastError`); the caller must not clear that warning afterwards.
    @discardableResult
    private func applyOwnConsentUpdate(_ consent: RelationshipConsent, forPairingID pairingID: String) -> Bool {
        guard let index = people.firstIndex(where: { $0.pairing.pairingID == pairingID }) else { return false }
        switch CompanionTrustMerge.decide(consent: consent, for: people[index].pairing, existingConsent: people[index].consent) {
        case .accepted(let accepted):
            people[index].consent = accepted
            savePeople()
            return true
        case .rejected(let reason):
            lastError = "The server returned unexpected consent data (\(reason)); ignoring it."
            return false
        }
    }

    // MARK: - Remove a person (owner)

    /// Removes a trusted person: revokes their pairing (and any duplicate
    /// pairing from the same friend) and deletes the stored invite(s) that
    /// created it, so no stale token outlives the pairing.
    func revokePairing(_ person: CompanionPerson) async {
        guard isAvailable, person.localRole == .iAmOwner else { return }
        // If the invite store can't be read, the token is deleted later (see
        // `discardInvitesOfRemovedPeople`): the person stays marked as removed.
        retryInviteStoreReadIfNeeded()
        do {
            let identity = try ensureIdentity(role: .owner)
            let client = makeClient(signer: try signer(for: identity))
            let group = people.filter { $0.localRole == .iAmOwner && $0.pairing.state == .active
                && $0.pairing.approver.identityID == person.pairing.approver.identityID }
            for member in group {
                #if DEBUG
                if let revokePairingOverride {
                    try await revokePairingOverride(member.pairing)
                } else {
                    try await client.revoke(member.pairing)
                }
                #else
                try await client.revoke(member.pairing)
                #endif
                // Marked revoked in place rather than deleted, so a later
                // inbox fetch that still lists this pairing (now `.revoked`
                // there too) can only confirm the same state through
                // `CompanionTrustMerge`'s field lock, never resurrect it.
                if let index = people.firstIndex(where: { $0.id == member.id }) {
                    people[index].pairing.state = .revoked
                }
                discardIssuedInvites(for: member.pairing)
                savePeople()
            }
            recomputeJoinedNotices()
            lastError = nil; needsRepair = false
        } catch { fail(error) }
    }

    func rename(_ person: CompanionPerson, to nickname: String) {
        guard isAvailable, let index = people.firstIndex(where: { $0.id == person.id }), !nickname.isEmpty else { return }
        people[index].nickname = nickname
        savePeople()
    }

    // MARK: - Ask to end early (owner) / approve-decline (friend)

    /// Owner side: verified, fully trusted people (one per friend) who can be asked.
    var trustedApprovers: [CompanionPerson] {
        trustedPeople.filter { $0.isFullyTrustedForEarlyEnd }
    }

    static let minimumAskLeadTime: TimeInterval = 30
    static let lockAboutToEndMessage = "This lock is about to end."
    static let lockAlreadyEndedMessage = "That lock has already ended, so there's nothing left to ask about."
    static let chooseSomeoneToAskMessage = "Choose at least one trusted person to ask."

    /// What an Ask can say about a lock ending at `end`, judged at `now`:
    /// `nil` when it can go ahead, otherwise the message to show instead.
    static func askBlockedMessage(end: Date, now: Date) -> String? {
        let remaining = end.timeIntervalSince(now)
        if remaining >= minimumAskLeadTime { return nil }
        return remaining > 0 ? lockAboutToEndMessage : lockAlreadyEndedMessage
    }

    /// How long a request may live: until the lock ends, or 24 hours if sooner.
    /// `nil` when the lock is already over at `requestTime`.
    static func askValidity(end: Date, requestTime: Date) -> TimeInterval? {
        let remaining = end.timeIntervalSince(requestTime)
        guard remaining > 0 else { return nil }
        return min(remaining, CompanionLimits.maxRequestLifetime)
    }

    #if DEBUG
    /// Test-only: replaces the two relay calls of an Ask (publish the session,
    /// create the request) so the Ask logic runs without a relay. Receives the
    /// session, the single instant the request lifetime is derived from, the
    /// lifetime, and the people asked.
    var askRelayOverride: (@MainActor (_ session: ActiveSession, _ requestTime: Date, _ validFor: TimeInterval,
                                       _ targets: [CompanionPerson]) async throws -> Void)?
    #endif

    func requestEarlyEnd(sessionID: String, activeSetID: String, start: Date, end: Date,
                        to targets: [CompanionPerson]) async {
        guard isAvailable else { return }
        guard !targets.isEmpty, targets.allSatisfy({ $0.localRole == .iAmOwner && $0.joinVerified && $0.pairing.state == .active && $0.isFullyTrustedForEarlyEnd }) else {
            lastError = Self.chooseSomeoneToAskMessage
            return
        }
        do {
            let identity = try ensureIdentity(role: .owner)
            // Checked before publishing anything: a lock that is over (or
            // about to be) has no request worth sending, and a request must
            // outlive the round trip to be answerable.
            if let blocked = Self.askBlockedMessage(end: end, now: Date()) {
                lastError = blocked
                return
            }
            let session = try ActiveSession(owner: identity, sessionID: sessionID, activeSetID: activeSetID,
                                            startsAt: start, endsAt: end)
            #if DEBUG
            if let askRelayOverride {
                let requestTime = Date()
                guard let validFor = Self.askValidity(end: end, requestTime: requestTime) else {
                    lastError = Self.lockAlreadyEndedMessage
                    return
                }
                try await askRelayOverride(session, requestTime, validFor, targets)
                lastError = nil; needsRepair = false
                return
            }
            #endif
            let client = makeClient(signer: try signer(for: identity))
            _ = try await client.publishSession(session)
            // P3-0 root cause (build-21 "Ask now never reached the friend"):
            // `TrustedRequest` requires `expiresAt <= session.endsAt`, but
            // the lifetime used to be computed from one `Date()` here while
            // `requestUnlock` stamped `createdAt` from a *later* `Date()`
            // inside the client -- so `createdAt + validFor` overshot the
            // session end by the elapsed microseconds and the request was
            // rejected locally ("invalid trusted request") whenever the lock
            // had under 24h left (i.e. always). Pin the client clock to the
            // single instant the lifetime is derived from, so the request
            // expires exactly when the session ends (or in 24h, if sooner).
            let requestTime = Date()
            guard let validFor = Self.askValidity(end: end, requestTime: requestTime) else {
                lastError = Self.lockAlreadyEndedMessage
                return
            }
            let requestClient = makeClient(signer: try signer(for: identity), now: { requestTime })
            _ = try await requestClient.requestUnlock(requestID: UUID().uuidString, pairings: targets.map(\.pairing),
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
        // With no pinned `approvalID`, take the first approval that verifies
        // (a stale or forged one earlier in the list must not hide a good one);
        // with none verifying, report the first failure.
        let candidates = (response.approvals ?? []).filter {
            $0.requestID == requestID && (approvalID == nil || $0.approvalID == approvalID)
        }
        guard !candidates.isEmpty else { throw CompanionError.notFound }
        var firstError: Error?
        for approval in candidates {
            do {
                // Approvals are accepted only from people the join check verified.
                guard let targetBinding = request.binding(for: approval.approver.identityID),
                      let person = people.first(where: { $0.pairing.pairingID == targetBinding.pairingID }),
                      person.localRole == .iAmOwner, person.joinVerified,
                      let consent = person.consent else {
                    throw CompanionError.unknownIdentity
                }
                let trustedApprover = OwnerApprovalCheck.TrustedApprover(pairing: person.pairing, consent: consent)
                try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trustedApprover, ownerIdentity: ownerIdentity)
                return (request, approval, trustedApprover)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? CompanionError.notFound
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
                lastError = "Couldn't connect. Pull down to finish."
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
                lastError = "The server's response failed an integrity check. Nothing was changed here; this needs attention before trying again."
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
    /// P3-0 (build-21 "pull-to-refresh always shows a relay error"): SwiftUI
    /// cancels the `.refreshable`/`.task` closure's task whenever it decides
    /// the hosting view was replaced or the gesture ended early. Because
    /// `refreshInbox` used to run its `URLSession` calls *inside* that
    /// structured task, a cancel made `session.data(for:)` throw
    /// `URLError.cancelled`, which `HTTPCompanionTransport` maps to
    /// `.unavailable` -- the "Couldn't reach the relay" banner -- even though
    /// the relay had already answered HTTP 200 (exactly the Vercel evidence).
    /// The refresh now runs in one unstructured, single-flight task: caller
    /// cancellation neither aborts the request nor raises a banner, and a
    /// `.task` + pull-to-refresh overlap joins the in-flight fetch instead of
    /// racing it.
    #if DEBUG
    /// Test-only (same style as `useApprovalOverride`): awaited inside every
    /// refresh pass after the relay responses arrive and before they are
    /// applied.
    var inboxFetchGateForTesting: (@MainActor () async -> Void)?
    /// Test-only: number of `refreshInbox()` calls so far.
    private(set) var refreshCallCountForTesting = 0
    #endif

    func refreshInbox() async { await refreshInbox(followUp: false) }

    /// `followUp` marks the single bounded extra flight scheduled after a capped one.
    private func refreshInbox(followUp: Bool) async {
        guard isAvailable else { return }
        #if DEBUG
        refreshCallCountForTesting += 1
        #endif
        if let flight = refreshFlight {
            // Arriving mid-flight: the in-flight fetch may predate whatever
            // the caller just changed, so demand one more pass and wait for
            // the final one.
            refreshNeedsAnotherPass = true
            await flight.value
            return
        }
        let flight = Task { @MainActor [weak self] in
            guard let self else { return }
            var passes = 0
            repeat {
                self.refreshNeedsAnotherPass = false
                passes += 1
                await self.performInboxRefresh()
            } while self.refreshNeedsAnotherPass && passes < Self.maxRefreshPasses
            // Capped so a steady stream of callers (the People auto-refresh
            // timer, pull-to-refresh, mutations) can never keep one flight
            // looping forever; anything still flagged is picked up by the
            // next caller.
            let capped = self.refreshNeedsAnotherPass
            self.refreshNeedsAnotherPass = false
            // Cleared here, with no suspension since the loop check, so a
            // later caller can never join a finished flight.
            self.refreshFlight = nil
            // A caller that joined during the last allowed pass may have
            // changed something the final fetch predates: run exactly one
            // follow-up flight (never chained), so it is not left stale until
            // the next poll.
            if capped && !followUp {
                Task { @MainActor [weak self] in await self?.refreshInbox(followUp: true) }
            }
        }
        refreshFlight = flight
        await flight.value
    }

    /// Passes one looping single flight may run before it completes.
    static let maxRefreshPasses = 3

    // MARK: - Auto-refresh (People tab)

    static let fastRefreshInterval: TimeInterval = 5
    static let idleRefreshInterval: TimeInterval = 30

    /// The link on screen has passed its expiry: the card says so and offers a new one.
    var pendingInviteIsExpired: Bool {
        guard let pendingInvite else { return false }
        return Date() >= pendingInvite.invitation.payload.expiresAt
    }

    /// Friend first-run: nobody has been invited and no one is paired, or a link was just opened, so "Got an invite link?" goes
    /// above the owner invite card instead of below all its copy.
    var showsAcceptInviteFirst: Bool {
        if case .none = incomingInvite {} else { return true }
        return pendingInvite == nil && people.isEmpty
    }

    /// True while an unexpired invite has not yet produced a person on this device.
    var hasOutstandingInvite: Bool {
        let now = Date()
        return issuedInvites.values.contains { now < $0.invitation.payload.expiresAt && !inviteHasPerson($0) }
    }

    /// Items that need the user right now, for the "Waiting for you" card:
    /// a request addressed to this device that it has not decided yet, or the
    /// owner's own approved request that still has an "End lock now" action
    /// (or is finishing). Everything else is history in the Inbox.
    func waitingItems(coordinator: any FriendReleaseLifecycle) -> [CompanionInboxItem] {
        inboxItems.filter { isWaitingForUser($0, coordinator: coordinator) }
    }

    /// The Inbox history: every item that is not in the Waiting card.
    func historyItems(coordinator: any FriendReleaseLifecycle) -> [CompanionInboxItem] {
        inboxItems.filter { !isWaitingForUser($0, coordinator: coordinator) }
    }

    private func isWaitingForUser(_ item: CompanionInboxItem, coordinator: any FriendReleaseLifecycle) -> Bool {
        if !item.isMine { return item.status == .pending && item.myDecision == .pending }
        guard item.status == .approved else { return false }
        return Self.shouldShowFriendReleaseAction(for: item, gateEnabled: friendApprovalCanEndLocksEnabled)
            || friendReleaseRequestState(for: item, coordinator: coordinator) == .finishing
    }

    /// Plain-word badge for an Inbox row.
    static func statusBadgeTitle(_ status: TrustedRequestStatus) -> String {
        switch status {
        case .pending: return "Waiting"
        case .approved: return "Approved"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        }
    }

    /// True while any request this device can see is still waiting for a decision.
    var hasPendingRequest: Bool { inboxItems.contains { $0.status == .pending } }

    /// ~5 s while something is about to change (an invite outstanding or a
    /// request pending), otherwise ~30 s.
    var autoRefreshInterval: TimeInterval {
        (hasOutstandingInvite || hasPendingRequest) ? Self.fastRefreshInterval : Self.idleRefreshInterval
    }

    /// Refreshes now, then again every `autoRefreshInterval`, until the
    /// calling task is cancelled. `PeopleView` runs this from a `.task` keyed
    /// on the scene phase, so it stops when People is not visible or the app
    /// is not active and starts with an immediate refresh when it becomes
    /// active again.
    func runAutoRefreshLoop(coordinator: any FriendReleaseLifecycle) async {
        while !Task.isCancelled {
            await refreshInbox()
            if Task.isCancelled { break }
            await replayPendingFriendRelease(coordinator: coordinator)
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(autoRefreshInterval * 1_000_000_000))
        }
    }

    private func performInboxRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        retryInviteStoreReadIfNeeded()
        pruneIssuedInvites(now: Date())
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
                pruneUseIDsByRequestID(presentRequestIDs: Set(response.requests.map(\.requestID)))
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

        #if DEBUG
        // Responses are in hand but not yet applied: lets a test hold a
        // fetch whose data is about to go stale.
        if let inboxFetchGateForTesting { await inboxFetchGateForTesting() }
        #endif
        inboxItems = items.sorted { $0.request.createdAt > $1.request.createdAt }
        inboxDataNotice = rejectionCount > 0
            ? "The server returned unexpected pairing or consent data; \(rejectionCount) item(s) were ignored."
            : nil
        if let encounteredError {
            fail(encounteredError)
        } else if inviteStoreFailed && ownerIdentity != nil {
            lastError = inviteStoreProblemMessage
        } else if anyFetchSucceeded || (ownerIdentity == nil && approverIdentity == nil) {
            lastError = nil; needsRepair = false
        }
    }

    static let integrityNoticeText =
        "Some activity reported by the server didn't check out, so it was ignored. Nothing was changed. If this keeps showing, remove the person involved and send a new invite."

    /// Folds one inbox response into the local registry. Returns the number
    /// of rejected (untrusted or malformed) entries so the caller can surface
    /// one non-blocking notice; a rejection never aborts the rest.
    ///
    /// **Owner side (pairing v3):** the owner no longer confirms anyone, so
    /// the only way a relay-reported pairing becomes a person is
    /// `JoinedAcceptanceCheck.verifiedPairings` against the invites this
    /// device issued. Pairings that don't verify (earlier-build pairings, a
    /// misbehaving relay) are never added, and consents are accepted only for
    /// verified people. **Friend side:** a pairing is stored only from this
    /// device's own `acceptInvite` response; the inbox may only advance it
    /// (`CompanionTrustMerge`'s field lock).
    @discardableResult
    func applyInboxSnapshot(_ response: InboxResponse, viewerIdentity: DeviceIdentity) -> Int {
        let isOwnerView = viewerIdentity.role == .owner
        var verifiedIDs: Set<String> = []
        // A local Keychain read error must never demote people who were verified before.
        let canVerify = !(isOwnerView && inviteStoreFailed)
        if isOwnerView && !canVerify { integrityNotice = nil }
        if isOwnerView && canVerify {
            let result = JoinedAcceptanceCheck.verifiedPairings(in: response, invites: issuedInvites, ownerIdentity: viewerIdentity)
            verifiedIDs = Set(result.verified.map(\.pairingID))
            integrityNotice = result.integrityWarnings.isEmpty ? nil : Self.integrityNoticeText
            #if DEBUG
            // Warnings name invite IDs only (never tokens, keys or signatures).
            for warning in result.integrityWarnings { print("[CompanionCoordinator] integrity: \(warning)") }
            #endif
        }
        var consentsByPairingID: [String: RelationshipConsent] = [:]
        for consent in response.consents ?? [] { consentsByPairingID[consent.pairingID] = consent }

        var rejections = 0
        for pairing in response.pairings ?? [] {
            let existingIndex = people.firstIndex(where: { $0.pairing.pairingID == pairing.pairingID })
            let resolvedPairing: Pairing?
            if let existingIndex {
                switch CompanionTrustMerge.decide(pairing: pairing, viewerIdentityID: viewerIdentity.identityID,
                                                  existingPairing: people[existingIndex].pairing) {
                case .unchanged: resolvedPairing = people[existingIndex].pairing
                case .update(let updated):
                    people[existingIndex].pairing = updated
                    resolvedPairing = updated
                case .rejected:
                    rejections += 1
                    resolvedPairing = nil
                }
            } else if isOwnerView, verifiedIDs.contains(pairing.pairingID), pairing.owner == viewerIdentity {
                people.append(CompanionPerson(nickname: CompanionPerson.defaultName(for: pairing, role: .iAmOwner),
                                              localRole: .iAmOwner, pairing: pairing, consent: nil, joinVerified: true))
                resolvedPairing = pairing
            } else {
                // Not provable (or not ours to learn from the inbox): show nothing.
                resolvedPairing = nil
            }

            guard let resolvedPairing,
                  let currentIndex = people.firstIndex(where: { $0.pairing.pairingID == resolvedPairing.pairingID }) else { continue }
            if isOwnerView && canVerify { people[currentIndex].joinVerified = verifiedIDs.contains(resolvedPairing.pairingID) }
            // Never accept consent for an owner-side pairing that hasn't verified.
            if isOwnerView && !people[currentIndex].joinVerified { continue }
            guard let candidateConsent = consentsByPairingID[resolvedPairing.pairingID] else { continue }
            switch CompanionTrustMerge.decide(consent: candidateConsent, for: resolvedPairing, existingConsent: people[currentIndex].consent) {
            case .accepted(let accepted):
                people[currentIndex].consent = accepted
            case .rejected:
                rejections += 1
            }
        }
        if rejections > 0 || !(response.pairings ?? []).isEmpty { savePeople() }
        if isOwnerView {
            recomputeJoinedNotices()
            // An expired link stays (shown as expired, with a one-tap new invite);
            // only a link that already created a person is dropped.
            if let pendingInvite, inviteHasPerson(pendingInvite) { self.pendingInvite = nil }
        }
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
