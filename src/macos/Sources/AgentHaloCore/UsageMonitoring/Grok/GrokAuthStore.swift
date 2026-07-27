import CryptoKit
import Foundation

/// Result of rotating a Grok OAuth access token. Written back into the matching
/// `~/.grok/auth.json` entry by `GrokAuthStore.persist`.
public struct GrokTokenRotation: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum GrokAuthError: Error, Equatable, Sendable {
    /// Present `auth.json` could not be parsed as a JSON object. Persist must
    /// refuse to overwrite so other accounts are not wiped.
    case invalidAuth
}

/// Loads and rotates Grok CLI OAuth credentials from `~/.grok/auth.json`.
///
/// The file is a map of `issuer::client_id` → entry. Each entry holds `key`
/// (access token), `refresh_token`, optional `expires_at`, and identity fields
/// used only for the account digest. Persist updates a single entry and leaves
/// every other account untouched; a corrupt file never gets rebuilt from memory.
public struct GrokAuthStore: Sendable {
    public static let refreshWindow: TimeInterval = 5 * 60
    /// Shared with `GrokUsageClient.defaultClientID` (single source of truth).
    public static let defaultClientID = GrokUsageClient.defaultClientID

    private let homeDirectory: URL?
    private let environment: any UsageEnvironmentReading
    private let files: any UsageFileAccessing
    private let now: @Sendable () -> Date

