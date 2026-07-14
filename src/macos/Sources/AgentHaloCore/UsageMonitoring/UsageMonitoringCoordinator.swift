import Foundation

public actor UsageMonitoringCoordinator {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let staleInterval: TimeInterval = 10 * 60
    private static let defaultCooldown: TimeInterval = 5 * 60

    private struct AccessSignature: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            case apiKey
            case oauth
            case oauthNeedsSignIn
        }

        let mode: Mode
        let accountKey: AccountCacheKey?
        let sourceVersion: String?
    }

    private struct PrepareContext: Sendable {
        var state: UsageMonitorState
        var access: ResolvedProviderAccess
        var signature: AccessSignature
        var generation: UInt64
    }

    private struct InFlightRecord {
        let accountKey: AccountCacheKey
        let generation: UInt64
        let signature: AccessSignature
        let token: UUID
        let task: Task<UsageRefreshResult, Never>
    }

    private let providers: [UsageProviderID: any UsageProvider]
    private let cache: UsageSnapshotCache
    private let now: @Sendable () -> Date

    private var states: [UsageProviderID: UsageMonitorState] = [:]
    private var contexts: [UsageProviderID: PrepareContext] = [:]
    private var inFlight: [UsageProviderID: InFlightRecord] = [:]
    private var cooldownUntil: [AccountCacheKey: Date] = [:]
    private var currentRunSnapshotKeys: Set<AccountCacheKey> = []
    private var prepareSequences: [UsageProviderID: UInt64] = [:]
    private var generationCounters: [UsageProviderID: UInt64] = [:]

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
        await prepareContext(providerID).state
    }

    public func ensureFresh(_ providerID: UsageProviderID) async -> UsageMonitorState {
        let prepared = await prepareContext(providerID)
        guard case .oauth(let access) = prepared.access else {
            return prepared.state
        }

        if let record = inFlight[providerID] {
            if record.accountKey == access.accountKey,
               record.generation == prepared.generation,
               record.signature == prepared.signature {
                let result = await record.task.value
                return await finishRefresh(result, providerID: providerID, expected: record)
            }
            invalidateInFlight(providerID)
        }

        if let snapshot = prepared.state.snapshot,
           currentRunSnapshotKeys.contains(snapshot.accountKey),
           prepared.state.lastFailure == nil,
           now().timeIntervalSince(snapshot.refreshedAt) <= Self.refreshInterval {
            return prepared.state
        }

        if let retryAt = cooldownUntil[access.accountKey], now() < retryAt {
            return prepared.state
        }
        cooldownUntil.removeValue(forKey: access.accountKey)

        var refreshing = prepared
        refreshing.state.isRefreshing = true
        commit(refreshing, for: providerID)

        let token = UUID()
        let provider = providers[providerID]!
        let task = Task<UsageRefreshResult, Never> {
            await provider.refresh(using: .oauth(access))
        }
        let record = InFlightRecord(
            accountKey: access.accountKey,
            generation: refreshing.generation,
            signature: refreshing.signature,
            token: token,
            task: task
        )
        inFlight[providerID] = record

        let result = await task.value
        return await finishRefresh(result, providerID: providerID, expected: record)
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
        contexts[providerID]?.state = state
        return state
    }

    public func cancelAll() {
        for providerID in Array(inFlight.keys) {
            invalidateInFlight(providerID)
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

    private func prepareContext(_ providerID: UsageProviderID) async -> PrepareContext {
        let sequence = nextPrepareSequence(for: providerID)
        guard let provider = providers[providerID] else {
            return commitResolvedAccess(.apiKey, providerID: providerID, sequence: sequence)
        }

        try? await cache.loadIfNeeded()
        let previousAccount = contexts[providerID]?.signature.accountKey
        let access = await provider.resolveAccess(accountKey: previousAccount)

        guard prepareSequences[providerID] == sequence else {
            return currentContextOrAPIKey(providerID)
        }

        let initial = commitResolvedAccess(access, providerID: providerID, sequence: sequence)
        guard let accountKey = initial.signature.accountKey else {
            return initial
        }

        let cached = try? await cache.snapshot(for: accountKey)
        guard prepareSequences[providerID] == sequence,
              let current = contexts[providerID],
              current.generation == initial.generation,
              current.signature == initial.signature
        else {
            return currentContextOrAPIKey(providerID)
        }

        if cached?.isFromCurrentRun == true {
            currentRunSnapshotKeys.insert(accountKey)
        }
        let snapshot = cached?.snapshot ?? initial.state.snapshot
        var completed = initial
        completed.state.snapshot = snapshot
        completed.state.isRefreshing = matchingInFlight(
            providerID: providerID,
            context: completed
        ) != nil

        switch access {
        case .apiKey:
            break
        case .oauthNeedsSignIn:
            completed.state.status = .signInAgain
            completed.state.lastFailure = .signInAgain
        case .oauth:
            completed.state.status = status(
                for: snapshot,
                isFromCurrentRun: currentRunSnapshotKeys.contains(accountKey),
                failure: completed.state.lastFailure
            )
        }
        commit(completed, for: providerID)
        return completed
    }

    private func commitResolvedAccess(
        _ access: ResolvedProviderAccess,
        providerID: UsageProviderID,
        sequence: UInt64
    ) -> PrepareContext {
        guard prepareSequences[providerID] == sequence else {
            return currentContextOrAPIKey(providerID)
        }

        let signature = Self.signature(for: access)
        let previous = contexts[providerID]
        let generation: UInt64
        if previous?.signature == signature {
            generation = previous!.generation
        } else {
            generation = nextGeneration(for: providerID)
            invalidateInFlight(providerID)
        }

        let sameAccount = previous?.signature.accountKey == signature.accountKey
        let retainedSnapshot = sameAccount ? previous?.state.snapshot : nil
        let retainedFailure = sameAccount ? previous?.state.lastFailure : nil
        let isRefreshing = inFlight[providerID].map {
            $0.accountKey == signature.accountKey
                && $0.generation == generation
                && $0.signature == signature
        } ?? false

        let state: UsageMonitorState
        switch access {
        case .apiKey:
            state = UsageMonitorState(providerID: providerID, accessMode: .apiKey)
        case .oauthNeedsSignIn:
            state = UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: retainedSnapshot,
                status: .signInAgain,
                lastFailure: .signInAgain,
                isRefreshing: isRefreshing
            )
        case .oauth(let oauthAccess):
            state = UsageMonitorState(
                providerID: providerID,
                accessMode: .oauth,
                snapshot: retainedSnapshot,
                status: status(
                    for: retainedSnapshot,
                    isFromCurrentRun: currentRunSnapshotKeys.contains(oauthAccess.accountKey),
                    failure: retainedFailure
                ),
                lastFailure: retainedFailure,
                isRefreshing: isRefreshing
            )
        }

        let context = PrepareContext(
            state: state,
            access: access,
            signature: signature,
            generation: generation
        )
        commit(context, for: providerID)
        return context
    }

    private func finishRefresh(
        _ result: UsageRefreshResult,
        providerID: UsageProviderID,
        expected: InFlightRecord
    ) async -> UsageMonitorState {
        guard isCurrent(expected, providerID: providerID),
              let context = contexts[providerID]
        else {
            return state(for: providerID)
        }

        if let failure = result.failure {
            return finishFailure(
                Self.mapFailure(failure),
                providerID: providerID,
                context: context,
                expected: expected
            )
        }

        guard let snapshot = result.snapshot,
              result.providerID == providerID,
              snapshot.providerID == providerID,
              snapshot.accountKey.providerID == providerID,
              result.migrateCacheFrom == nil
                || result.migrateCacheFrom == expected.accountKey,
              snapshot.accountKey == expected.accountKey
                || result.migrateCacheFrom == expected.accountKey
        else {
            return finishFailure(
                .invalidResponse,
                providerID: providerID,
                context: context,
                expected: expected
            )
        }

        if let oldKey = result.migrateCacheFrom {
            try? await cache.migrate(from: oldKey, to: snapshot.accountKey)
        }
        guard isCurrent(expected, providerID: providerID) else {
            return state(for: providerID)
        }
        try? await cache.store(snapshot)
        guard isCurrent(expected, providerID: providerID) else {
            return state(for: providerID)
        }

        inFlight.removeValue(forKey: providerID)
        cooldownUntil.removeValue(forKey: expected.accountKey)
        cooldownUntil.removeValue(forKey: snapshot.accountKey)
        currentRunSnapshotKeys.insert(snapshot.accountKey)

        var completed = context
        completed.state = UsageMonitorState(
            providerID: providerID,
            accessMode: .oauth,
            snapshot: snapshot,
            status: .fresh(updatedAt: snapshot.refreshedAt),
            lastFailure: nil,
            isRefreshing: false
        )

        if snapshot.accountKey != expected.accountKey,
           case .oauth(var access) = completed.access {
            access.accountKey = snapshot.accountKey
            completed.access = .oauth(access)
            completed.signature = Self.signature(for: completed.access)
            completed.generation = nextGeneration(for: providerID)
        }
        commit(completed, for: providerID)
        return completed.state
    }

    private func finishFailure(
        _ failure: UsageFailureReason,
        providerID: UsageProviderID,
        context: PrepareContext,
        expected: InFlightRecord
    ) -> UsageMonitorState {
        guard isCurrent(expected, providerID: providerID) else {
            return state(for: providerID)
        }
        inFlight.removeValue(forKey: providerID)
        if case .rateLimited(let retryAt) = failure {
            cooldownUntil[expected.accountKey] = retryAt
                ?? now().addingTimeInterval(Self.defaultCooldown)
        }

        var failed = context
        failed.state.lastFailure = failure
        failed.state.status = Self.failureStatus(failure, snapshot: context.state.snapshot)
        failed.state.isRefreshing = false
        commit(failed, for: providerID)
        return failed.state
    }

    private func matchingInFlight(
        providerID: UsageProviderID,
        context: PrepareContext
    ) -> InFlightRecord? {
        guard let record = inFlight[providerID],
              record.accountKey == context.signature.accountKey,
              record.generation == context.generation,
              record.signature == context.signature
        else {
            return nil
        }
        return record
    }

    private func isCurrent(
        _ expected: InFlightRecord,
        providerID: UsageProviderID
    ) -> Bool {
        guard let record = inFlight[providerID],
              record.token == expected.token,
              record.accountKey == expected.accountKey,
              record.generation == expected.generation,
              record.signature == expected.signature,
              let context = contexts[providerID],
              context.generation == expected.generation,
              context.signature == expected.signature,
              context.signature.accountKey == expected.accountKey
        else {
            return false
        }
        return true
    }

    private func invalidateInFlight(_ providerID: UsageProviderID) {
        inFlight.removeValue(forKey: providerID)?.task.cancel()
        states[providerID]?.isRefreshing = false
        contexts[providerID]?.state.isRefreshing = false
    }

    private func commit(_ context: PrepareContext, for providerID: UsageProviderID) {
        contexts[providerID] = context
        states[providerID] = context.state
    }

    private func currentContextOrAPIKey(_ providerID: UsageProviderID) -> PrepareContext {
        if let context = contexts[providerID] {
            return context
        }
        return PrepareContext(
            state: UsageMonitorState(providerID: providerID, accessMode: .apiKey),
            access: .apiKey,
            signature: AccessSignature(mode: .apiKey, accountKey: nil, sourceVersion: nil),
            generation: generationCounters[providerID] ?? 0
        )
    }

    private func nextPrepareSequence(for providerID: UsageProviderID) -> UInt64 {
        let next = (prepareSequences[providerID] ?? 0) &+ 1
        prepareSequences[providerID] = next
        return next
    }

    private func nextGeneration(for providerID: UsageProviderID) -> UInt64 {
        let next = (generationCounters[providerID] ?? 0) &+ 1
        generationCounters[providerID] = next
        return next
    }

    private static func signature(for access: ResolvedProviderAccess) -> AccessSignature {
        switch access {
        case .apiKey:
            return AccessSignature(mode: .apiKey, accountKey: nil, sourceVersion: nil)
        case .oauthNeedsSignIn(let accountKey):
            return AccessSignature(
                mode: .oauthNeedsSignIn,
                accountKey: accountKey,
                sourceVersion: nil
            )
        case .oauth(let access):
            return AccessSignature(
                mode: .oauth,
                accountKey: access.accountKey,
                sourceVersion: access.sourceVersion
            )
        }
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
