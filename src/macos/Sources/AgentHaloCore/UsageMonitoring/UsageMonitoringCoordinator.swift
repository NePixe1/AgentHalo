import Foundation

public actor UsageMonitoringCoordinator {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let staleInterval: TimeInterval = 10 * 60
    private static let defaultCooldown: TimeInterval = 5 * 60

    private let providers: [UsageProviderID: any UsageProvider]
    private let cache: UsageSnapshotCache
    private let now: @Sendable () -> Date

    private var states: [UsageProviderID: UsageMonitorState] = [:]
    private var inFlight: [UsageProviderID: Task<UsageMonitorState, Never>] = [:]
    private var cooldownUntil: [AccountCacheKey: Date] = [:]

    private var activeAccountKeys: [UsageProviderID: AccountCacheKey] = [:]
    private var resolvedAccess: [UsageProviderID: ResolvedProviderAccess] = [:]
    private var currentRunSnapshotKeys: Set<AccountCacheKey> = []
    private var refreshTokens: [UsageProviderID: UUID] = [:]

    public init(
        providers: [any UsageProvider],
        cache: UsageSnapshotCache,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providers = Dictionary(
            providers.map { ($0.providerID, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        self.cache = cache
        self.now = now
    }

    public func prepare(_ providerID: UsageProviderID) async -> UsageMonitorState {
        guard let provider = providers[providerID] else {
            return publishAPIKeyState(providerID)
        }

        // A transient cache read failure must not prevent credential resolution
        // or a later network refresh; UsageSnapshotCache retries failed loads.
        try? await cache.loadIfNeeded()
        let previousKey = activeAccountKeys[providerID]
        let access = await provider.resolveAccess(accountKey: previousKey)
        resolvedAccess[providerID] = access

        switch access {
        case .apiKey:
            return publishAPIKeyState(providerID)

        case .oauthNeedsSignIn(let accountKey):
            activeAccountKeys[providerID] = accountKey
            let snapshot = await snapshotForPrepare(
                providerID: providerID,
                accountKey: accountKey
            )
            let state = UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: snapshot,
                status: .signInAgain,
                lastFailure: .signInAgain,
                isRefreshing: inFlight[providerID] != nil
            )
            states[providerID] = state
            return state

        case .oauth(let oauthAccess):
            let accountKey = oauthAccess.accountKey
            let previousState = states[providerID]
            let isSameAccount = previousKey == accountKey
            activeAccountKeys[providerID] = accountKey

            let cached = try? await cache.snapshot(for: accountKey)
            if cached?.isFromCurrentRun == true {
                currentRunSnapshotKeys.insert(accountKey)
            }
            let snapshot = cached?.snapshot
                ?? (isSameAccount ? previousState?.snapshot : nil)
            let preservedFailure = isSameAccount ? previousState?.lastFailure : nil
            let state = UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: snapshot,
                status: status(
                    for: snapshot,
                    isFromCurrentRun: currentRunSnapshotKeys.contains(accountKey),
                    failure: preservedFailure
                ),
                lastFailure: preservedFailure,
                isRefreshing: inFlight[providerID] != nil
            )
            states[providerID] = state
            return state
        }
    }

    public func ensureFresh(_ providerID: UsageProviderID) async -> UsageMonitorState {
        let prepared = await prepare(providerID)
        guard case .oauth(let access) = resolvedAccess[providerID] else {
            return prepared
        }

        if let task = inFlight[providerID], let token = refreshTokens[providerID] {
            let result = await task.value
            return finishRefresh(result, providerID: providerID, accountKey: access.accountKey, token: token)
        }

        if let snapshot = prepared.snapshot,
           currentRunSnapshotKeys.contains(snapshot.accountKey),
           prepared.lastFailure == nil,
           now().timeIntervalSince(snapshot.refreshedAt) < Self.refreshInterval {
            return prepared
        }

        if let retryAt = cooldownUntil[access.accountKey], now() < retryAt {
            return prepared
        }
        cooldownUntil.removeValue(forKey: access.accountKey)

        var refreshing = prepared
        refreshing.isRefreshing = true
        states[providerID] = refreshing

        let token = UUID()
        let provider = providers[providerID]!
        let cache = cache
        let task = Task<UsageMonitorState, Never> {
            let result = await provider.refresh(using: .oauth(access))
            guard !Task.isCancelled else {
                var cancelled = prepared
                cancelled.isRefreshing = false
                return cancelled
            }
            return await Self.makeRefreshState(
                result: result,
                providerID: providerID,
                retainedSnapshot: prepared.snapshot,
                cache: cache
            )
        }
        inFlight[providerID] = task
        refreshTokens[providerID] = token

        let result = await task.value
        return finishRefresh(result, providerID: providerID, accountKey: access.accountKey, token: token)
    }

    public func state(for providerID: UsageProviderID) -> UsageMonitorState {
        guard var state = states[providerID] else {
            return UsageMonitorState(providerID: providerID, accessMode: .apiKey)
        }
        guard state.accessMode == .oauth,
              state.status != .signInAgain,
              state.lastFailure == nil,
              let snapshot = state.snapshot,
              now().timeIntervalSince(snapshot.refreshedAt) > Self.staleInterval
        else {
            return state
        }
        state.status = .stale(updatedAt: snapshot.refreshedAt)
        states[providerID] = state
        return state
    }

    public func cancelAll() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        refreshTokens.removeAll()
        for providerID in states.keys {
            states[providerID]?.isRefreshing = false
        }
    }

    public static func live(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> UsageMonitoringCoordinator {
        let environment = ProcessInfoUsageEnvironment()
        let files = FilesystemUsageFiles()
        let processRunner = ProcessUsageRunner()
        let keychain = SecurityUsageKeychain(processRunner: processRunner)
        let http = URLSessionUsageHTTPClient(fixedHost: "official usage endpoints")

        let codexAuthStore = CodexAuthStore(
            environment: environment,
            files: files,
            keychain: keychain
        )
        let claudeAuthStore = ClaudeAuthStore(
            environment: environment,
            files: files,
            keychain: keychain
        )
        let codexProvider = CodexUsageProvider(
            authStore: codexAuthStore,
            usageClient: CodexUsageClient(http: http)
        )
        let claudeProvider = ClaudeUsageProvider(
            authStore: claudeAuthStore,
            usageClient: ClaudeUsageClient(http: http)
        )
        let cacheURL = homeDirectory
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("usage-snapshots-v1.json")
        let cache = UsageSnapshotCache(cacheURL: cacheURL, files: files)
        return UsageMonitoringCoordinator(
            providers: [codexProvider, claudeProvider],
            cache: cache
        )
    }

    private func publishAPIKeyState(_ providerID: UsageProviderID) -> UsageMonitorState {
        activeAccountKeys.removeValue(forKey: providerID)
        resolvedAccess[providerID] = .apiKey
        let state = UsageMonitorState(providerID: providerID, accessMode: .apiKey)
        states[providerID] = state
        return state
    }

    private func snapshotForPrepare(
        providerID: UsageProviderID,
        accountKey: AccountCacheKey?
    ) async -> UsageSnapshot? {
        guard let accountKey else { return nil }
        let cached = try? await cache.snapshot(for: accountKey)
        if cached?.isFromCurrentRun == true {
            currentRunSnapshotKeys.insert(accountKey)
        }
        if let snapshot = cached?.snapshot { return snapshot }
        guard activeAccountKeys[providerID] == accountKey,
              states[providerID]?.snapshot?.accountKey == accountKey
        else {
            return nil
        }
        return states[providerID]?.snapshot
    }

    private func status(
        for snapshot: UsageSnapshot?,
        isFromCurrentRun: Bool,
        failure: UsageFailureReason?
    ) -> UsageDataStatus {
        if failure == .signInAgain { return .signInAgain }
        if failure != nil {
            return snapshot.map { .stale(updatedAt: $0.refreshedAt) } ?? .noData
        }
        guard let snapshot else { return .noData }
        if !isFromCurrentRun || now().timeIntervalSince(snapshot.refreshedAt) > Self.staleInterval {
            return .stale(updatedAt: snapshot.refreshedAt)
        }
        return .fresh(updatedAt: snapshot.refreshedAt)
    }

    private func finishRefresh(
        _ result: UsageMonitorState,
        providerID: UsageProviderID,
        accountKey: AccountCacheKey,
        token: UUID
    ) -> UsageMonitorState {
        guard refreshTokens[providerID] == token else {
            return state(for: providerID)
        }
        inFlight.removeValue(forKey: providerID)
        refreshTokens.removeValue(forKey: providerID)

        var result = result
        result.isRefreshing = false
        switch result.lastFailure {
        case .rateLimited(let retryAt):
            cooldownUntil[accountKey] = retryAt ?? now().addingTimeInterval(Self.defaultCooldown)
        case nil:
            cooldownUntil.removeValue(forKey: accountKey)
            if let snapshot = result.snapshot {
                activeAccountKeys[providerID] = snapshot.accountKey
                currentRunSnapshotKeys.insert(snapshot.accountKey)
                cooldownUntil.removeValue(forKey: snapshot.accountKey)
            }
        default:
            break
        }
        states[providerID] = result
        return result
    }

    private static func makeRefreshState(
        result: UsageRefreshResult,
        providerID: UsageProviderID,
        retainedSnapshot: UsageSnapshot?,
        cache: UsageSnapshotCache
    ) async -> UsageMonitorState {
        if let failure = result.failure {
            let mapped = mapFailure(failure)
            return UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: retainedSnapshot,
                status: failureStatus(mapped, snapshot: retainedSnapshot),
                lastFailure: mapped
            )
        }

        guard let snapshot = result.snapshot,
              result.providerID == providerID,
              snapshot.providerID == providerID,
              snapshot.accountKey.providerID == providerID
        else {
            return UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: retainedSnapshot,
                status: failureStatus(.invalidResponse, snapshot: retainedSnapshot),
                lastFailure: .invalidResponse
            )
        }

        if let oldKey = result.migrateCacheFrom {
            try? await cache.migrate(from: oldKey, to: snapshot.accountKey)
        }
        // Cache persistence is best-effort for the current response. The cache
        // actor updates its in-memory entry before attempting the disk write.
        try? await cache.store(snapshot)
        return UsageMonitorState(
            providerID: providerID,
            accessMode: .oauth,
            snapshot: snapshot,
            status: .fresh(updatedAt: snapshot.refreshedAt),
            lastFailure: nil
        )
    }

    private static func mapFailure(_ failure: UsageProviderFailure) -> UsageFailureReason {
        switch failure {
        case .rateLimited(let retryAt):
            return .rateLimited(retryAt: retryAt)
        case .network:
            return .network
        case .serviceUnavailable:
            return .serviceUnavailable
        case .invalidResponse:
            return .invalidResponse
        case .signInAgain:
            return .signInAgain
        }
    }

    private static func failureStatus(
        _ failure: UsageFailureReason,
        snapshot: UsageSnapshot?
    ) -> UsageDataStatus {
        if failure == .signInAgain { return .signInAgain }
        return snapshot.map { .stale(updatedAt: $0.refreshedAt) } ?? .noData
    }
}
