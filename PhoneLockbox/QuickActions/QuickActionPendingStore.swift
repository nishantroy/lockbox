import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded App Group handoff for navigation-only quick-action routes. This
/// queue is independent from enforcement runtime state and uses claim/ack so a
/// host crash can retry presentation without deleting a concurrently enqueued
/// route or changing policy.
///
/// The queue is deliberately a small durable-storage abstraction rather than a
/// second application state store. Its payload is only an unauthenticated
/// navigation URL; it never authorizes, applies, releases, or edits a lock.
struct QuickActionPendingRouteStore: @unchecked Sendable {
    struct Claim: Equatable, Sendable {
        // These are intentionally carried through the coordinator and UI. An
        // acknowledgement must match both values, so a re-leased route cannot
        // be removed by a stale presentation callback.
        let id: String
        let token: String
        let url: URL
        /// The exact wall-clock instant at which this claim can be reclaimed.
        /// Keeping this on the claim lets terminal acknowledgement failures
        /// schedule a retry without guessing or spinning.
        let leaseUntil: Date
    }

    enum ClaimResult: Equatable, Sendable {
        case empty
        case leased(until: Date)
        case claimed(Claim)

        /// The next instant at which the head may be claimed. `nil` means the
        /// queue is empty; a caller must not treat that as a leased head.
        var nextClaimOpportunity: Date? {
            switch self {
            case .empty: return nil
            case .leased(let until): return until
            case .claimed(let claim): return claim.leaseUntil
            }
        }
    }

    private struct Entry: Codable, Equatable {
        let id: String
        let url: String
        let enqueuedAt: Int64
        var claimToken: String?
        var claimUntil: Int64?

        private enum CodingKeys: String, CodingKey {
            case id, url, enqueuedAt, claimToken, claimUntil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let claimToken = try container.decodeIfPresent(String.self, forKey: .claimToken)
            let claimUntil = try container.decodeIfPresent(Int64.self, forKey: .claimUntil)
            guard id.utf8.count <= QuickActionPendingRouteStore.maximumIdentifierBytes,
                  url.utf8.count <= QuickActionPendingRouteStore.maximumURLBytes,
                  claimToken?.utf8.count ?? 0 <= QuickActionPendingRouteStore.maximumClaimTokenBytes else {
                throw QueueError.corrupt
            }
            self.id = id
            self.url = url
            self.enqueuedAt = try container.decode(Int64.self, forKey: .enqueuedAt)
            self.claimToken = claimToken
            self.claimUntil = claimUntil
        }

        init(id: String, url: String, enqueuedAt: Int64, claimToken: String?, claimUntil: Int64?) {
            self.id = id
            self.url = url
            self.enqueuedAt = enqueuedAt
            self.claimToken = claimToken
            self.claimUntil = claimUntil
        }
    }

    private struct Document: Codable, Equatable {
        static let currentSchema = 1
        let schemaVersion: Int
        var entries: [Entry]
        /// A bounded replay tombstone set keeps an already-settled nonce from
        /// being re-enqueued while its short-lived route could still be
        /// replayed. These are navigation deduplication metadata, not auth.
        var settledIDs: [String]

        init(entries: [Entry] = [], settledIDs: [String] = []) {
            self.schemaVersion = Self.currentSchema
            self.entries = entries
            self.settledIDs = settledIDs
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, entries, settledIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == Self.currentSchema else { throw QueueError.corrupt }
            var entriesContainer = try container.nestedUnkeyedContainer(forKey: .entries)
            guard let count = entriesContainer.count,
                  count <= QuickActionPendingRouteStore.maximumEntries else {
                throw QueueError.corrupt
            }
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            while !entriesContainer.isAtEnd {
                entries.append(try entriesContainer.decode(Entry.self))
            }

            var settledIDs: [String] = []
            if container.contains(.settledIDs) {
                var settledContainer = try container.nestedUnkeyedContainer(forKey: .settledIDs)
                guard let settledCount = settledContainer.count,
                      settledCount <= QuickActionPendingRouteStore.maximumSettledIdentifiers else {
                    throw QueueError.corrupt
                }
                settledIDs.reserveCapacity(settledCount)
                while !settledContainer.isAtEnd {
                    let id = try settledContainer.decode(String.self)
                    guard id.utf8.count <= QuickActionPendingRouteStore.maximumIdentifierBytes else {
                        throw QueueError.corrupt
                    }
                    settledIDs.append(id)
                }
            }
            self.schemaVersion = schemaVersion
            self.entries = entries
            self.settledIDs = settledIDs
        }
    }

