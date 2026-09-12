import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded cross-process file lock around the complete JSON document.
/// The lock is intentionally non-blocking: an extension suspended while holding
/// it must not hang the foreground app forever.
public final class SharedRuntimeStore: @unchecked Sendable {
    public let directoryURL: URL
    private let documentURL: URL
    private let lockURL: URL
    private let lockTimeout: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL, lockTimeout: TimeInterval = 0.5) throws {
        self.directoryURL = directoryURL
        self.documentURL = directoryURL.appendingPathComponent("runtime-state.json")
        self.lockURL = directoryURL.appendingPathComponent("runtime-state.lock")
        self.lockTimeout = lockTimeout.isFinite ? max(0, min(lockTimeout, 5)) : 0.5
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public convenience init(appGroupIdentifier: String) throws {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw RuntimeValidationError.appGroupUnavailable
        }
        try self.init(directoryURL: directory)
    }

    public var hasDocument: Bool { FileManager.default.fileExists(atPath: documentURL.path) }

    public func read() throws -> RuntimeStoreDocument {
        try withExclusiveLock { try readUnlocked() }
    }

    /// Discovery and migration share the callback lock. A callback may have
    /// created a diagnostics-only file before the app's first launch.
    public func loadOrMigrate(_ legacy: () throws -> RuntimeStoreDocument) throws -> RuntimeStoreDocument {
        try withExclusiveLock {
            var document = try readUnlocked()
            guard document.legacyMigrationCompleted != true else { return document }
            if document.configuration == nil && document.draft == nil && document.activeOwner == nil {
                let earlyDiagnostics = document.diagnostics
                document = try legacy()
                for event in earlyDiagnostics { document.record(event) }
            }
            document.legacyMigrationCompleted = true
            try write(document)
            return document
        }
    }

    /// Compatibility API for simple read/modify/write callers.
    @discardableResult
    public func transaction<T>(_ body: (inout RuntimeStoreDocument) throws -> T) throws -> T {
        try withTransaction { context in
            var document = context.document
            let result = try body(&document)
            context.document = document
            return result
        }
    }

    /// Holds the process lock across multiple durable commits and a side effect.
    /// Call `commit()` before the side effect to persist ownership/intent first,
    /// then commit the final diagnostic/state after the side effect.
    @discardableResult
    public func withTransaction<T>(_ body: (RuntimeStoreTransaction) throws -> T) throws -> T {
        try withExclusiveLock {
            let context = RuntimeStoreTransaction(store: self, document: try readUnlocked())
            let result = try body(context)
            if !context.hasCommitted { try context.commit() }
            return result
        }
    }

    /// Emergency-only reset. Persist disabled intent before clearing settings,
    /// under the same lock as monitor callbacks. Keep an empty document so a
    /// crash cannot cause old UserDefaults to be migrated a second time.
    /// Corrupt JSON does not prevent this explicitly requested cleanup.
    public func reset(performing cleanup: () -> Void = {}) throws {
        try withExclusiveLock {
            var empty = RuntimeStoreDocument()
            empty.legacyMigrationCompleted = true
            try write(empty)
            cleanup()
        }
    }

    fileprivate func write(_ document: RuntimeStoreDocument) throws {
        try document.validate()
        do {
            let data = try encoder.encode(document)
            try data.write(to: documentURL, options: [.atomic])
        } catch {
            throw RuntimeValidationError.invalidConfiguration("Unable to save shared Phone Lockbox state.")
        }
    }

    private func readUnlocked() throws -> RuntimeStoreDocument {
        guard hasDocument else { return RuntimeStoreDocument() }
        do {
            let data = try Data(contentsOf: documentURL)
            let document = try decoder.decode(RuntimeStoreDocument.self, from: data)
            try document.validate()
            // RuntimeStoreDocument upgrades older validated schemas in its
            // decoder. Persist that upgrade while holding the same lock so a
            // crash cannot leave app and monitor on different schemas.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let encodedSchema = object["schemaVersion"] as? Int,
               encodedSchema < RuntimeStoreDocument.currentSchema {
                try write(document)
            }
            return document
        } catch let error as RuntimeValidationError {
            throw error
        } catch {
            throw RuntimeValidationError.corruptSharedData
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RuntimeValidationError.concurrentStoreAccess }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            #if canImport(Darwin)
            let wouldBlock = errno == EWOULDBLOCK || errno == EAGAIN
            #else
            let wouldBlock = errno == EWOULDBLOCK || errno == EAGAIN
            #endif
            guard wouldBlock, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuntimeValidationError.concurrentStoreAccess
            }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
        #else
        return try body()
        #endif
    }
}

public final class RuntimeStoreTransaction: @unchecked Sendable {
    private let store: SharedRuntimeStore
    public var document: RuntimeStoreDocument
    fileprivate private(set) var hasCommitted = false

    fileprivate init(store: SharedRuntimeStore, document: RuntimeStoreDocument) {
        self.store = store
        self.document = document
    }

    /// Durably commits the current intent while retaining the store lock.
    public func commit() throws {
        try store.write(document)
        hasCommitted = true
    }
}
