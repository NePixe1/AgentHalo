import Foundation
import CryptoKit

public struct CodexTokenRotation: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var refreshedAt: Date

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        refreshedAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.refreshedAt = refreshedAt
    }
}

public struct CodexAuthStore: Sendable {
    public static let keychainService = "Codex Auth"
    public static let refreshWindow: TimeInterval = 5 * 60

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
        for path in authPaths() {
            if let access = reload(source: .file(path: path)) {
                return .oauth(access)
            }
        }

        if let item = try? keychain.readFirstMatching(service: Self.keychainService) {
            let data = Data(item.value.utf8)
            if let object = try? CredentialJSON.object(from: data),
               let access = makeOAuthAccess(
                   from: data,
                   object: object,
                   source: .keychain(service: Self.keychainService, account: item.account)
               ) {
                return .oauth(access)
            }
        }

        return .apiKey
    }

    public func reload(source: CredentialSource) -> OAuthAccess? {
        guard let payload = try? readPayload(from: source) else { return nil }
        return makeOAuthAccess(from: payload.data, object: payload.object, source: source)
    }

    public func needsRefresh(_ access: OAuthAccess, lastRefresh: Date?) -> Bool {
        if let expiresAt = access.expiresAt {
            return expiresAt.timeIntervalSince(now()) <= Self.refreshWindow
        }
        guard let lastRefresh else { return false }
        return now().timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    /// Reloads the exact credential source and applies its stored
    /// `last_refresh` when the access token has no readable JWT expiry.
    public func needsRefresh(_ access: OAuthAccess) -> Bool {
        do {
            guard let payload = try readPayload(from: access.source),
                  UsageDigest.sha256Data(payload.data) == access.sourceVersion
            else {
                return needsRefresh(access, lastRefresh: nil)
            }
            return needsRefresh(access, lastRefresh: payload.lastRefresh)
        } catch {
            return needsRefresh(access, lastRefresh: nil)
        }
    }

    public func persist(
        rotation: CodexTokenRotation,
        replacing expected: OAuthAccess
    ) throws -> OAuthAccess? {
        guard let current = try readPayload(from: expected.source) else { return nil }
        let currentVersion = UsageDigest.sha256Data(current.data)
        guard currentVersion == expected.sourceVersion else { return nil }

        var object = current.object
        CredentialJSON.set(rotation.accessToken, path: ["tokens", "access_token"], in: &object)
        if let refreshToken = rotation.refreshToken {
            CredentialJSON.set(refreshToken, path: ["tokens", "refresh_token"], in: &object)
        }
        if let idToken = rotation.idToken {
            CredentialJSON.set(idToken, path: ["tokens", "id_token"], in: &object)
        }
        CredentialJSON.set(Self.formatDate(rotation.refreshedAt), path: ["last_refresh"], in: &object)

        let prettyPrinted: Bool
        switch expected.source {
        case .file:
            prettyPrinted = true
        case .keychain:
            prettyPrinted = false
        }
        let rotatedData = try CredentialJSON.data(from: object, prettyPrinted: prettyPrinted)

        switch expected.source {
        case .file(let path):
            try files.writeAtomically(rotatedData, to: path, preservingModeOf: path)
        case .keychain(let service, let account):
            guard let value = String(data: rotatedData, encoding: .utf8) else { return nil }
            try keychain.write(service: service, account: account, value: value)
        }

        return makeOAuthAccess(from: rotatedData, object: object, source: expected.source)
    }

    private func authPaths() -> [String] {
        if let codexHome = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return [Self.join(codexHome, "auth.json")]
        }

        let home = environment.value(for: "HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            Self.join(home, ".config/codex/auth.json"),
            Self.join(home, ".codex/auth.json"),
        ]
    }

    private func readPayload(
        from source: CredentialSource
    ) throws -> (data: Data, object: [String: Any], lastRefresh: Date?)? {
        let data: Data
        switch source {
        case .file(let path):
            guard let fileData = try files.readDataIfPresent(at: path) else { return nil }
            data = fileData
        case .keychain(let service, let account):
            guard let value = try keychain.read(service: service, account: account) else { return nil }
            data = Data(value.utf8)
        }

        guard let object = try? CredentialJSON.object(from: data) else { return nil }
        let lastRefresh = CredentialJSON.string(object, path: ["last_refresh"])
            .flatMap(Self.parseDate)
        return (data, object, lastRefresh)
    }

    private func makeOAuthAccess(
        from data: Data,
        object: [String: Any],
        source: CredentialSource
    ) -> OAuthAccess? {
        guard let accessToken = Self.nonemptyString(object, path: ["tokens", "access_token"]) else {
            return nil
        }

        let refreshToken = Self.nonemptyString(object, path: ["tokens", "refresh_token"])
        let accountID = Self.nonemptyString(object, path: ["tokens", "account_id"])
        let sourceIdentity = Self.sourceIdentity(source)
        let accountDigest: String
        if let accountID {
            accountDigest = UsageDigest.sha256(accountID)
        } else {
            accountDigest = UsageDigest.sha256("\(sourceIdentity)|\(refreshToken ?? "")|\(accessToken)")
        }

        return OAuthAccess(
            providerID: .codex,
            accountKey: AccountCacheKey(providerID: .codex, digest: accountDigest),
            source: source,
            sourceVersion: UsageDigest.sha256Data(data),
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Self.accessTokenExpiry(accessToken),
            accountID: accountID,
            planHint: nil
        )
    }

    private static func nonemptyString(_ object: [String: Any], path: [String]) -> String? {
        guard let value = CredentialJSON.string(object, path: path), !value.isEmpty else { return nil }
        return value
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

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func join(_ base: String, _ suffix: String) -> String {
        let trimmed = base.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "/\(suffix)" : "\(trimmed)/\(suffix)"
    }
}

private extension UsageDigest {
    static func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