    private enum QueueError: Error {
        case unavailable
        case corrupt
        case locked
        case invalidClock
    }

    /// Failure points used by host and simulator tests to prove that a
    /// pre-rename failure is reported as unsuccessful while a post-rename
    /// directory-sync failure remains a committed, durability-uncertain write.
    enum WriteFailureInjection: Equatable, Sendable {
        case write
        case fileSync
        case close
        case rename
        case directorySync
    }

    private enum WriteDurability: Equatable {
        case durable
        case atomicRenameOnly
        case uncertain
    }

    private enum WriteOutcome: Equatable {
        case committed(WriteDurability)
    }

    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private static let queueFileName = "phone-lockbox.quick-action-queue.json"
    private static let lockFileName = "phone-lockbox.quick-action-queue.lock"

    // These limits are intentionally small. A quick action contains one of
    // three known paths and a handful of decimal/UUID fields, so accepting a
    // multi-megabyte App Group document would only expand a local DoS surface.
    static let maximumEntries = 32
    private static let maximumSettledIdentifiers = 64
    static let maximumQueueBytes = 32 * 1024
    static let maximumIdentifierBytes = 64
    static let maximumURLBytes = 1_024
    static let maximumClaimTokenBytes = 64
    private static let maximumEntryAge: Int64 = 10 * 60
    private static let claimLease: Int64 = 60
    /// A rollback larger than this is treated deterministically: all queued
    /// routes are discarded because their freshness timestamps cannot safely
    /// be interpreted under the new wall clock. Navigation-only data may be
    /// dropped; it must never wedge queue capacity or enforcement state.
    private static let significantClockRollback: Int64 = 5 * 60

    private let directoryURL: URL
    private let queueURL: URL
    private let lockURL: URL
    private let lockTimeout: TimeInterval
    private let failureInjection: WriteFailureInjection?

