import Foundation

private enum ClaudeGenerationChecked<Value: Sendable>: Sendable {
    case value(Value)
    case externalAccessChanged
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
        authStore.resolveAccess()
    }

    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let initialAccess) = access else {
            return failure(.signInAgain)
        }
        return await refresh(initialAccess: initialAccess)
    }

    private func refresh(initialAccess: OAuthAccess) async -> UsageRefreshResult {
        do {
            var current = initialAccess
            var migrateCacheFrom: AccountCacheKey?
            let exactAccess = authStore.reloadResolved(source: initialAccess.source)
            switch exactAccess {
            case .oauth(let live):
                guard live.sourceVersion == initialAccess.sourceVersion else {
                    return externalAccessChanged()
                }
                current = live
            case .oauthNeedsSignIn, .apiKey:
                return externalAccessChanged()
            }

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
                    try await usageClient.fetchUsage(accessToken: firstUsageCandidate.accessToken)
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
                        try await usageClient.fetchUsage(accessToken: secondUsageCandidate.accessToken)
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
        _ expected: OAuthAccess
    ) async throws -> (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?) {
        guard let refreshToken = expected.refreshToken, !refreshToken.isEmpty else {
            throw UsageProviderFailure.signInAgain
        }
        let response = try await usageClient.refreshToken(refreshToken)
        let rotation = try Self.rotation(from: response, now: now())
        var inMemory = Self.rotatedAccess(rotation, replacing: expected)

        do {
            if let persisted = try authStore.persist(rotation: rotation, replacing: expected) {
                inMemory = persisted
            }
        } catch {
            NSLog("[ClaudeUsage] rotated credential writeback failed; continuing in memory")
        }

        let migration = inMemory.accountKey != expected.accountKey
            ? expected.accountKey
            : nil
        return (inMemory, migration)
    }

    private func generationChecked<Value: Sendable>(
        candidate: OAuthAccess,
        successCandidate: @Sendable (Value) -> OAuthAccess,
        operation: @Sendable () async throws -> Value
    ) async -> ClaudeGenerationChecked<Value> {
        do {
            let value = try await operation()
            if sourceHasChanged(since: successCandidate(value)) {
                return .externalAccessChanged
            }
            return .value(value)
        } catch let failure as UsageProviderFailure {
            if sourceHasChanged(since: candidate) {
                return .externalAccessChanged
            }
            return .failure(failure)
        } catch {
            if sourceHasChanged(since: candidate) {
                return .externalAccessChanged
            }
            return .failure(.network)
        }
    }

    private func sourceHasChanged(since candidate: OAuthAccess) -> Bool {
        guard case .oauth(let live) = authStore.reloadResolved(source: candidate.source) else {
            return true
        }
        return live.sourceVersion != candidate.sourceVersion
    }

    private func failure(_ failure: UsageProviderFailure) -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, snapshot: nil, failure: failure)
    }

    private func externalAccessChanged() -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, outcome: .externalAccessChanged)
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
