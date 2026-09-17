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
struct QuickActionPendingRouteStore: @unchecked Sendable {
    struct Claim: Equatable, Sendable {
        fileprivate let id: String
        fileprivate let token: String
        let url: URL
    }

    private struct Entry: Codable, Equatable {
        let id: String
        let url: String
        let enqueuedAt: Int64
        var claimToken: String?
        var claimUntil: Int64?
    }

    private struct Document: Codable, Equatable {
        static let currentSchema = 1
        let schemaVersion: Int
        var entries: [Entry]

        init(entries: [Entry] = []) {
            self.schemaVersion = Self.currentSchema
            self.entries = entries
        }
    }

    private enum QueueError: Error {
        case unavailable
        case corrupt
        case locked
        case invalidClock
    }

    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private static let queueFileName = "phone-lockbox.quick-action-queue.json"
    private static let lockFileName = "phone-lockbox.quick-action-queue.lock"
    private static let maximumEntries = 32
    private static let maximumEntryAge: Int64 = 10 * 60
    private static let claimLease: Int64 = 60

    private let directoryURL: URL
    private let queueURL: URL
    private let lockURL: URL
    private let lockTimeout: TimeInterval

    init(directoryURL: URL, lockTimeout: TimeInterval = 0.5) throws {
        self.directoryURL = directoryURL
        self.queueURL = directoryURL.appendingPathComponent(Self.queueFileName)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName)
        self.lockTimeout = lockTimeout.isFinite ? max(0, min(lockTimeout, 5)) : 0.5
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func enqueue(_ action: QuickActionRoute.Action, now: Date = Date()) -> Bool {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
              let store = try? Self(directoryURL: directory) else { return false }
        return store.enqueue(action, now: now)
    }

    static func claim(now: Date = Date()) -> Claim? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
              let store = try? Self(directoryURL: directory) else { return nil }
        return try? store.claim(now: now)
    }

    static func acknowledge(_ claim: Claim) -> Bool {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
              let store = try? Self(directoryURL: directory) else { return false }
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
              let seconds = Self.integerSeconds(now) else { return false }
        do {
            try withExclusiveLock {
                var document = try read()
                prune(&document, now: seconds)
                guard !document.entries.contains(where: { $0.id == route.id }) else { return }
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
    func claim(now: Date = Date()) throws -> Claim? {
        guard let seconds = Self.integerSeconds(now) else { throw QueueError.invalidClock }
        return try withExclusiveLock {
            var document = try read()
            let before = document.entries
            prune(&document, now: seconds)
            if document.entries != before { try write(document) }
            guard let index = document.entries.firstIndex(where: {
                guard let until = $0.claimUntil else { return true }
                return until <= seconds
            }) else { return nil }
            let token = UUID().uuidString.lowercased()
            guard !seconds.addingReportingOverflow(Self.claimLease).overflow else { throw QueueError.invalidClock }
            document.entries[index].claimToken = token
            document.entries[index].claimUntil = seconds.addingReportingOverflow(Self.claimLease).partialValue
            try write(document)
            guard let url = URL(string: document.entries[index].url) else { throw QueueError.corrupt }
            return Claim(id: document.entries[index].id, token: token, url: url)
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
            document.entries.remove(at: index)
            try write(document)
            return true
        }
    }

    private func prune(_ document: inout Document, now: Int64) {
        document.entries.removeAll { entry in
            guard now >= entry.enqueuedAt else { return false }
            let age = now.subtractingReportingOverflow(entry.enqueuedAt)
            return age.overflow || age.partialValue > Self.maximumEntryAge
        }
    }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return Document() }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: queueURL))
            guard document.schemaVersion == Document.currentSchema,
                  document.entries.count <= Self.maximumEntries,
                  Set(document.entries.map(\.id)).count == document.entries.count,
                  document.entries.allSatisfy(validEntry) else { throw QueueError.corrupt }
            return document
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.corrupt
        }
    }

    private func validEntry(_ entry: Entry) -> Bool {
        guard isCanonicalUUID(entry.id),
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

    private func write(_ document: Document) throws {
        guard document.entries.count <= Self.maximumEntries else { throw QueueError.corrupt }
        do {
            try JSONEncoder().encode(document).write(to: queueURL, options: [.atomic])
        } catch {
            throw QueueError.unavailable
        }
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