    init(
        directoryURL: URL,
        lockTimeout: TimeInterval = 0.5,
        failureInjection: WriteFailureInjection? = nil
    ) throws {
        self.directoryURL = directoryURL
        self.queueURL = directoryURL.appendingPathComponent(Self.queueFileName)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName)
        self.lockTimeout = lockTimeout.isFinite ? max(0, min(lockTimeout, 5)) : 0.5
        self.failureInjection = failureInjection
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try applyProtection(to: directoryURL)
            if !FileManager.default.fileExists(atPath: lockURL.path) {
                guard FileManager.default.createFile(atPath: lockURL.path, contents: nil) else {
                    throw QueueError.unavailable
                }
            }
            try applyProtection(to: lockURL)
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.unavailable
        }
    }

    static func appGroupStore() -> Self? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return try? Self(directoryURL: directory)
    }

    static func enqueue(_ action: QuickActionRoute.Action, now: Date = Date()) -> Bool {
        guard let store = appGroupStore() else { return false }
        return store.enqueue(action, now: now)
    }

    static func enqueue(_ url: URL, now: Date = Date()) -> Bool {
        guard let store = appGroupStore() else { return false }
        return store.enqueue(url, now: now)
    }

    static func claim(now: Date = Date()) -> Claim? {
        guard let store = appGroupStore() else { return nil }
        return try? store.claim(now: now)
    }

    static func claimResult(now: Date = Date()) -> ClaimResult? {
        guard let store = appGroupStore() else { return nil }
        return try? store.claimResult(now: now)
    }

    static func acknowledge(_ claim: Claim) -> Bool {
        guard let store = appGroupStore() else { return false }
        return (try? store.acknowledge(claim)) == true
    }

    @discardableResult
    func enqueue(_ action: QuickActionRoute.Action, now: Date = Date()) -> Bool {
        guard let url = QuickActionRoute.url(for: action, now: now) else { return false }
        return enqueue(url, now: now)
    }

    /// Enqueues an already-created route. Keeping the route ID in the durable
    /// entry makes retrying the same intent idempotent rather than overwriting
    /// an earlier navigation request.
    @discardableResult
    func enqueue(_ url: URL, now: Date = Date()) -> Bool {
        guard let route = QuickActionRoute.parse(url, now: now),
              let seconds = Self.integerSeconds(now),
              url.absoluteString.utf8.count <= Self.maximumURLBytes else { return false }
        do {
            try withExclusiveLock {
                var document = try read()
                prune(&document, now: seconds)
                guard !document.entries.contains(where: { $0.id == route.id }),
                      !document.settledIDs.contains(route.id) else { return }
                guard document.entries.count < Self.maximumEntries else { throw QueueError.locked }
                document.entries.append(Entry(id: route.id, url: url.absoluteString, enqueuedAt: seconds, claimToken: nil, claimUntil: nil))
                try write(document)
            }
            return true
        } catch {
            return false
        }
    }

    /// Atomically claims the oldest available entry. The lease makes a crash
    /// retryable; only the matching token can acknowledge and remove it.
    /// Queue order is strict FIFO: an unexpired lease on the head blocks later
    /// entries rather than allowing a later route to overtake it.
    func claim(now: Date = Date()) throws -> Claim? {
        switch try claimResult(now: now) {
        case .empty, .leased:
            return nil
        case .claimed(let claim):
            return claim
        }
    }

    /// Returns the queue's exact claim state. An empty queue is distinct from
    /// a leased FIFO head so a coordinator can sleep until the lease deadline
    /// instead of polling or spinning.
    func claimResult(now: Date = Date()) throws -> ClaimResult {
        guard let seconds = Self.integerSeconds(now) else { throw QueueError.invalidClock }
        return try withExclusiveLock {
            var document = try read()
            let before = document.entries
            prune(&document, now: seconds)
            if document.entries != before { try write(document) }
            guard let head = document.entries.first else { return .empty }
            if let until = head.claimUntil, until > seconds {
                return .leased(until: Date(timeIntervalSinceReferenceDate: Double(until)))
            }
            let token = UUID().uuidString.lowercased()
            guard !seconds.addingReportingOverflow(Self.claimLease).overflow else { throw QueueError.invalidClock }
            let leaseUntil = seconds.addingReportingOverflow(Self.claimLease).partialValue
            document.entries[0].claimToken = token
            document.entries[0].claimUntil = leaseUntil
            try write(document)
            guard let url = URL(string: document.entries[0].url) else { throw QueueError.corrupt }
            return .claimed(Claim(
                id: document.entries[0].id,
                token: token,
                url: url,
                leaseUntil: Date(timeIntervalSinceReferenceDate: Double(leaseUntil))
            ))
        }
    }

    /// Removes only the claimed entry identified by both route ID and lease
    /// token. A stale consumer cannot acknowledge a newer claimant's entry.
    @discardableResult
    func acknowledge(_ claim: Claim) throws -> Bool {
        try withExclusiveLock {
            var document = try read()
            guard let index = document.entries.firstIndex(where: {
                $0.id == claim.id && $0.claimToken == claim.token
            }) else { return false }
            let settledID = document.entries[index].id
            document.entries.remove(at: index)
            document.settledIDs.removeAll { $0 == settledID }
            document.settledIDs.append(settledID)
            if document.settledIDs.count > Self.maximumSettledIdentifiers {
                document.settledIDs.removeFirst(document.settledIDs.count - Self.maximumSettledIdentifiers)
            }
            _ = try write(document)
            return true
        }
    }

    private func prune(_ document: inout Document, now: Int64) {
        // Without a monotonic clock shared by the App Group processes, an
        // entry/lease materially ahead of `now` is the only durable evidence of
        // a wall-clock rollback. Drop the whole navigation queue, including
        // leases, rather than retaining future data until it fills capacity.
        let rollback = document.entries.contains { entry in
            isSignificantlyFuture(entry.enqueuedAt, relativeTo: now)
                || (entry.claimUntil.map { isSignificantlyFuture($0, relativeTo: now) } ?? false)
        }
        if rollback {
            document.entries.removeAll()
            return
        }

        document.entries.removeAll { entry in
            guard now >= entry.enqueuedAt else { return false }
            let age = now.subtractingReportingOverflow(entry.enqueuedAt)
            return age.overflow || age.partialValue > Self.maximumEntryAge
        }
    }

    private func isSignificantlyFuture(_ value: Int64, relativeTo now: Int64) -> Bool {
        let difference = value.subtractingReportingOverflow(now)
        return !difference.overflow && difference.partialValue > Self.significantClockRollback
    }

    private func read() throws -> Document {
#if canImport(Darwin) || canImport(Glibc)
        // Bind validation and reading to one descriptor. O_NOFOLLOW rejects a
        // symlink at open, O_NONBLOCK makes a hostile FIFO/device harmless,
        // and fstat validates the exact inode that will be read.
        let descriptor = open(queueURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Document() }
            throw QueueError.corrupt
        }
        defer { _ = close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { throw QueueError.corrupt }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else { throw QueueError.corrupt }
        let size = Int64(fileInfo.st_size)
        guard size >= 0, size <= Int64(Self.maximumQueueBytes) else { throw QueueError.corrupt }
        do {
            let data = try readBounded(from: descriptor)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == Document.currentSchema,
                  document.entries.count <= Self.maximumEntries,
                  document.settledIDs.count <= Self.maximumSettledIdentifiers,
                  Set(document.entries.map(\.id)).count == document.entries.count,
                  Set(document.settledIDs).count == document.settledIDs.count,
                  Set(document.entries.map(\.id)).isDisjoint(with: document.settledIDs),
                  document.entries.allSatisfy(validEntry),
                  document.settledIDs.allSatisfy(isCanonicalUUID) else { throw QueueError.corrupt }
            return document
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.corrupt
        }
#else
        do {
            let data = try Data(contentsOf: queueURL)
            guard data.count <= Self.maximumQueueBytes else { throw QueueError.corrupt }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == Document.currentSchema,
                  document.entries.count <= Self.maximumEntries,
                  document.settledIDs.count <= Self.maximumSettledIdentifiers,
                  Set(document.entries.map(\.id)).count == document.entries.count,
                  Set(document.settledIDs).count == document.settledIDs.count,
                  Set(document.entries.map(\.id)).isDisjoint(with: document.settledIDs),
                  document.entries.allSatisfy(validEntry),
                  document.settledIDs.allSatisfy(isCanonicalUUID) else { throw QueueError.corrupt }
            return document
        } catch let error as QueueError {
            throw error
        } catch {
            if !FileManager.default.fileExists(atPath: queueURL.path) { return Document() }
            throw QueueError.corrupt
        }
#endif
    }

