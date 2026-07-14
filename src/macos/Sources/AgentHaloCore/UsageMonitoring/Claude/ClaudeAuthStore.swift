import CryptoKit
import Foundation

public struct ClaudeTokenRotation: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct ClaudeAuthStore: Sendable {
    public static let keychainService = "Claude Code-credentials"
    public static let usageScope = "user:profile"
    public static let refreshWindow: TimeInterval = 5 * 60

    private static let credentialFileName = ".credentials.json"
    private static let nonProductionOverrideNames = [
        "CLAUDE_CODE_CUSTOM_OAUTH_URL",
        "CLAUDE_LOCAL_OAUTH_API_BASE",
        "CLAUDE_CODE_OAUTH_CLIENT_ID",
        "CLAUDE_CODE_OAUTH_BASE_URL",
        "ANTHROPIC_BASE_URL",
        "USE_LOCAL_OAUTH",
        "USE_STAGING_OAUTH",
    ]

    private let environment: any UsageEnvironmentReading
    private let files: any UsageFileAccessing
    private let keychain: any UsageKeychainAccessing
    private let now: @Sendable () -> Date

    public init(
        environment: any UsageEnvironmentReading = ProcessInfoUsageEnvironment(),
        files: any UsageFileAccessing = FilesystemUsageFiles(),
        keychain: any UsageKeychainAccessing = SecurityUsageKeychain(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
    }

    public func resolveAccess() -> ResolvedProviderAccess {
        // This feature only supports Anthropic's production OAuth endpoints.
        // Any endpoint/client override makes the ambient credential an API-key
        // concern so a stored OAuth token can never be sent to a custom host.
        guard !hasNonProductionOAuthOverride() else { return .apiKey }

        if let candidate = firstStoredCandidate() { return resolvedAccess(candidate) }

        // CLAUDE_CODE_OAUTH_TOKEN is intentionally inference-only. With no
        // stored interactive login it therefore remains the API-key mode.
        return .apiKey
    }

    /// Reloads exactly the supplied file or keychain item. It never performs
    /// discovery, so refresh/retry code cannot silently migrate credentials.
    public func reload(source: CredentialSource) -> OAuthAccess? {
        do {
            return try loadCandidate(from: source)?.access
        } catch {
            return nil
        }
    }

    /// Reloads exactly one credential source and reapplies the same scope and
    /// production-endpoint policy as discovery. Refresh/retry paths use this
    /// so an external login change cannot bypass the `user:profile` gate.
    public func reloadResolved(source: CredentialSource) -> ResolvedProviderAccess {
        guard !hasNonProductionOAuthOverride() else { return .apiKey }
        do {
            guard let candidate = try loadCandidate(from: source) else { return .apiKey }
            return resolvedAccess(candidate)
        } catch {
            return .apiKey
        }
    }

    public func needsRefresh(_ access: OAuthAccess) -> Bool {
        guard let expiresAt = access.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshWindow
    }

    public func persist(
        rotation: ClaudeTokenRotation,
        replacing expected: OAuthAccess
    ) throws -> OAuthAccess? {
        if case .keychain(_, nil) = expected.source {
            return nil
        }
        guard expected.providerID == .claude,
              let currentPayload = try readPayload(from: expected.source),
              let current = makeCandidate(from: currentPayload, source: expected.source),
              current.access.sourceVersion == expected.sourceVersion
        else {
            return nil
        }

        var object = currentPayload.object
        CredentialJSON.set(rotation.accessToken, path: ["claudeAiOauth", "accessToken"], in: &object)
        if let refreshToken = rotation.refreshToken {
            CredentialJSON.set(refreshToken, path: ["claudeAiOauth", "refreshToken"], in: &object)
        }
        CredentialJSON.set(
            rotation.expiresAt.map { $0.timeIntervalSince1970 * 1000 },
            path: ["claudeAiOauth", "expiresAt"],
            in: &object
        )

        let rotatedData = try CredentialJSON.data(
            from: object,
            prettyPrinted: Self.isFile(expected.source)
        )
        switch expected.source {
        case .file(let path):
            try files.writeAtomically(rotatedData, to: path, preservingModeOf: path)
        case .keychain(let service, let account):
            guard let value = String(data: rotatedData, encoding: .utf8) else { return nil }
            try keychain.write(service: service, account: account, value: value)
        }

        let rotatedPayload = Payload(data: rotatedData, object: object)
        return makeCandidate(from: rotatedPayload, source: expected.source)?.access
    }

    private struct Payload {
        var data: Data
        var object: [String: Any]
    }

    private struct Candidate {
        var access: OAuthAccess
        var scopes: [String]?
    }

    private func resolvedAccess(_ candidate: Candidate) -> ResolvedProviderAccess {
        if let scopes = candidate.scopes,
           !scopes.isEmpty,
           !scopes.contains(Self.usageScope) {
            return .oauthNeedsSignIn(accountKey: candidate.access.accountKey)
        }
        return .oauth(candidate.access)
    }

    private func firstStoredCandidate() -> Candidate? {
        let account = currentUserAccount()
        for service in keychainServices() {
            if let account,
               let candidate = try? loadCandidate(
                   from: .keychain(service: service, account: account)
               ) {
                return candidate
            }
            if let item = try? keychain.readFirstMatching(service: service),
               let object = try? CredentialJSON.object(from: Data(item.value.utf8)),
               let candidate = makeCandidate(
                   from: Payload(data: Data(item.value.utf8), object: object),
                   source: .keychain(service: service, account: item.account)
               ) {
                return candidate
            }
        }
        return try? loadCandidate(from: .file(path: credentialsPath()))
    }

    private func keychainServices() -> [String] {
        guard let configDir = nonemptyEnvironmentValue("CLAUDE_CONFIG_DIR") else {
            return [Self.keychainService]
        }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let suffix = String(UsageDigest.sha256(normalized).prefix(8))
        return ["\(Self.keychainService)-\(suffix)", Self.keychainService]
    }

    private func credentialsPath() -> String {
        if let configDir = nonemptyEnvironmentValue("CLAUDE_CONFIG_DIR") {
            return Self.join(configDir, Self.credentialFileName)
        }
        let home = nonemptyEnvironmentValue("HOME") ?? ""
        return Self.join(home, ".claude/\(Self.credentialFileName)")
    }

    private func currentUserAccount() -> String? {
        if let user = nonemptyEnvironmentValue("USER") { return user }
        let user = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
    }

    private func hasNonProductionOAuthOverride() -> Bool {
        Self.nonProductionOverrideNames.contains { nonemptyEnvironmentValue($0) != nil }
    }

    private func nonemptyEnvironmentValue(_ name: String) -> String? {
        guard let value = environment.value(for: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func readPayload(from source: CredentialSource) throws -> Payload? {
        let data: Data
        switch source {
        case .file(let path):
            guard let stored = try files.readDataIfPresent(at: path) else { return nil }
            data = stored
        case .keychain(let service, let account):
            guard let stored = try keychain.read(service: service, account: account) else { return nil }
            data = Data(stored.utf8)
        }
        guard let object = try? CredentialJSON.object(from: data) else { return nil }
        return Payload(data: data, object: object)
    }

    private func loadCandidate(from source: CredentialSource) throws -> Candidate? {
        guard let payload = try readPayload(from: source) else { return nil }
        return makeCandidate(from: payload, source: source)
    }

    private func makeCandidate(from payload: Payload, source: CredentialSource) -> Candidate? {
        let root = payload.object
        guard let accessToken = Self.nonemptyString(root, path: ["claudeAiOauth", "accessToken"]) else {
            return nil
        }
        let refreshToken = Self.nonemptyString(root, path: ["claudeAiOauth", "refreshToken"])
        let expiresAtMilliseconds = Self.number(root, path: ["claudeAiOauth", "expiresAt"])
        let subscriptionType = Self.nonemptyString(root, path: ["claudeAiOauth", "subscriptionType"])
        let rateLimitTier = Self.nonemptyString(root, path: ["claudeAiOauth", "rateLimitTier"])
        let scopes = Self.stringArray(root, path: ["claudeAiOauth", "scopes"])

        let tokenDigest = UsageDigest.sha256(refreshToken ?? accessToken)
        let accountDigest = UsageDigest.sha256("\(Self.sourceIdentity(source))|\(tokenDigest)")
        let sourceVersion = Self.sourceVersion(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: expiresAtMilliseconds,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            scopes: scopes
        )
        let planHint: OAuthPlanHint?
        if subscriptionType != nil || rateLimitTier != nil {
            planHint = OAuthPlanHint(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
        } else {
            planHint = nil
        }

        let access = OAuthAccess(
            providerID: .claude,
            accountKey: AccountCacheKey(providerID: .claude, digest: accountDigest),
            source: source,
            sourceVersion: sourceVersion,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAtMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) },
            accountID: nil,
            planHint: planHint
        )
        return Candidate(access: access, scopes: scopes)
    }

    private static func sourceVersion(
        accessToken: String,
        refreshToken: String?,
        expiresAtMilliseconds: Double?,
        subscriptionType: String?,
        rateLimitTier: String?,
        scopes: [String]?
    ) -> String {
        let effectiveFields: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": Self.jsonValue(refreshToken),
            "expiresAt": Self.jsonValue(expiresAtMilliseconds),
            "subscriptionType": Self.jsonValue(subscriptionType),
            "rateLimitTier": Self.jsonValue(rateLimitTier),
            "scopes": Self.jsonValue(scopes?.sorted()),
        ]
        let canonical = try! JSONSerialization.data(withJSONObject: effectiveFields, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private static func value(_ object: [String: Any], path: [String]) -> Any? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func nonemptyString(_ object: [String: Any], path: [String]) -> String? {
        guard let value = value(object, path: path) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    private static func number(_ object: [String: Any], path: [String]) -> Double? {
        (value(object, path: path) as? NSNumber)?.doubleValue
    }

    private static func stringArray(_ object: [String: Any], path: [String]) -> [String]? {
        value(object, path: path) as? [String]
    }

    private static func sourceIdentity(_ source: CredentialSource) -> String {
        switch source {
        case .file(let path):
            return path
        case .keychain(let service, let account):
            return account.map { "\(service)|\($0)" } ?? service
        }
    }

    private static func isFile(_ source: CredentialSource) -> Bool {
        if case .file = source { return true }
        return false
    }

    private static func join(_ base: String, _ suffix: String) -> String {
        let trimmed = base.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "/\(suffix)" : "\(trimmed)/\(suffix)"
    }
}
