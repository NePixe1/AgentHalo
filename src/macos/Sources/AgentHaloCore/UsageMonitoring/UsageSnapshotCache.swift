import Foundation

public struct CachedUsageSnapshot: Equatable, Sendable {
    public var snapshot: UsageSnapshot
    public var isFromCurrentRun: Bool
}

/// Provider-and-account scoped persistence for the last successful usage
/// snapshots. The payload only contains provider-neutral usage models; raw
/// credentials, requests and responses never enter this API.
public actor UsageSnapshotCache {
    private static let schemaVersion = 1
    private static let maximumAccountsPerProvider = 3
    private static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60

    private let cacheURL: URL
    private let files: any UsageFileAccessing
    private let now: @Sendable () -> Date

    private var didLoad = false
    private var hasPersistedFile = false
    private var entries: [AccountCacheKey: CacheEntry] = [:]
    private var currentRunKeys: Set<AccountCacheKey> = []

    public init(
        cacheURL: URL,
        files: any UsageFileAccessing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cacheURL = cacheURL
        self.files = files
        self.now = now
    }

    public func loadIfNeeded() throws {
        guard !didLoad else { return }
        let data = try files.readDataIfPresent(at: cacheURL.path)
        didLoad = true

        guard let data else { return }
        hasPersistedFile = true

        guard
            let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
            payload.version == Self.schemaVersion
        else {
            // Corrupt and future-version payloads are deliberately ignored.
            // A later successful store replaces them with the current schema.
            return
        }

        for entry in payload.entries {
            let key = entry.snapshot.accountKey
            guard entry.snapshot.providerID == key.providerID else { continue }
            if let existing = entries[key], existing.lastAccessedAt >= entry.lastAccessedAt {
                continue
            }
            entries[key] = entry
        }

        if prune(referenceDate: now()) {
            try persist()
        }
    }

    public func snapshot(for key: AccountCacheKey) throws -> CachedUsageSnapshot? {
        try loadIfNeeded()
        let accessDate = now()
        if prune(referenceDate: accessDate) {
            try persist()
        }
        guard var entry = entries[key] else { return nil }

        entry.lastAccessedAt = accessDate
        entries[key] = entry
        return CachedUsageSnapshot(
            snapshot: entry.snapshot,
            isFromCurrentRun: currentRunKeys.contains(key)
        )
    }

    /// Stores only the successful snapshot value. Error states and provider
    /// responses have no representation in this API and therefore cannot be
    /// persisted accidentally.
    public func store(_ snapshot: UsageSnapshot) throws {
        try loadIfNeeded()
        guard snapshot.providerID == snapshot.accountKey.providerID else { return }

        let storeDate = now()
        entries[snapshot.accountKey] = CacheEntry(
            snapshot: snapshot,
            lastAccessedAt: storeDate
        )
        currentRunKeys.insert(snapshot.accountKey)
        _ = prune(referenceDate: storeDate)
        try persist()
    }

    /// Moves one exact account key during an internally verified token rotation.
    /// Cross-provider migration is refused to preserve provider isolation.
    public func migrate(from oldKey: AccountCacheKey, to newKey: AccountCacheKey) throws {
        try loadIfNeeded()
        guard oldKey.providerID == newKey.providerID else { return }

        let migrationDate = now()
        let pruned = prune(referenceDate: migrationDate)
        guard var entry = entries.removeValue(forKey: oldKey) else {
            if pruned { try persist() }
            return
        }

        entry.snapshot.accountKey = newKey
        entry.snapshot.providerID = newKey.providerID
        entry.lastAccessedAt = migrationDate
        entries[newKey] = entry

        let wasFromCurrentRun = currentRunKeys.remove(oldKey) != nil
        currentRunKeys.remove(newKey)
        if wasFromCurrentRun {
            currentRunKeys.insert(newKey)
        }

        _ = prune(referenceDate: migrationDate)
        try persist()
    }

    @discardableResult
    private func prune(referenceDate: Date) -> Bool {
        var removedKeys = Set<AccountCacheKey>()

        for (key, entry) in entries
        where referenceDate.timeIntervalSince(entry.lastAccessedAt) > Self.maximumEntryAge {
            removedKeys.insert(key)
        }

        for providerID in [UsageProviderID.codex, .claude] {
            let retainedForProvider = entries
                .filter { key, _ in
                    key.providerID == providerID && !removedKeys.contains(key)
                }
                .sorted { lhs, rhs in
                    if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                        return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
                    }
                    return lhs.key.digest < rhs.key.digest
                }
            for (key, _) in retainedForProvider.dropFirst(Self.maximumAccountsPerProvider) {
                removedKeys.insert(key)
            }
        }

        guard !removedKeys.isEmpty else { return false }
        for key in removedKeys {
            entries.removeValue(forKey: key)
            currentRunKeys.remove(key)
        }
        return true
    }

    private func persist() throws {
        try files.ensureDirectory(
            at: cacheURL.deletingLastPathComponent().path,
            mode: 0o700
        )
        let payload = CachePayload(
            version: Self.schemaVersion,
            entries: entries.values.sorted { lhs, rhs in
                let lhsKey = lhs.snapshot.accountKey
                let rhsKey = rhs.snapshot.accountKey
                if lhsKey.providerID.rawValue != rhsKey.providerID.rawValue {
                    return lhsKey.providerID.rawValue < rhsKey.providerID.rawValue
                }
                return lhsKey.digest < rhsKey.digest
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try files.writeAtomically(
            data,
            to: cacheURL.path,
            preservingModeOf: hasPersistedFile ? cacheURL.path : nil
        )
        hasPersistedFile = true
    }
}

private struct CachePayload: Codable {
    var version: Int
    var entries: [CacheEntry]
}

private struct CacheEntry: Codable {
    var snapshot: UsageSnapshot
    var lastAccessedAt: Date
}
