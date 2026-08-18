import Foundation

/// Tokens stored in the Antigravity Keychain item (`gemini` / `antigravity`).
/// The production store never writes this item; refreshed access tokens live
/// only in `antigravity-auth.json`.
public struct AntigravityKeychainToken: Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiry: Date?

    public init(accessToken: String?, refreshToken: String?, expiry: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }
}

/// Resolves Antigravity OAuth access from Keychain and a local fingerprint cache.
///
/// `resolveAccess` never returns `.apiKey`. Missing Keychain with a discoverable
/// language server still yields `.oauth` so the coordinator will call `refresh()`.
public struct AntigravityAuthStore: Sendable {
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"
    public static let refreshBuffer: TimeInterval = 60
    public static let localLSAccountDigest = UsageDigest.sha256("antigravity-ls")

    private static let goKeyringPrefix = "go-keyring-base64:"
    private static let cacheFileName = "antigravity-auth.json"
    private static let lsSourceFileName = "antigravity-ls"

    private let homeDirectory: URL
    private let keychain: any UsageKeychainAccessing
    private let files: any UsageFileAccessing
    private let now: @Sendable () -> Date
    private let memo: AntigravityKeychainMemo

    public init(
        homeDirectory: URL,
        keychain: any UsageKeychainAccessing,
        files: any UsageFileAccessing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.keychain = keychain
        self.files = files
        self.now = now
        self.memo = AntigravityKeychainMemo()
    }

    public func resolveAccess(lsAvailable: Bool) -> ResolvedProviderAccess {
        let token: AntigravityKeychainToken?
        do {
            token = try loadKeychainToken()
        } catch {
            return lsAvailable ? lsOnlyAccess() : .oauthNeedsSignIn(accountKey: nil)
        }
        if let token {
            return .oauth(makeOAuthAccess(from: token))
        }
        if lsAvailable {
            return lsOnlyAccess()
        }
        return .oauthNeedsSignIn(accountKey: nil)
    }

    public func loadKeychainToken() throws -> AntigravityKeychainToken? {
        try memo.load {
            let raw = try keychain.read(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
            guard let raw else { return nil }
            return Self.extractToken(fromKeychainRaw: raw)
        }
    }

    public func loadCachedAccessToken(matching source: AntigravityKeychainToken) -> String? {
        guard let expectedFingerprint = Self.credentialFingerprint(for: source.refreshToken) else {
            discardCachedToken()
            return nil
        }
        let data: Data
        do {
            guard let stored = try files.readDataIfPresent(at: cacheFileURL().path) else {
                return nil
            }
            data = stored
        } catch {
            return nil
        }
        guard let cached = try? JSONDecoder().decode(CachedAccessToken.self, from: data) else {
            discardCachedToken()
            return nil
        }
        let remainingThresholdMs = (now().timeIntervalSince1970 + Self.refreshBuffer) * 1_000
        let token = cached.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cached.credentialFingerprint == expectedFingerprint,
              cached.expiresAtMs > remainingThresholdMs,
              !token.isEmpty
        else {
            discardCachedToken()
            return nil
        }
        return token
    }

    public func cacheAccessToken(
        _ token: String,
        expiresIn: Double,
        sourceRefreshToken: String
    ) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let fingerprint = Self.credentialFingerprint(for: sourceRefreshToken)
        else {
            return
        }
        let cached = CachedAccessToken(
            accessToken: trimmed,
            expiresAtMs: (now().timeIntervalSince1970 + expiresIn) * 1_000,
            credentialFingerprint: fingerprint
        )
        let data = try JSONEncoder().encode(cached)
        let url = cacheFileURL()
        try files.ensureDirectory(at: url.deletingLastPathComponent().path, mode: 0o700)
        let existingPath: String?
        if (try? files.readDataIfPresent(at: url.path)) != nil {
            existingPath = url.path
        } else {
            existingPath = nil
        }
        try files.writeAtomically(data, to: url.path, preservingModeOf: existingPath)
    }

