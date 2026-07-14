import Foundation

/// The result of a single provider usage refresh. Either a fresh snapshot
/// or a classified failure. Never carries partial credential data.
public struct UsageRefreshResult: Sendable {
    public let providerID: UsageProviderID
    public let snapshot: UsageSnapshot?
    public let failure: UsageProviderFailure?
    public let migrateCacheFrom: AccountCacheKey?

    public init(
        providerID: UsageProviderID,
        snapshot: UsageSnapshot?,
        failure: UsageProviderFailure?,
        migrateCacheFrom: AccountCacheKey? = nil
    ) {
        self.providerID = providerID
        self.snapshot = snapshot
        self.failure = failure
        self.migrateCacheFrom = migrateCacheFrom
    }
}

/// A usage provider knows how to resolve its access mode and refresh usage
/// for a given account. Implementations are Codex/Claude-specific; this
/// protocol is the seam the coordinator talks to.
public protocol UsageProvider: Sendable {
    var providerID: UsageProviderID { get }

    /// Resolve how this provider should access credentials for the account
    /// identified by `accountKey` (or whichever account is available).
    func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess

    /// Fetch a fresh usage snapshot. Returns a failure for rate limits,
    /// network errors, service issues or stale-auth instead of throwing.
    func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult
}
