import Foundation

/// Injectable LS discovery. Production uses `AntigravityLanguageServerDiscovery`;
/// checks inject a fake so refresh never scans the real process table.
public protocol AntigravityLanguageServerDiscovering: Sendable {
    func discover(
        _ options: AntigravityLanguageServerDiscovery.Options
    ) -> AntigravityLanguageServerDiscovery.Result?
}

extension AntigravityLanguageServerDiscovery: AntigravityLanguageServerDiscovering {}

/// Antigravity usage: local language server first, then `agy`, then Cloud Code.
///
/// `RetrieveUserQuotaSummary` 2xx with a parseable body (including zero windows)
/// is authoritative for that source. One extra `GetUserStatus` may fill `planName`
/// only. Legacy remaining-fraction endpoints run only when the summary is not
/// that RPC, and only produce a 5h session window.
public struct AntigravityUsageProvider: UsageProvider, Sendable {
    public let providerID = UsageProviderID.antigravity

    public static let languageServerOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "language_server",
        markers: ["antigravity", "antigravity-ide"],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port"
    )
    public static let agyOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "agy",
        markers: [],
        csrfFlag: "",
        portFlag: nil
    )

    private let authStore: AntigravityAuthStore
    private let usageClient: AntigravityUsageClient
    private let discovery: any AntigravityLanguageServerDiscovering
    private let focusController: UsageProviderFocusController
    private let now: @Sendable () -> Date

    public init(
        authStore: AntigravityAuthStore,
        usageClient: AntigravityUsageClient = AntigravityUsageClient(),
        discovery: any AntigravityLanguageServerDiscovering = AntigravityLanguageServerDiscovery(),
        focusController: UsageProviderFocusController = UsageProviderFocusController(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.discovery = discovery
        self.focusController = focusController
        self.now = now
    }

    public func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess {
        let lsAvailable =
            discovery.discover(Self.languageServerOptions) != nil
            || discovery.discover(Self.agyOptions) != nil
        return authStore.resolveAccess(lsAvailable: lsAvailable)
    }

    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let oauth) = access else {
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
        }
        if let snapshot = await probeLS(Self.languageServerOptions, accountKey: oauth.accountKey) {
            return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
        }
        if let snapshot = await probeLS(Self.agyOptions, accountKey: oauth.accountKey) {
            return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
        }
        switch await resolvedCloudCodeToken(oauth) {
        case .ready(let token):
            return await probeCloudCode(oauth, accessToken: token)
        case .signInAgain:
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
        case .serviceUnavailable:
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.serviceUnavailable))
        }
    }

    /// Summary 2xx + 可解析（含空窗）即返回；可选第二次 `GetUserStatus` 只填 `planName`。
    /// Summary 不是该 RPC 时，才用 legacy configs → `sessionWindowFromLegacyGeminiConfigs`。
    private func probeLS(
        _ options: AntigravityLanguageServerDiscovery.Options,
        accountKey: AccountCacheKey
    ) async -> UsageSnapshot? {
        guard let discovered = discovery.discover(options) else { return nil }

        var endpoints: [(scheme: String, port: Int)] = []
        for port in discovered.ports {
            endpoints.append(("https", port))
            endpoints.append(("http", port))
        }
        if let extensionPort = discovered.extensionPort {
            endpoints.append(("http", extensionPort))
        }

        for endpoint in endpoints {
            if let summary = await usageClient.callLS(
                scheme: endpoint.scheme,
                port: endpoint.port,
                csrf: discovered.csrf,
                method: "RetrieveUserQuotaSummary"
            ) {
                if (200..<300).contains(summary.statusCode),
                   let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(summary.body) {
                    let planName = await planNameFromUserStatus(
                        scheme: endpoint.scheme,
                        port: endpoint.port,
                        csrf: discovered.csrf
                    )
                    return makeSnapshot(accountKey: accountKey, planName: planName, windows: windows)
                }
            }

            guard let status = await usageClient.callLS(
                scheme: endpoint.scheme,
                port: endpoint.port,
                csrf: discovered.csrf,
                method: "GetUserStatus"
            ), (200..<300).contains(status.statusCode) else {
                continue
            }

            let planName = Self.userTierPlan(from: status.body)
            if let window = Self.sessionWindow(from: Self.geminiConfigs(fromUserStatus: status.body)) {
                return makeSnapshot(accountKey: accountKey, planName: planName, windows: [window])
            }

            if let fallback = await usageClient.callLS(
                scheme: endpoint.scheme,
                port: endpoint.port,
                csrf: discovered.csrf,
                method: "GetCommandModelConfigs"
            ), (200..<300).contains(fallback.statusCode),
               let window = Self.sessionWindow(
                    from: Self.geminiConfigs(fromCommandConfigs: fallback.body)
               ) {
                return makeSnapshot(accountKey: accountKey, planName: planName, windows: [window])
            }
        }
        return nil
    }

    private func planNameFromUserStatus(scheme: String, port: Int, csrf: String) async -> String? {
        guard let status = await usageClient.callLS(
            scheme: scheme,
            port: port,
            csrf: csrf,
            method: "GetUserStatus"
        ), (200..<300).contains(status.statusCode) else {
            return nil
        }
        return Self.userTierPlan(from: status.body)
    }

    /// Unusable access + refresh outage is not sign-in; do not send that token to Cloud Code.
    private func resolvedCloudCodeToken(_ oauth: OAuthAccess) async -> CloudCodeTokenResolution {
        let keychainToken = (try? authStore.loadKeychainToken()) ?? AntigravityKeychainToken(
            accessToken: oauth.accessToken.isEmpty ? nil : oauth.accessToken,
            refreshToken: oauth.refreshToken,
            expiry: oauth.expiresAt
        )

        if !oauth.accessToken.isEmpty, authStore.isUsable(expiry: oauth.expiresAt) {
            return .ready(oauth.accessToken)
        }
        if let cached = authStore.loadCachedAccessToken(matching: keychainToken) {
            return .ready(cached)
        }
        if let refresh = nonempty(oauth.refreshToken) ?? nonempty(keychainToken.refreshToken) {
            switch await usageClient.refreshGoogleToken(refresh) {
            case .refreshed(let accessToken, let expiresIn):
                cacheRefreshedAccess(accessToken, expiresIn: expiresIn, refreshToken: refresh)
                return .ready(accessToken)
            case .authFailed:
                return .signInAgain
            case .unavailable:
                return .serviceUnavailable
            }
        }
        if let access = nonempty(oauth.accessToken) {
            return .ready(access)
        }
        return .signInAgain
    }

    private func cacheRefreshedAccess(
        _ accessToken: String,
        expiresIn: Double,
        refreshToken: String
    ) {
        guard let authorization = focusController.authorization(for: providerID) else { return }
        do {
            try authorization.performCredentialWrite {
                try authStore.cacheAccessToken(
                    accessToken,
                    expiresIn: expiresIn,
                    sourceRefreshToken: refreshToken
                )
            }
        } catch is UsageProviderFocusError {
            return
        } catch {
            NSLog("[AntigravityUsage] access-token cache write failed; continuing in memory")
        }
    }

    private func probeCloudCode(_ oauth: OAuthAccess, accessToken: String) async -> UsageRefreshResult {
        switch await fetchCloudCode(token: accessToken, accountKey: oauth.accountKey) {
        case .success(let snapshot):
            return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
        case .authFailed:
            switch await refreshedTokenAfterAuthFailure(oauth, used: accessToken) {
            case .ready(let retryToken):
                switch await fetchCloudCode(token: retryToken, accountKey: oauth.accountKey) {
                case .success(let snapshot):
                    return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
                case .authFailed:
                    return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
                case .unavailable:
                    return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.serviceUnavailable))
                }
            case .signInAgain:
                return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
            case .serviceUnavailable:
                return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.serviceUnavailable))
            }
        case .unavailable:
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.serviceUnavailable))
        }
    }

    private func refreshedTokenAfterAuthFailure(
        _ oauth: OAuthAccess,
        used: String
    ) async -> CloudCodeTokenResolution {
        let keychainToken = (try? authStore.loadKeychainToken()) ?? AntigravityKeychainToken(
            accessToken: oauth.accessToken.isEmpty ? nil : oauth.accessToken,
            refreshToken: oauth.refreshToken,
            expiry: oauth.expiresAt
        )
        guard let refresh = nonempty(oauth.refreshToken) ?? nonempty(keychainToken.refreshToken) else {
            return .signInAgain
        }
        if let cached = authStore.loadCachedAccessToken(matching: keychainToken), cached != used {
            return .ready(cached)
        }
        switch await usageClient.refreshGoogleToken(refresh) {
        case .refreshed(let accessToken, let expiresIn):
            cacheRefreshedAccess(accessToken, expiresIn: expiresIn, refreshToken: refresh)
            return .ready(accessToken)
        case .authFailed:
            return .signInAgain
        case .unavailable:
            return .serviceUnavailable
        }
    }

    private enum CloudCodeTokenResolution {
        case ready(String)
        case signInAgain
        case serviceUnavailable
    }

    private enum CloudCodeProbe {
        case success(UsageSnapshot)
        case authFailed
        case unavailable
    }

    private func fetchCloudCode(token: String, accountKey: AccountCacheKey) async -> CloudCodeProbe {
        switch await usageClient.cloudCode(
            path: AntigravityUsageClient.quotaSummaryPath,
            token: token,
            userAgent: "antigravity",
            body: [:]
        ) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(data) {
                return .success(makeSnapshot(accountKey: accountKey, planName: nil, windows: windows))
            }
        case .unavailable:
            break
        }

        switch await usageClient.cloudCode(
            path: AntigravityUsageClient.fetchModelsPath,
            token: token,
            userAgent: "antigravity",
            body: [:]
        ) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let window = Self.sessionWindow(from: Self.geminiConfigs(fromCloudModels: data)) {
                return .success(makeSnapshot(accountKey: accountKey, planName: nil, windows: [window]))
            }
        case .unavailable:
            break
        }

        switch await usageClient.cloudCode(
            path: AntigravityUsageClient.retrieveQuotaPath,
            token: token,
            userAgent: "agy",
            body: [:]
        ) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let window = Self.sessionWindow(from: Self.geminiConfigs(fromQuotaBuckets: data)) {
                return .success(makeSnapshot(accountKey: accountKey, planName: nil, windows: [window]))
            }
        case .unavailable:
            break
        }
        return .unavailable
    }

    private func makeSnapshot(
        accountKey: AccountCacheKey,
        planName: String?,
        windows: [UsageWindow]
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: .antigravity,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now()
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Legacy Gemini extraction

    private static func userTierPlan(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(UserStatusEnvelope.self, from: data) else {
            return nil
        }
        return AntigravityUsageMapper.formatPlan(envelope.status?.userTier?.name)
    }

    private static func geminiConfigs(fromUserStatus data: Data) -> [LegacyGeminiConfig] {
        guard let envelope = try? JSONDecoder().decode(UserStatusEnvelope.self, from: data) else {
            return []
        }
        return (envelope.status?.cascadeModelConfigData?.clientModelConfigs ?? [])
            .compactMap(legacyGemini(from:))
    }

    private static func geminiConfigs(fromCommandConfigs data: Data) -> [LegacyGeminiConfig] {
        guard let envelope = try? JSONDecoder().decode(UserStatusEnvelope.self, from: data) else {
            return []
        }
        return (envelope.commandConfigs ?? []).compactMap(legacyGemini(from:))
    }

    private static func geminiConfigs(fromCloudModels data: Data) -> [LegacyGeminiConfig] {
        guard let envelope = try? JSONDecoder().decode(CloudModelsEnvelope.self, from: data),
              let models = envelope.models
        else {
            return []
        }
        return models.compactMap { key, model in
            legacyGemini(
                label: model.displayName ?? model.label,
                modelID: model.model ?? key,
                remainingFraction: model.quotaInfo?.remainingFraction,
                resetTime: model.quotaInfo?.resetTime
            )
        }
    }

    private static func geminiConfigs(fromQuotaBuckets data: Data) -> [LegacyGeminiConfig] {
        guard let envelope = try? JSONDecoder().decode(CloudQuotaEnvelope.self, from: data),
              let buckets = envelope.buckets
        else {
            return []
        }
        return buckets.compactMap { bucket in
            legacyGemini(
                label: bucket.modelId,
                modelID: bucket.modelId,
                remainingFraction: bucket.remainingFraction,
                resetTime: bucket.resetTime
            )
        }
    }

    private static func legacyGemini(from config: UserStatusEnvelope.ModelConfig) -> LegacyGeminiConfig? {
        legacyGemini(
            label: config.label,
            modelID: config.modelOrAlias?.model,
            remainingFraction: config.quotaInfo?.remainingFraction,
            resetTime: config.quotaInfo?.resetTime
        )
    }

    private static func legacyGemini(
        label: String?,
        modelID: String?,
        remainingFraction: Double?,
        resetTime: String?
    ) -> LegacyGeminiConfig? {
        guard isGemini(label: label, modelID: modelID),
              let fraction = remainingFraction, fraction.isFinite
        else {
            return nil
        }
        return LegacyGeminiConfig(remainingFraction: fraction, resetTime: resetTime.flatMap(parseResetTime))
    }

    private static func isGemini(label: String?, modelID: String?) -> Bool {
        [label, modelID].compactMap { $0 }.contains {
            $0.range(of: "gemini", options: .caseInsensitive) != nil
        }
    }

    private static func sessionWindow(from configs: [LegacyGeminiConfig]) -> UsageWindow? {
        guard let worst = configs.min(by: { $0.remainingFraction < $1.remainingFraction }) else {
            return nil
        }
        return AntigravityUsageMapper.sessionWindowFromLegacyGeminiConfigs(
            remainingFractions: configs.map(\.remainingFraction),
            resetTime: worst.resetTime
        )
    }

    private static func parseResetTime(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct LegacyGeminiConfig {
    var remainingFraction: Double
    var resetTime: Date?
}

private struct UserStatusEnvelope: Decodable {
    struct Wrapper: Decodable {
        let userStatus: UserStatus?
        let clientModelConfigs: [ModelConfig]?
    }

    struct UserStatus: Decodable {
        struct Tier: Decodable { let name: String? }
        struct Cascade: Decodable { let clientModelConfigs: [ModelConfig]? }
        let userTier: Tier?
        let cascadeModelConfigData: Cascade?
    }

    struct ModelConfig: Decodable {
        struct Quota: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
        }
        struct ModelOrAlias: Decodable { let model: String? }
        let label: String?
        let modelOrAlias: ModelOrAlias?
        let quotaInfo: Quota?
    }

    let response: Wrapper?
    let userStatus: UserStatus?
    let clientModelConfigs: [ModelConfig]?

    var status: UserStatus? { userStatus ?? response?.userStatus }
    var commandConfigs: [ModelConfig]? { clientModelConfigs ?? response?.clientModelConfigs }
}

private struct CloudModelsEnvelope: Decodable {
    struct Model: Decodable {
        struct Quota: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
        }
        let model: String?
        let displayName: String?
        let label: String?
        let quotaInfo: Quota?
    }

    let models: [String: Model]?
}

private struct CloudQuotaEnvelope: Decodable {
    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }

    let buckets: [Bucket]?
}
