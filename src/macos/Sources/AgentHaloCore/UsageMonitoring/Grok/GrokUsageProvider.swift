import Foundation

private enum GrokGenerationChecked<Value: Sendable>: Sendable {
    case value(Value)
    case externalAccessChanged
    case failure(UsageProviderFailure)
    case cancelled
}

public struct GrokUsageProvider: UsageProvider, Sendable {
    public let providerID: UsageProviderID = .grok

    private let authStore: GrokAuthStore
    private let usageClient: GrokUsageClient
    private let focusController: UsageProviderFocusController
    private let now: @Sendable () -> Date

    public init(
        authStore: GrokAuthStore = GrokAuthStore(),
        usageClient: GrokUsageClient = GrokUsageClient(),
        focusController: UsageProviderFocusController =
            UsageProviderFocusController(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.focusController = focusController
        self.now = now
    }

    public func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess {
        authStore.resolveAccess()
    }

    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let initialAccess) = access else {
            return failure(.signInAgain)
        }
        guard let authorization = focusController.authorization(for: providerID) else {
            return cancelled()
        }
        return await refresh(
            initialAccess: initialAccess,
            authorization: authorization
        )
    }

    private func refresh(
        initialAccess: OAuthAccess,
        authorization: UsageProviderFocusAuthorization
    ) async -> UsageRefreshResult {
        do {
            try authorization.check()
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
                    authorization: authorization,
                    successCandidate: { $0.access },
                    operation: {
                        try await rotate(
                            requestCandidate,
                            authorization: authorization
                        )
                    }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checked {
                case .value(let value):
                    rotated = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                case .cancelled:
                    return cancelled()
                }
                current = rotated.access
                migrateCacheFrom = rotated.migrateCacheFrom
            }

            let firstCreditsCandidate = current
            let firstCredits = await generationChecked(
                candidate: firstCreditsCandidate,
                authorization: authorization,
                successCandidate: { _ in firstCreditsCandidate },
                operation: {
                    try await usageClient.fetchCreditsConfig(
                        accessToken: firstCreditsCandidate.accessToken
                    )
                }
            )
            var response: UsageHTTPResponse
            switch firstCredits {
            case .value(let value):
                response = value
            case .externalAccessChanged:
                return externalAccessChanged()
            case .failure(let failure):
                return self.failure(failure)
            case .cancelled:
                return cancelled()
            }
            if response.statusCode == 401 {
                let requestCandidate = current
                let checkedRotation = await generationChecked(
                    candidate: requestCandidate,
                    authorization: authorization,
                    successCandidate: { $0.access },
                    operation: {
                        try await rotate(
                            requestCandidate,
                            authorization: authorization
                        )
                    }
                )
                let rotated: (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?)
                switch checkedRotation {
                case .value(let value):
                    rotated = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                case .cancelled:
                    return cancelled()
                }
                current = rotated.access
                migrateCacheFrom = migrateCacheFrom ?? rotated.migrateCacheFrom
                let secondCreditsCandidate = current
                let secondCredits = await generationChecked(
                    candidate: secondCreditsCandidate,
                    authorization: authorization,
                    successCandidate: { _ in secondCreditsCandidate },
                    operation: {
                        try await usageClient.fetchCreditsConfig(
                            accessToken: secondCreditsCandidate.accessToken
                        )
                    }
                )
                switch secondCredits {
                case .value(let value):
                    response = value
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure(let failure):
                    return self.failure(failure)
                case .cancelled:
                    return cancelled()
                }
                if response.statusCode == 401 { return failure(.signInAgain) }
            }

            // Best-effort plan label; settings failure still yields a credits snapshot.
            var planName: String?
            if (200..<300).contains(response.statusCode) {
                let settingsCandidate = current
                let settingsChecked = await generationChecked(
                    candidate: settingsCandidate,
                    authorization: authorization,
                    successCandidate: { _ in settingsCandidate },
                    operation: {
                        try await usageClient.fetchSettings(
                            accessToken: settingsCandidate.accessToken
                        )
                    }
                )
                switch settingsChecked {
                case .value(let settingsResponse):
                    planName = GrokUsageMapper.planName(from: settingsResponse)
                case .externalAccessChanged:
                    return externalAccessChanged()
                case .failure:
                    planName = nil
                case .cancelled:
                    return cancelled()
                }
            }

            let snapshot = try GrokUsageMapper.mapCredits(
                response: response,
                accountKey: current.accountKey,
                planName: planName,
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
        } catch is CancellationError {
            return cancelled()
        } catch is UsageProviderFocusError {
            return cancelled()
        } catch {
            return failure(.network)
        }
    }

    private func rotate(
        _ expected: OAuthAccess,
        authorization: UsageProviderFocusAuthorization
    ) async throws -> (access: OAuthAccess, migrateCacheFrom: AccountCacheKey?) {
        try authorization.check()
        guard let refreshToken = expected.refreshToken, !refreshToken.isEmpty else {
            throw UsageProviderFailure.signInAgain
        }
        let clientID = authStore.clientID(for: expected)
        let response = try await usageClient.refreshToken(refreshToken, clientID: clientID)
        try authorization.check()
        let rotation = try Self.rotation(from: response, now: now())
        var requestAccess = Self.rotatedAccess(rotation, replacing: expected)
        requestAccess.accountKey = expected.accountKey
        var persistedAccess: OAuthAccess?

        do {
            let persisted = try authorization.performCredentialWrite {
                try authStore.persist(rotation: rotation, replacing: expected)
            }
            if let persisted {
                requestAccess = persisted
                persistedAccess = persisted
            }
        } catch let error as UsageProviderFocusError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[GrokUsage] rotated credential writeback failed; continuing in memory")
        }

        let migration = persistedAccess.map { $0.accountKey != expected.accountKey } == true
            ? expected.accountKey
            : nil
        return (requestAccess, migration)
    }

    private func generationChecked<Value: Sendable>(
        candidate: OAuthAccess,
        authorization: UsageProviderFocusAuthorization,
        successCandidate: @Sendable (Value) -> OAuthAccess,
        operation: @Sendable () async throws -> Value
    ) async -> GrokGenerationChecked<Value> {
        do {
            try authorization.check()
            let value = try await operation()
            try authorization.check()
            if sourceHasChanged(since: successCandidate(value)) {
                return .externalAccessChanged
            }
            return .value(value)
        } catch is CancellationError {
            return .cancelled
        } catch is UsageProviderFocusError {
            return .cancelled
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

    private func cancelled() -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, outcome: .cancelled)
    }

    private func externalAccessChanged() -> UsageRefreshResult {
        UsageRefreshResult(providerID: providerID, outcome: .externalAccessChanged)
    }

    private static func rotation(
        from response: UsageHTTPResponse,
        now: Date
    ) throws -> GrokTokenRotation {
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
                retryAt: GrokUsageMapper.retryAfterDate(response, now: now)
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
        return GrokTokenRotation(
            accessToken: accessToken,
            refreshToken: nonemptyString(object["refresh_token"]),
            expiresAt: expiresAt
        )
    }

    private static func rotatedAccess(
        _ rotation: GrokTokenRotation,
        replacing expected: OAuthAccess
    ) -> OAuthAccess {
        let refreshToken = rotation.refreshToken ?? expected.refreshToken
        return OAuthAccess(
            providerID: .grok,
            accountKey: expected.accountKey,
            source: expected.source,
            sourceVersion: expected.sourceVersion,
            accessToken: rotation.accessToken,
            refreshToken: refreshToken,
            expiresAt: rotation.expiresAt ?? expected.expiresAt,
            accountID: expected.accountID,
            planHint: expected.planHint
        )
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
        // Reject real JSON booleans only. `is Bool` also matches NSNumber(0/1).
        if let value = value as? NSNumber {
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                return nil
            }
            return value.doubleValue
        }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }
}
