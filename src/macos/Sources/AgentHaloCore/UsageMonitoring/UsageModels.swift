import Foundation
import CryptoKit

/// Provider identifiers for usage monitoring. Codex and Claude are the only
/// supported surfaces; balance/credits/spark providers are explicitly excluded.
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
}

/// How a provider's credentials are accessed. Drives the access-mode badge
/// in the UI; there is no third "balance/credits" mode.
public enum AccessMode: String, Codable, Sendable {
    case oauth
    case apiKey
}

/// Usage window granularity. Sessions map to short windows; weekly to long ones.
public enum UsageWindowKind: String, Codable, Sendable {
    case session
    case weekly
}

/// A single usage window (e.g. "5h session" or "weekly") with its used percent,
/// optional reset time and window duration in seconds.
public struct UsageWindow: Codable, Equatable, Sendable {
    public var kind: UsageWindowKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var duration: TimeInterval

    public init(
        kind: UsageWindowKind,
        usedPercent: Double,
        resetsAt: Date?,
        duration: TimeInterval
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
    }
}

/// A cache key for a provider account. `digest` is a SHA256 hex of the
/// account/source identity — never the raw token. Used as a stable,
/// non-credential-leaking identifier for cache files and per-account state.
public struct AccountCacheKey: Codable, Hashable, Sendable {
    public var providerID: UsageProviderID
    public var digest: String

    public init(providerID: UsageProviderID, digest: String) {
        self.providerID = providerID
        self.digest = digest
    }
}

/// A provider-neutral usage snapshot: which account, plan name, the windows
/// of usage and the refresh time. Cached and surfaced to the UI.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var providerID: UsageProviderID
    public var accountKey: AccountCacheKey
    public var planName: String?
    public var windows: [UsageWindow]
    public var refreshedAt: Date

    public init(
        providerID: UsageProviderID,
        accountKey: AccountCacheKey,
        planName: String?,
        windows: [UsageWindow],
        refreshedAt: Date
    ) {
        self.providerID = providerID
        self.accountKey = accountKey
        self.planName = planName
        self.windows = windows
        self.refreshedAt = refreshedAt
    }
}

/// Coarse status of the cached usage data, surfaced to the panel.
public enum UsageDataStatus: Equatable, Sendable {
    case fresh(updatedAt: Date)
    case stale(updatedAt: Date)
    case noData
    case signInAgain
}

/// Why a usage refresh failed. Mirrors `UsageProviderFailure` but is a
/// display-side enum so the UI layer does not depend on the error type.
public enum UsageFailureReason: Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case network
    case serviceUnavailable
    case invalidResponse
    case signInAgain
}

/// Aggregate per-provider monitor state for the panel.
public struct UsageMonitorState: Equatable, Sendable {
    public var providerID: UsageProviderID
    public var accessMode: AccessMode
    public var snapshot: UsageSnapshot?
    public var status: UsageDataStatus?
    public var lastFailure: UsageFailureReason?
    public var isRefreshing: Bool

    public init(
        providerID: UsageProviderID,
        accessMode: AccessMode,
        snapshot: UsageSnapshot? = nil,
        status: UsageDataStatus? = nil,
        lastFailure: UsageFailureReason? = nil,
        isRefreshing: Bool = false
    ) {
        self.providerID = providerID
        self.accessMode = accessMode
        self.snapshot = snapshot
        self.status = status
        self.lastFailure = lastFailure
        self.isRefreshing = isRefreshing
    }
}

/// Where a credential lives on disk or in the keychain. Used by auth stores
/// and the cache key digest.
public enum CredentialSource: Hashable, Sendable {
    case file(path: String)
    case keychain(service: String, account: String?)
}

/// Best-effort plan hints extracted from the OAuth response. Optional and
/// advisory only; never surfaces a third access mode.
public struct OAuthPlanHint: Equatable, Sendable {
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(subscriptionType: String?, rateLimitTier: String?) {
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }
}

/// A resolved OAuth access. Deliberately NOT Codable/CustomStringConvertible/
/// CustomDebugStringConvertible so it can never be serialized or printed by
/// accident — logging the token or refresh token is a credential leak.
public struct OAuthAccess: Sendable {
    public var providerID: UsageProviderID
    public var accountKey: AccountCacheKey
    public var source: CredentialSource
    public var sourceVersion: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountID: String?
    public var planHint: OAuthPlanHint?

    public init(
        providerID: UsageProviderID,
        accountKey: AccountCacheKey,
        source: CredentialSource,
        sourceVersion: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        accountID: String?,
        planHint: OAuthPlanHint?
    ) {
        self.providerID = providerID
        self.accountKey = accountKey
        self.source = source
        self.sourceVersion = sourceVersion
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.planHint = planHint
    }
}

/// The access mode a provider should run under. OAuth wins over "needs sign
/// in", which wins over API key. `apiKey` documents detection but never
/// creates a third UI mode beyond oauth/apiKey.
public enum ResolvedProviderAccess: Sendable {
    case oauth(OAuthAccess)
    case oauthNeedsSignIn(accountKey: AccountCacheKey?)
    case apiKey
}

/// Provider-facing usage refresh failure. Mirrors `UsageFailureReason`.
public enum UsageProviderFailure: Error, Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case network
    case serviceUnavailable
    case invalidResponse
    case signInAgain
}

/// SHA256 digest helper. Returns lowercase hex so digests are filesystem-safe
/// and never reveal the raw token. Used to build `AccountCacheKey.digest`.
public enum UsageDigest {
    /// Lowercase hex SHA256 of `value`. Always 64 characters.
    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
