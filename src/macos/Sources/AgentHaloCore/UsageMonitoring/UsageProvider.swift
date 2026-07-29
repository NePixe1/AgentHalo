import Foundation

public enum UsageProviderFocusError: Error, Equatable, Sendable {
    case inactiveProvider
}

public struct UsageProviderFocusAuthorization: Sendable {
    fileprivate let providerID: UsageProviderID
    fileprivate let generation: UInt64
    fileprivate let controller: UsageProviderFocusController

    public func check() throws {
        try Task.checkCancellation()
        try controller.check(self)
    }

    public func performCredentialWrite<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        return try controller.performCredentialWrite(self, operation)
    }
}

/// Synchronous focus authority shared by the app, coordinator and real OAuth
/// providers. A focus transition invalidates every previously issued
/// authorization, including authorizations for the same provider from an older
/// focus generation.
///
/// Credential writes run while the focus lock is held (see
/// `performCredentialWrite`). That serializes persistence against activate /
/// deactivate so a completed focus transition never races an older write, at
/// the cost of delaying abort handlers until disk/Keychain I/O finishes.
public final class UsageProviderFocusController: @unchecked Sendable {
    private struct CancellationRegistration {
        let providerID: UsageProviderID
        let generation: UInt64
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var activeProviderID: UsageProviderID?
    private var enforcesFocus = false
    private var generation: UInt64 = 0
    private var cancellations: [UUID: CancellationRegistration] = [:]

    public init() {}

    public func activate(_ providerID: UsageProviderID) {
        let handlers: [@Sendable () -> Void]
        lock.lock()
        generation &+= 1
        enforcesFocus = true
        activeProviderID = providerID
        handlers = cancellations.values.map(\.cancel)
        cancellations.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    public func deactivateAll() {
        let handlers: [@Sendable () -> Void]
        lock.lock()
        generation &+= 1
        enforcesFocus = true
        activeProviderID = nil
        handlers = cancellations.values.map(\.cancel)
        cancellations.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    public func authorization(
        for providerID: UsageProviderID
    ) -> UsageProviderFocusAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        if enforcesFocus && activeProviderID != providerID {
            return nil
        }
        return UsageProviderFocusAuthorization(
            providerID: providerID,
            generation: generation,
            controller: self
        )
    }

    public func isActive(_ providerID: UsageProviderID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !enforcesFocus || activeProviderID == providerID
    }

    public func isCurrent(_ authorization: UsageProviderFocusAuthorization) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(authorization)
    }

    @discardableResult
    public func registerCancellation(
        token: UUID,
        authorization: UsageProviderFocusAuthorization,
        cancel: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        let current = isCurrentLocked(authorization)
        if current {
            cancellations[token] = CancellationRegistration(
                providerID: authorization.providerID,
                generation: authorization.generation,
                cancel: cancel
            )
        }
        lock.unlock()
        if !current {
            cancel()
        }
        return current
    }

    public func unregisterCancellation(token: UUID) {
        lock.lock()
        cancellations.removeValue(forKey: token)
        lock.unlock()
    }

    fileprivate func check(
        _ authorization: UsageProviderFocusAuthorization
    ) throws {
        lock.lock()
        let current = isCurrentLocked(authorization)
        lock.unlock()
        if !current {
            throw UsageProviderFocusError.inactiveProvider
        }
    }

    /// Runs `operation` while holding the focus lock after verifying
    /// `authorization` is still current. Callers must not re-enter the
    /// controller from `operation` (would deadlock). Prefer short file /
    /// Keychain work only — long I/O postpones focus transitions and abort.
    fileprivate func performCredentialWrite<T>(
        _ authorization: UsageProviderFocusAuthorization,
        _ operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(authorization) else {
            throw UsageProviderFocusError.inactiveProvider
        }
        return try operation()
    }

    private func isCurrentLocked(
        _ authorization: UsageProviderFocusAuthorization
    ) -> Bool {
        guard authorization.controller === self,
              authorization.generation == generation
        else {
            return false
        }
        return !enforcesFocus ||
            activeProviderID == authorization.providerID
    }
}

/// A Provider-to-Coordinator outcome. An external login/source replacement is
/// deliberately distinct from both a request failure and internal cache-key
/// migration: only the Coordinator may establish the new access generation.
///
/// `cancelled` means focus became inactive or the refresh task was cancelled;
/// it must not surface as sign-in-again or a network failure in the UI.
public enum UsageRefreshOutcome: Sendable {
    case snapshot(UsageSnapshot, migrateCacheFrom: AccountCacheKey?)
    case failure(UsageProviderFailure)
    case externalAccessChanged
    case cancelled

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
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
