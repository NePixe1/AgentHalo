import Foundation

private enum CodexGenerationChecked<Value: Sendable>: Sendable {
    case value(Value)
    case externalAccessChanged
    case failure(UsageProviderFailure)
}

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
        authStore.resolveAccess()
    }

    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let initialAccess) = access else {
            return failure(.signInAgain)
        }

        do {
            guard let exactAccess = authStore.reload(source: initialAccess.source),
                  exactAccess.sourceVersion == initialAccess.sourceVersion
            else {
                return externalAccessChanged()
            }

            var current = exactAccess
            var migrateCacheFrom: AccountCacheKey?

            if authStore.needsRefresh(current) {
                let requestCandidate = current
                let checked = await generationChecked(
                    candidate: requestCandidate,
                    successCandidate: { $0.access },
                    operation: { try await rotate(requestCandidate) }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checked {
                case .value(let value):
                    rotated = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                }
                current = rotated.access
                migrateCacheFrom = rotated.migrateCacheFrom
            }

            let firstUsageCandidate = current
            let firstUsage = await generationChecked(
                candidate: firstUsageCandidate,
                successCandidate: { _ in firstUsageCandidate },
                operation: {
                    try await usageClient.fetchUsage(
                        accessToken: firstUsageCandidate.accessToken,
                        accountID: firstUsageCandidate.accountID
                    )
                }
            )
            var response: UsageHTTPResponse
            switch firstUsage {
            case .value(let value):
                response = value
            case .externalAccessChanged:
                return externalAccessChanged()
            case .failure(let failure):
                return self.failure(failure)
            }
            if response.statusCode == 401 {
                let requestCandidate = current
                let checkedRotation = await generationChecked(
                    candidate: requestCandidate,
                    successCandidate: { $0.access },
                    operation: { try await rotate(requestCandidate) }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checkedRotation {
                case .value(let value):
                    rotated = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                }
                current = rotated.access
                migrateCacheFrom = migrateCacheFrom ?? rotated.migrateCacheFrom
                let secondUsageCandidate = current
                let secondUsage = await generationChecked(
                    candidate: secondUsageCandidate,
                    successCandidate: { _ in secondUsageCandidate },
                    operation: {
                        try await usageClient.fetchUsage(
                            accessToken: secondUsageCandidate.accessToken,
                            accountID: secondUsageCandidate.accountID
                        )
                    }
                )
                switch secondUsage {
                case .value(let value):
                    response = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                }
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
        _ expected: OAuthAccess
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
        var requestAccess = Self.rotatedAccess(response, replacing: expected)
        requestAccess.accountKey = expected.accountKey
        var persistedAccess: OAuthAccess?

        do {
            if let persisted = try authStore.persist(rotation: rotation, replacing: expected) {
                requestAccess = persisted
                persistedAccess = persisted
            }
        } catch {
            // Deliberately omit the underlying error: it may contain a path or
            // Keychain diagnostic. The in-memory token remains valid now.
            NSLog("[CodexUsage] rotated credential writeback failed; continuing in memory")
        }

        let migration = persistedAccess.map { $0.accountKey != expected.accountKey } == true
            ? expected.accountKey
            : nil
        return (requestAccess, migration)
    }

    private func generationChecked<Value: Sendable>(
        candidate: OAuthAccess,
        successCandidate: @Sendable (Value) -> OAuthAccess,
        operation: @Sendable () async throws -> Value
    ) async -> CodexGenerationChecked<Value> {
        do {
            let value = try await operation()
            guard sourceIsCurrent(successCandidate(value)) else {
                return .externalAccessChanged
            }
            return .value(value)
        } catch let failure as UsageProviderFailure {
            guard sourceIsCurrent(candidate) else {
                return .externalAccessChanged
            }
            return .failure(failure)
        } catch {
            guard sourceIsCurrent(candidate) else {
                return .externalAccessChanged
            }
            return .failure(.network)
        }
    }

    private func sourceIsCurrent(_ candidate: OAuthAccess) -> Bool {
        guard let live = authStore.reload(source: candidate.source) else { return false }
        return live.sourceVersion == candidate.sourceVersion
    }

    private func failure(_ failure: UsageProviderFailure) -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, snapshot: nil, failure: failure)
    }

    private func externalAccessChanged() -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, outcome: .externalAccessChanged)
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
