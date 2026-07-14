import Foundation

private enum ClaudeGenerationChecked<Value: Sendable>: Sendable {
    case value(Value)
    case restarted(UsageRefreshResult)
    case failure(UsageProviderFailure)
}

public struct ClaudeUsageProvider: UsageProvider, Sendable {
    public let providerID: UsageProviderID = .claude

    private let authStore: ClaudeAuthStore
    private let usageClient: ClaudeUsageClient
    private let now: @Sendable () -> Date

    public init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    public func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess {
        await Task.detached { [authStore] in
            authStore.resolveAccess()
        }.value
    }

    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let initialAccess) = access else {
            return failure(.signInAgain)
        }
        return await refresh(initialAccess: initialAccess, externalReloadsRemaining: 1)
    }

    private func refresh(
        initialAccess: OAuthAccess,
        externalReloadsRemaining: Int
    ) async -> UsageRefreshResult {
        do {
            var current = initialAccess
            var migrateCacheFrom: AccountCacheKey?
            var adoptedExternalSource = false

            let exactAccess = await Task.detached(operation: { [authStore] in
                authStore.reloadResolved(source: initialAccess.source)
            }).value
            switch exactAccess {
            case .oauth(let live):
                adoptedExternalSource = live.sourceVersion != initialAccess.sourceVersion
                current = live
            case .oauthNeedsSignIn, .apiKey:
                return failure(.signInAgain)
            }

            let refreshCandidate = current
            let needsProactiveRefresh = await Task.detached(operation: { [authStore] in
                authStore.needsRefresh(refreshCandidate)
            }).value
            if needsProactiveRefresh {
                let requestCandidate = current
                let allowMigration = !adoptedExternalSource
                let checked = await generationChecked(
                    candidate: requestCandidate,
                    externalReloadsRemaining: externalReloadsRemaining,
                    successCandidate: { $0.access },
                    operation: { try await rotate(requestCandidate, allowMigration: allowMigration) }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checked {
                case .value(let value):
                    rotated = value
                case .restarted(let result):
                    return result
                case .failure(let failure):
                    return self.failure(failure)
                }
                current = rotated.access
                migrateCacheFrom = rotated.migrateCacheFrom
            }

            let firstUsageCandidate = current
            let firstUsage = await generationChecked(
                candidate: firstUsageCandidate,
                externalReloadsRemaining: externalReloadsRemaining,
                successCandidate: { _ in firstUsageCandidate },
                operation: {
                    try await usageClient.fetchUsage(accessToken: firstUsageCandidate.accessToken)
                }
            )
            var response: UsageHTTPResponse
            switch firstUsage {
            case .value(let value):
                response = value
            case .restarted(let result):
                return result
            case .failure(let failure):
                return self.failure(failure)
            }
            if response.statusCode == 401 {
                let requestCandidate = current
                let allowMigration = !adoptedExternalSource
                let checkedRotation = await generationChecked(
                    candidate: requestCandidate,
                    externalReloadsRemaining: externalReloadsRemaining,
                    successCandidate: { $0.access },
                    operation: { try await rotate(requestCandidate, allowMigration: allowMigration) }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checkedRotation {
                case .value(let value):
                    rotated = value
                case .restarted(let result):
                    return result
                case .failure(let failure):
                    return self.failure(failure)
                }
                current = rotated.access
                migrateCacheFrom = migrateCacheFrom ?? rotated.migrateCacheFrom
                let secondUsageCandidate = current
                let secondUsage = await generationChecked(
                    candidate: secondUsageCandidate,
                    externalReloadsRemaining: externalReloadsRemaining,
                    successCandidate: { _ in secondUsageCandidate },
                    operation: {
                        try await usageClient.fetchUsage(accessToken: secondUsageCandidate.accessToken)
                    }
                )
                switch secondUsage {
                case .value(let value):
                    response = value
                case .restarted(let result):
                    return result
                case .failure(let failure):
                    return self.failure(failure)
                }
                if response.statusCode == 401 { return failure(.signInAgain) }
            }

            let snapshot = try ClaudeUsageMapper.map(
                response: response,
                accountKey: current.accountKey,
                planHint: current.planHint,
                now: now()
            )
            return UsageRefreshResult(
                providerID: providerID,
                snapshot: snapshot,
                failure: nil,
                migrateCacheFrom: migrateCacheFrom
            )
        } catch let failure as UsageProviderFailure {
            return self.failure(failure)
        } catch {
            return failure(.network)
        }
    }

    private func rotate(
        _ expected: OAuthAccess,
        allowMigration: Bool
    ) async throws -> (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?) {
        guard let refreshToken = expected.refreshToken, !refreshToken.isEmpty else {
            throw UsageProviderFailure.signInAgain
        }
        let response = try await usageClient.refreshToken(refreshToken)
        let rotation = try Self.rotation(from: response, now: now())
        var inMemory = Self.rotatedAccess(rotation, replacing: expected)

        do {
            if let persisted = try await Task.detached(operation: { [authStore] in
                try authStore.persist(rotation: rotation, replacing: expected)
            }).value {
                inMemory = persisted
            }
        } catch {
            NSLog("[ClaudeUsage] rotated credential writeback failed; continuing in memory")
        }

        let migration = allowMigration && inMemory.accountKey != expected.accountKey
            ? expected.accountKey
            : nil
        return (inMemory, migration)
    }

    private func generationChecked<Value: Sendable>(
        candidate: OAuthAccess,
        externalReloadsRemaining: Int,
        successCandidate: @Sendable (Value) -> OAuthAccess,
        operation: @Sendable () async throws -> Value
    ) async -> ClaudeGenerationChecked<Value> {
        do {
            let value = try await operation()
            if let restarted = await restartIfGenerationChanged(
                since: successCandidate(value),
                externalReloadsRemaining: externalReloadsRemaining
            ) {
                return .restarted(restarted)
            }
            return .value(value)
        } catch let failure as UsageProviderFailure {
            if let restarted = await restartIfGenerationChanged(
                since: candidate,
                externalReloadsRemaining: externalReloadsRemaining
            ) {
                return .restarted(restarted)
            }
            return .failure(failure)
        } catch {
            if let restarted = await restartIfGenerationChanged(
                since: candidate,
                externalReloadsRemaining: externalReloadsRemaining
            ) {
                return .restarted(restarted)
            }
            return .failure(.network)
        }
    }

    private func restartIfGenerationChanged(
        since candidate: OAuthAccess,
        externalReloadsRemaining: Int
    ) async -> UsageRefreshResult? {
        let exactAccess = await Task.detached(operation: { [authStore] in
            authStore.reloadResolved(source: candidate.source)
        }).value
        let live: OAuthAccess
        switch exactAccess {
        case .oauth(let access):
            guard access.sourceVersion != candidate.sourceVersion else { return nil }
            live = access
        case .oauthNeedsSignIn, .apiKey:
            return failure(.signInAgain)
        }
        guard externalReloadsRemaining > 0 else {
            return failure(.signInAgain)
        }
        let restarted = await refresh(
            initialAccess: live,
            externalReloadsRemaining: externalReloadsRemaining - 1
        )
        return UsageRefreshResult(
            providerID: providerID,
            snapshot: restarted.snapshot,
            failure: restarted.failure,
            migrateCacheFrom: nil
        )
    }

    private func failure(_ failure: UsageProviderFailure) -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, snapshot: nil, failure: failure)
    }

    private static func rotation(
        from response: UsageHTTPResponse,
        now: Date
    ) throws -> ClaudeTokenRotation {
        switch response.statusCode {
        case 200..<300:
            break
        case 400, 401:
            if requiresSignIn(response.body) {
                throw UsageProviderFailure.signInAgain
            }
            throw UsageProviderFailure.invalidResponse
        case 429:
            throw UsageProviderFailure.rateLimited(
                retryAt: ClaudeUsageMapper.retryAfterDate(response, now: now)
            )
        case 500...599:
            throw UsageProviderFailure.serviceUnavailable
        default:
            throw UsageProviderFailure.invalidResponse
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let accessToken = nonemptyString(object["access_token"])
        else {
            throw UsageProviderFailure.invalidResponse
        }
        let expiresAt = number(object["expires_in"]).map { now.addingTimeInterval($0) }
        return ClaudeTokenRotation(
            accessToken: accessToken,
            refreshToken: nonemptyString(object["refresh_token"]),
            expiresAt: expiresAt
        )
    }

    private static func rotatedAccess(
        _ rotation: ClaudeTokenRotation,
        replacing expected: OAuthAccess
    ) -> OAuthAccess {
        let refreshToken = rotation.refreshToken ?? expected.refreshToken
        let identityToken = refreshToken ?? rotation.accessToken
        let accountDigest = UsageDigest.sha256(
            "\(sourceIdentity(expected.source))|\(UsageDigest.sha256(identityToken))"
        )
        return OAuthAccess(
            providerID: .claude,
            accountKey: AccountCacheKey(providerID: .claude, digest: accountDigest),
            source: expected.source,
            sourceVersion: expected.sourceVersion,
            accessToken: rotation.accessToken,
            refreshToken: refreshToken,
            expiresAt: rotation.expiresAt,
            accountID: nil,
            planHint: expected.planHint
        )
    }

    private static func sourceIdentity(_ source: CredentialSource) -> String {
        switch source {
        case .file(let path):
            return path
        case .keychain(let service, let account):
            return account.map { "\(service)|\($0)" } ?? service
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requiresSignIn(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let code: String?
        if let error = object["error"] as? [String: Any] {
            code = nonemptyString(error["code"])
                ?? nonemptyString(error["type"])
                ?? nonemptyString(error["error"])
        } else {
            code = nonemptyString(object["error"])
                ?? nonemptyString(object["error_description"])
                ?? nonemptyString(object["code"])
        }
        return code == "invalid_grant"
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }
}