#if canImport(Darwin) || canImport(Glibc)
    private func readBounded(from descriptor: Int32) throws -> Data {
        var data = Data()
        data.reserveCapacity(Self.maximumQueueBytes)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= Self.maximumQueueBytes {
            let requested = min(buffer.count, Self.maximumQueueBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
#if canImport(Darwin)
                return Darwin.read(descriptor, baseAddress, requested)
#else
                return Glibc.read(descriptor, baseAddress, requested)
#endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw QueueError.corrupt
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= Self.maximumQueueBytes else { throw QueueError.corrupt }
        return data
    }
#endif


    private func validEntry(_ entry: Entry) -> Bool {
        guard entry.id.utf8.count <= Self.maximumIdentifierBytes,
              entry.url.utf8.count <= Self.maximumURLBytes,
              entry.claimToken?.utf8.count ?? 0 <= Self.maximumClaimTokenBytes,
              isCanonicalUUID(entry.id),
              let url = URL(string: entry.url),
              !url.isFileURL,
              let route = QuickActionRoute.parse(url, now: Date(timeIntervalSinceReferenceDate: Double(entry.enqueuedAt))),
              route.id == entry.id else { return false }
        switch (entry.claimToken, entry.claimUntil) {
        case (nil, nil): return true
        case let (.some(token), .some(until)):
            return isCanonicalUUID(token) && until > entry.enqueuedAt
        default: return false
        }
    }

    /// Atomically replaces the queue and reports the logical mutation as
    /// committed once rename succeeds. A directory-sync error after rename is
    /// represented as `.uncertain`; callers must not report no effect or
    /// blindly retry the same nonce. Unsupported sync remains the explicit
    /// atomic-rename-only fallback.
    @discardableResult
    private func write(_ document: Document) throws -> WriteOutcome {
        guard document.entries.count <= Self.maximumEntries else { throw QueueError.corrupt }
        let data: Data
        do {
            data = try JSONEncoder().encode(document)
        } catch {
            throw QueueError.unavailable
        }
        guard data.count <= Self.maximumQueueBytes else { throw QueueError.corrupt }

#if canImport(Darwin) || canImport(Glibc)
        let temporaryURL = directoryURL.appendingPathComponent(".\(Self.queueFileName).\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw QueueError.unavailable }
        var isOpen = true
        var didRename = false
        do {
            try injectedFailure(.write)
            try writeAll(data, to: descriptor)
            try applyProtection(to: temporaryURL)
            try injectedFailure(.fileSync)
            _ = try synchronize(descriptor)
            try injectedFailure(.close)
            guard close(descriptor) == 0 else { throw QueueError.unavailable }
            isOpen = false
            try injectedFailure(.rename)
            guard rename(temporaryURL.path, queueURL.path) == 0 else { throw QueueError.unavailable }
            didRename = true
            do {
                let directorySync = try synchronizeDirectory()
                return .committed(directorySync ? .durable : .atomicRenameOnly)
            } catch {
                // The replacement is already visible. Do not turn a hard
                // directory-fsync error into an unsafe retry signal.
                return .committed(.uncertain)
            }
        } catch {
            if isOpen { _ = close(descriptor) }
            if !didRename { _ = unlink(temporaryURL.path) }
            if error is QueueError { throw error }
            throw QueueError.unavailable
        }
#else
        do {
            try data.write(to: queueURL, options: [.atomic])
            try applyProtection(to: queueURL)
            return .committed(.atomicRenameOnly)
        } catch {
            throw QueueError.unavailable
        }
#endif
    }

#if canImport(Darwin) || canImport(Glibc)
    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            while offset < buffer.count {
                let count = buffer.count - offset
                let written: Int
#if canImport(Darwin)
                written = Darwin.write(descriptor, baseAddress.advanced(by: offset), count)
#else
                written = Glibc.write(descriptor, baseAddress.advanced(by: offset), count)
#endif
                guard written > 0 else { throw QueueError.unavailable }
                offset += written
            }
        }
    }

    private func synchronize(_ descriptor: Int32) throws -> Bool {
#if canImport(Darwin)
        let result = Darwin.fsync(descriptor)
#else
        let result = Glibc.fsync(descriptor)
#endif
        guard result != -1 else {
            guard isUnsupportedSyncError(errno) else { throw QueueError.unavailable }
            return false
        }
        return true
    }

    private func synchronizeDirectory() throws -> Bool {
        try injectedFailure(.directorySync)
        let descriptor = open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw QueueError.unavailable }
        defer { _ = close(descriptor) }
#if canImport(Darwin)
        let result = Darwin.fsync(descriptor)
#else
        let result = Glibc.fsync(descriptor)
#endif
        guard result != -1 else {
            guard isUnsupportedSyncError(errno) else { throw QueueError.unavailable }
            return false
        }
        return true
    }

    private func injectedFailure(_ stage: WriteFailureInjection) throws {
        guard failureInjection == stage else { return }
        throw QueueError.unavailable
    }

    private func isUnsupportedSyncError(_ value: Int32) -> Bool {
#if canImport(Darwin) || canImport(Glibc)
        value == EINVAL || value == ENOTSUP || value == EOPNOTSUPP
#else
        false
#endif
    }
#endif

    private func applyProtection(to url: URL) throws {
#if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            throw QueueError.unavailable
        }
#else
        // Host-side tests and macOS tooling do not expose iOS Data Protection.
        // iOS production files explicitly use CompleteUntilFirstUserAuthentication.
        _ = url
#endif
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
#if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw QueueError.unavailable }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EAGAIN), ProcessInfo.processInfo.systemUptime < deadline else {
                throw QueueError.locked
            }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
#else
        return try body()
#endif
    }

    private static func integerSeconds(_ date: Date) -> Int64? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date.timeIntervalSinceReferenceDate >= Double(Int64.min),
              date.timeIntervalSinceReferenceDate < Double(Int64.max) else { return nil }
        return Int64(date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}