    public func isUsable(expiry: Date?) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now()) > Self.refreshBuffer
    }

    /// Decode a Keychain value: optional `go-keyring-base64:` wrapper, nested
    /// `token.access_token`, a `Bearer` prefix, or a raw token. Broken JSON is nil.
    public static func extractToken(fromKeychainRaw raw: String) -> AntigravityKeychainToken? {
        let boundaryCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        let normalizedRaw = raw.trimmingCharacters(in: boundaryCharacters)
        let text = unwrapGoKeyring(normalizedRaw).trimmingCharacters(in: boundaryCharacters)
        guard !text.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            if let dict = json as? [String: Any] {
                return tokenFromObject(dict)
            }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return AntigravityKeychainToken(accessToken: string, refreshToken: nil, expiry: nil)
            }
            return nil
        }

        if text.hasPrefix("{") || text.hasPrefix("[") {
            return nil
        }

        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            return AntigravityKeychainToken(accessToken: token, refreshToken: nil, expiry: nil)
        }
        return AntigravityKeychainToken(accessToken: text, refreshToken: nil, expiry: nil)
    }

    // MARK: - Internals

    private struct CachedAccessToken: Codable {
        var accessToken: String
        var expiresAtMs: Double
        var credentialFingerprint: String
    }

    private func cacheFileURL() -> URL {
        AgentHaloPaths(homeDirectory: homeDirectory).cacheDirectory
            .appendingPathComponent(Self.cacheFileName)
    }

    private func lsOnlyAccess() -> ResolvedProviderAccess {
        let lsPath = AgentHaloPaths(homeDirectory: homeDirectory).cacheDirectory
            .appendingPathComponent(Self.lsSourceFileName).path
        return .oauth(
            OAuthAccess(
                providerID: .antigravity,
                accountKey: AccountCacheKey(
                    providerID: .antigravity,
                    digest: Self.localLSAccountDigest
                ),
                source: .file(path: lsPath),
                sourceVersion: Self.localLSAccountDigest,
                accessToken: "",
                refreshToken: nil,
                expiresAt: nil,
                accountID: nil,
                planHint: nil
            )
        )
    }

    private func makeOAuthAccess(from token: AntigravityKeychainToken) -> OAuthAccess {
        OAuthAccess(
            providerID: .antigravity,
            accountKey: AccountCacheKey(providerID: .antigravity, digest: accountDigest(for: token)),
            source: .keychain(service: Self.keychainService, account: Self.keychainAccount),
            sourceVersion: sourceVersion(for: token),
            accessToken: token.accessToken ?? "",
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            accountID: nil,
            planHint: nil
        )
    }

    private func accountDigest(for token: AntigravityKeychainToken) -> String {
        if let fingerprint = Self.credentialFingerprint(for: token.refreshToken) {
            return UsageDigest.sha256(fingerprint)
        }
        if let fingerprint = Self.credentialFingerprint(for: token.accessToken) {
            return UsageDigest.sha256(fingerprint)
        }
        return UsageDigest.sha256("\(Self.keychainService)|\(Self.keychainAccount)")
    }

    private func sourceVersion(for token: AntigravityKeychainToken) -> String {
        let fields = [
            token.accessToken ?? "",
            token.refreshToken ?? "",
            token.expiry.map { String($0.timeIntervalSince1970) } ?? "",
        ].joined(separator: "|")
        return UsageDigest.sha256(fields)
    }

    /// `UsageFileAccessing` has no `remove`; overwrite a stale cache with `{}`.
    private func discardCachedToken() {
        let path = cacheFileURL().path
        guard (try? files.readDataIfPresent(at: path)) != nil else { return }
        try? files.writeAtomically(Data("{}".utf8), to: path, preservingModeOf: path)
    }

    private static func credentialFingerprint(for refreshToken: String?) -> String? {
        guard let refreshToken else { return nil }
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UsageDigest.sha256(trimmed)
    }

    /// One Security prompt per process. Ad-hoc builds cannot persist
    /// "Always Allow" across launches; we still must not re-prompt in-session.
    fileprivate final class AntigravityKeychainMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var state: State = .empty

        private enum State {
            case empty
            case loaded(AntigravityKeychainToken?)
            case denied(UsageKeychainError)
        }

        func load(_ read: () throws -> AntigravityKeychainToken?) throws -> AntigravityKeychainToken? {
            lock.lock()
            defer { lock.unlock() }
            switch state {
            case .loaded(let token):
                return token
            case .denied(let error):
                throw error
            case .empty:
                do {
                    let token = try read()
                    state = .loaded(token)
                    return token
                } catch {
                    if let denied = error as? UsageKeychainError, denied.isAuthorizationDenied {
                        state = .denied(denied)
                    }
                    throw error
                }
            }
        }
    }

    /// Strip `go-keyring-base64:` and base64-decode. Decode failure keeps the original text.
    private static func unwrapGoKeyring(_ raw: String) -> String {
        guard raw.hasPrefix(goKeyringPrefix) else { return raw }
        let encoded = String(raw.dropFirst(goKeyringPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return raw
        }
        return decoded
    }

    private static func tokenFromObject(_ object: [String: Any]) -> AntigravityKeychainToken? {
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, [
            "access_token", "accessToken", "token", "id_token", "idToken",
            "bearerToken", "auth_token", "authToken",
        ])
        let refresh = firstString(source, ["refresh_token", "refreshToken"])
        let expiry = firstString(source, ["expiry", "expires_at", "expiresAt"]).flatMap(parseExpiry)

        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = tokenFromObject(nested) {
                    return token
                }
            }
            return nil
        }
        return AntigravityKeychainToken(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = (object[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
