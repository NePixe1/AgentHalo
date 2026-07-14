import Foundation

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

            if let live = await Task.detached(operation: { [authStore] in
                authStore.reload(source: initialAccess.source)
            }).value {
                adoptedExternalSource = live.sourceVersion != initialAccess.sourceVersion
                current = live
            }

            let refreshCandidate = current
            let needsProactiveRefresh = await Task.detached(operation: { [authStore] in
                authStore.needsRefresh(refreshCandidate)
            }).value
            if needsProactiveRefresh {
                let rotated = try await rotate(current, allowMigration: !adoptedExternalSource)
                current = rotated.access
                migrateCacheFrom = rotated.migrateCacheFrom
                adoptedExternalSource = adoptedExternalSource || rotated.adoptedExternalSource
            }

            var response = try await usageClient.fetchUsage(accessToken: current.accessToken)
            var secondUnauthorized = false
            if response.statusCode == 401 {
                let rotated = try await rotate(current, allowMigration: !adoptedExternalSource)
                current = rotated.access
                migrateCacheFrom = migrateCacheFrom ?? rotated.migrateCacheFrom
                adoptedExternalSource = adoptedExternalSource || rotated.adoptedExternalSource
                response = try await usageClient.fetchUsage(accessToken: current.accessToken)
                secondUnauthorized = response.statusCode == 401
            }

            let responseCandidate = current
            if let live = await Task.detached(operation: { [authStore] in
                authStore.reload(source: responseCandidate.source)
            }).value,
               live.sourceVersion != responseCandidate.sourceVersion {
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
            if secondUnauthorized {
                return failure(.signInAgain)
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
    ) async throws -> (
        access: OAuthAccess,
        migrateCacheFrom: AccountCacheKey?,
        adoptedExternalSource: Bool
    ) {
        guard let refreshToken = expected.refreshToken, !refreshToken.isEmpty else {
            throw UsageProviderFailure.signInAgain
        }
        let response = try await usageClient.refreshToken(refreshToken)
        let rotation = try Self.rotation(from: response, now: now())
        var inMemory = Self.rotatedAccess(rotation, replacing: expected)

        var persistedAccess: OAuthAccess?
        do {
            if let persisted = try await Task.detached(operation: { [authStore] in
                try authStore.persist(rotation: rotation, replacing: expected)
            }).value {
                inMemory = persisted
                persistedAccess = persisted
            }
        } catch {
            NSLog("[ClaudeUsage] rotated credential writeback failed; continuing in memory")
        }

        if persistedAccess == nil,
           let live = await Task.detached(operation: { [authStore] in
               authStore.reload(source: expected.source)
           }).value,
           live.sourceVersion != expected.sourceVersion {
            return (live, nil, true)
        }

        let migration = allowMigration && inMemory.accountKey != expected.accountKey
            ? expected.accountKey
            : nil
        return (inMemory, migration, false)
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