    public init(
        homeDirectory: URL? = nil,
        environment: any UsageEnvironmentReading = ProcessInfoUsageEnvironment(),
        files: any UsageFileAccessing = FilesystemUsageFiles(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.files = files
        self.now = now
    }

    public func resolveAccess() -> ResolvedProviderAccess {
        guard let candidate = firstCandidate() else {
            return .oauthNeedsSignIn(accountKey: nil)
        }
        return .oauth(candidate.access)
    }

    /// Reloads the exact credential file (or keychain item) and re-resolves.
    /// Never discovers alternate paths, so refresh/retry cannot migrate sources.
    public func reloadResolved(source: CredentialSource) -> ResolvedProviderAccess {
        do {
            guard let payload = try readPayload(from: source),
                  let candidate = firstCandidate(in: payload, source: source)
            else {
                return .oauthNeedsSignIn(accountKey: nil)
            }
            return .oauth(candidate.access)
        } catch {
            return .oauthNeedsSignIn(accountKey: nil)
        }
    }

    public func needsRefresh(_ access: OAuthAccess) -> Bool {
        guard let expiresAt = access.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshWindow
    }

    /// OIDC client id for token refresh: entry `oidc_client_id`, then the
    /// `::` suffix of the entry key, then the Grok CLI default.
    public func clientID(for access: OAuthAccess) -> String {
        guard let payload = try? readPayload(from: access.source),
              let match = findEntry(in: payload.object, matchingAccessToken: access.accessToken)
        else {
            return Self.defaultClientID
        }
        return Self.clientID(entryKey: match.entryKey, entry: match.entry)
    }

    public func persist(
        rotation: GrokTokenRotation,
        replacing expected: OAuthAccess
    ) throws -> OAuthAccess? {
        guard expected.providerID == .grok else { return nil }

        let path: String
        switch expected.source {
        case .file(let filePath):
            path = filePath
        case .keychain:
            return nil
        }

        guard let data = try files.readDataIfPresent(at: path) else { return nil }
        guard let object = try? CredentialJSON.object(from: data) else {
            throw GrokAuthError.invalidAuth
        }

        guard let match = findEntry(in: object, matchingAccessToken: expected.accessToken) else {
            return nil
        }
        let currentAccess = makeAccess(
            entryKey: match.entryKey,
            entry: match.entry,
            source: expected.source
        )
        guard currentAccess.sourceVersion == expected.sourceVersion else {
            return nil
        }

        var root = object
        var entryObject = match.entry
        entryObject["key"] = rotation.accessToken
        if let refreshToken = rotation.refreshToken {
            entryObject["refresh_token"] = refreshToken
        }
        if let expiresAt = rotation.expiresAt {
            entryObject["expires_at"] = Self.formatExpiresAt(expiresAt)
        }
        root[match.entryKey] = entryObject

        let rotatedData = try CredentialJSON.data(from: root, prettyPrinted: true)
        try files.writeAtomically(rotatedData, to: path, preservingModeOf: path)

        return makeAccess(
            entryKey: match.entryKey,
            entry: entryObject,
            source: expected.source
        )
    }

    // MARK: - Internals

    private struct Payload {
        var data: Data
        var object: [String: Any]
    }

    private struct Candidate {
        var entryKey: String
        var entry: [String: Any]
        var access: OAuthAccess
    }

    private func authPath() -> String {
        let home: String
        if let homeDirectory {
            home = homeDirectory.path
        } else {
            home = environment.value(for: "HOME")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return Self.join(home, ".grok/auth.json")
    }

    private func firstCandidate() -> Candidate? {
        let source = CredentialSource.file(path: authPath())
        guard let payload = try? readPayload(from: source) else { return nil }
        return firstCandidate(in: payload, source: source)
    }

    private func firstCandidate(in payload: Payload, source: CredentialSource) -> Candidate? {
        // Sorted keys give stable multi-account selection (client-a before client-b).
        for entryKey in payload.object.keys.sorted() {
            guard let entry = payload.object[entryKey] as? [String: Any],
                  Self.nonemptyString(entry["key"]) != nil
            else {
                continue
            }
            let access = makeAccess(entryKey: entryKey, entry: entry, source: source)
            return Candidate(entryKey: entryKey, entry: entry, access: access)
        }
        return nil
    }

    private func readPayload(from source: CredentialSource) throws -> Payload? {
        let data: Data
        switch source {
        case .file(let path):
            guard let stored = try files.readDataIfPresent(at: path) else { return nil }
            data = stored
        case .keychain:
            return nil
        }
        guard let object = try? CredentialJSON.object(from: data) else { return nil }
        return Payload(data: data, object: object)
    }

    private func findEntry(
        in object: [String: Any],
        matchingAccessToken accessToken: String
    ) -> (entryKey: String, entry: [String: Any])? {
        for entryKey in object.keys.sorted() {
            guard let entry = object[entryKey] as? [String: Any],
                  Self.nonemptyString(entry["key"]) == accessToken
            else {
                continue
            }
            return (entryKey, entry)
        }
        return nil
    }

    private func makeAccess(
        entryKey: String,
        entry: [String: Any],
        source: CredentialSource
    ) -> OAuthAccess {
        let accessToken = Self.nonemptyString(entry["key"]) ?? ""
        let refreshToken = Self.nonemptyString(entry["refresh_token"])
            ?? Self.nonemptyString(entry["refresh"])
        let userID = Self.nonemptyString(entry["user_id"])
        let email = Self.nonemptyString(entry["email"])
        let identity = userID ?? email ?? entryKey
        let accountDigest = UsageDigest.sha256(identity)

        let entryExpires = Self.parseExpiresAt(
            Self.nonemptyString(entry["expires_at"]) ?? Self.nonemptyString(entry["expires"])
        )
        let jwtExpires = Self.tokenExpiresAt(accessToken)
        let expiresAt: Date?
        switch (entryExpires, jwtExpires) {
        case let (entry?, jwt?):
            expiresAt = min(entry, jwt)
        case let (entry?, nil):
            expiresAt = entry
        case let (nil, jwt?):
            expiresAt = jwt
        case (nil, nil):
            expiresAt = nil
        }

        return OAuthAccess(
            providerID: .grok,
            accountKey: AccountCacheKey(providerID: .grok, digest: accountDigest),
            source: source,
            sourceVersion: Self.sourceVersion(entryKey: entryKey, entry: entry),
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountID: userID,
            planHint: nil
        )
    }

    private static func sourceVersion(entryKey: String, entry: [String: Any]) -> String {
        func jsonField(_ key: String) -> Any {
            guard let value = entry[key] else { return NSNull() }
            if value is NSNull { return NSNull() }
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number }
            return String(describing: value)
        }
        let fields: [String: Any] = [
            "entryKey": entryKey,
            "key": jsonField("key"),
            "refresh_token": jsonField("refresh_token"),
            "refresh": jsonField("refresh"),
            "expires_at": jsonField("expires_at"),
            "expires": jsonField("expires"),
            "user_id": jsonField("user_id"),
            "email": jsonField("email"),
            "oidc_client_id": jsonField("oidc_client_id"),
        ]
        let canonical = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    static func clientID(entryKey: String, entry: [String: Any]) -> String {
        if let oidc = nonemptyString(entry["oidc_client_id"]) {
            return oidc
        }
        let parts = entryKey.split(separator: "::", omittingEmptySubsequences: false)
        if let last = parts.last {
            let value = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return defaultClientID
    }

    private static func tokenExpiresAt(_ token: String) -> Date? {
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

    private static func parseExpiresAt(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func formatExpiresAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func join(_ base: String, _ suffix: String) -> String {
        let trimmed = base.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "/\(suffix)" : "\(trimmed)/\(suffix)"
    }
}
