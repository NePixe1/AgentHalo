import Foundation

public struct CodexUsageProvider: UsageProvider, Sendable {
    public let providerID: UsageProviderID = .codex

    private let authStore: CodexAuthStore
    private let usageClient: CodexUsageClient
    private let now: @Sendable () -> Date

    public init(
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
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
            }

            var response = try await usageClient.fetchUsage(
                accessToken: current.accessToken,
                accountID: current.accountID
            )
            if response.statusCode == 401 {
                let rotated = try await rotate(current, allowMigration: !adoptedExternalSource)
                current = rotated.access
                migrateCacheFrom = migrateCacheFrom ?? rotated.migrateCacheFrom
                response = try await usageClient.fetchUsage(
                    accessToken: current.accessToken,
                    accountID: current.accountID
                )
                guard response.statusCode != 401 else {
                    return failure(.signInAgain)
                }
            }

            let snapshot = try CodexUsageMapper.map(
                response: response,
                accountKey: current.accountKey,
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
        let refreshedAt = now()
        let rotation = CodexTokenRotation(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            refreshedAt: refreshedAt
        )
        var inMemory = Self.rotatedAccess(response, replacing: expected)

        do {
            if let persisted = try await Task.detached(operation: { [authStore] in
                try authStore.persist(rotation: rotation, replacing: expected)
            }).value {
                inMemory = persisted
            }
        } catch {
            // Deliberately omit the underlying error: it may contain a path or
            // Keychain diagnostic. The in-memory token remains valid now.
            NSLog("[CodexUsage] rotated credential writeback failed; continuing in memory")
        }

        let migration = allowMigration && inMemory.accountKey != expected.accountKey
            ? expected.accountKey
            : nil
        return (inMemory, migration)
    }

    private func failure(_ failure: UsageProviderFailure) -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, snapshot: nil, failure: failure)
    }

    private static func rotatedAccess(
        _ response: CodexRefreshResponse,
        replacing expected: OAuthAccess
    ) -> OAuthAccess {
        let refreshToken = response.refreshToken ?? expected.refreshToken
        let accountDigest: String
        if let accountID = expected.accountID {
            accountDigest = UsageDigest.sha256(accountID)
        } else {
            accountDigest = UsageDigest.sha256(
                "\(sourceIdentity(expected.source))|\(refreshToken ?? "")|\(response.accessToken)"
            )
        }
        return OAuthAccess(
            providerID: .codex,
            accountKey: AccountCacheKey(providerID: .codex, digest: accountDigest),
            source: expected.source,
            sourceVersion: expected.sourceVersion,
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: accessTokenExpiry(response.accessToken),
            accountID: expected.accountID,
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

    private static func accessTokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? NSNumber
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}
