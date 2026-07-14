import Foundation

/// A Provider-to-Coordinator outcome. An external login/source replacement is
/// deliberately distinct from both a request failure and internal cache-key
/// migration: only the Coordinator may establish the new access generation.
public enum UsageRefreshOutcome: Sendable {
    case snapshot(UsageSnapshot, migrateCacheFrom: AccountCacheKey?)
    case failure(UsageProviderFailure)
    case externalAccessChanged
}

/// The result of a single provider usage refresh. Never carries partial
/// credential data or encodes an external login as cache migration.
public struct UsageRefreshResult: Sendable {
    public let providerID: UsageProviderID
    public let outcome: UsageRefreshOutcome

    public var snapshot: UsageSnapshot? {
        guard case .snapshot(let snapshot, _) = outcome else { return nil }
        return snapshot
    }

    public var failure: UsageProviderFailure? {
        guard case .failure(let failure) = outcome else { return nil }
        return failure
    }

    public var migrateCacheFrom: AccountCacheKey? {
        guard case .snapshot(_, let oldKey) = outcome else { return nil }
        return oldKey
    }

    public init(
        providerID: UsageProviderID,
        snapshot: UsageSnapshot?,
        failure: UsageProviderFailure?,
        migrateCacheFrom: AccountCacheKey? = nil
    ) {
        self.providerID = providerID
        if let failure {
            self.outcome = .failure(failure)
        } else if let snapshot {
            self.outcome = .snapshot(snapshot, migrateCacheFrom: migrateCacheFrom)
        } else {
            self.outcome = .failure(.invalidResponse)
        }
    }

    public init(providerID: UsageProviderID, outcome: UsageRefreshOutcome) {
        self.providerID = providerID
        self.outcome = outcome
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
