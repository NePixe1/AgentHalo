import Foundation
import AgentHaloCore

/// A lock-protected mutable box for checks. Marked `@unchecked Sendable`
/// only around the lock-protected value; everything goes through the lock.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) {
        self.stored = initial
    }

    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&stored)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Fake environment

final class FakeUsageEnvironment: UsageEnvironmentReading, @unchecked Sendable {
    private let values: LockedBox<[String: String]>

    init(_ values: [String: String] = [:]) {
        self.values = LockedBox(values)
    }

    func setValue(_ value: String?, for name: String) {
        values.withValue { dict in
            if let value = value {
                dict[name] = value
            } else {
                dict.removeValue(forKey: name)
            }
        }
    }

    func value(for name: String) -> String? {
        values.value[name]
    }
}

// MARK: - Fake files

/// A snapshot of a captured write, including the mode that was preserved.
struct FakeUsageFileWrite: Equatable {
    let path: String
    let data: Data
    let preservingModeOf: String?
}

enum FakeUsageFilesError: Error {
    case transientRead
}

final class FakeUsageFiles: UsageFileAccessing, @unchecked Sendable {
    /// Existing file contents keyed by path (the "disk").
    private let disk: LockedBox<[String: Data]>
    /// Existing posix modes keyed by path.
    private let modes: LockedBox<[String: mode_t]>
    /// Captured writes in order.
    private let writes: LockedBox<[FakeUsageFileWrite]>
    /// Number of upcoming reads that should fail before normal reads resume.
    private let remainingReadFailures: LockedBox<Int>

    init(
        contents: [String: Data] = [:],
        modes: [String: mode_t] = [:],
        readFailures: Int = 0
    ) {
        self.disk = LockedBox(contents)
        self.modes = LockedBox(modes)
        self.writes = LockedBox([])
        self.remainingReadFailures = LockedBox(readFailures)
    }

    func readDataIfPresent(at path: String) throws -> Data? {
        let shouldFail = remainingReadFailures.withValue { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if shouldFail {
            throw FakeUsageFilesError.transientRead
        }
        return disk.value[path]
    }

    func ensureDirectory(at path: String, mode: mode_t) throws {}

    func writeAtomically(_ data: Data, to path: String, preservingModeOf existingPath: String?) throws {
        let resolved = existingPath ?? (disk.value[path] != nil ? path : nil)
        let mode: mode_t
        if let existing = resolved {
            mode = modes.value[existing] ?? 0o600
        } else {
            mode = 0o600
        }
        disk.withValue { dict in dict[path] = data }
        modes.withValue { dict in dict[path] = mode }
        writes.withValue { array in
            array.append(FakeUsageFileWrite(path: path, data: data, preservingModeOf: existingPath))
        }
    }

    func capturedWrites() -> [FakeUsageFileWrite] {
        writes.value
    }

    func storedMode(for path: String) -> mode_t? {
        modes.value[path]
    }
}

// MARK: - Fake keychain

/// Keychain keyed by `service` plus optional `account`. Never logs the
/// stored values; equality failures only compare counts and presence.
final class FakeUsageKeychain: UsageKeychainAccessing, @unchecked Sendable {
    struct Key: Hashable {
        let service: String
        let account: String?
    }

    private let store: LockedBox<[Key: String]>

    init() {
        self.store = LockedBox([:])
    }

    func read(service: String, account: String?) throws -> String? {
        store.value[Key(service: service, account: account)]
    }

    func readFirstMatching(service: String) throws -> UsageKeychainItem? {
        store.value
            .compactMap { key, value -> UsageKeychainItem? in
                guard key.service == service, let account = key.account, !account.isEmpty else {
                    return nil
                }
                return UsageKeychainItem(account: account, value: value)
            }
            .sorted { $0.account < $1.account }
            .first
    }

    func write(service: String, account: String?, value: String) throws {
        store.withValue { dict in
            dict[Key(service: service, account: account)] = value
        }
    }

    func contains(service: String, account: String?) -> Bool {
        store.value[Key(service: service, account: account)] != nil
    }
}

// MARK: - Recording process runner

struct RecordedUsageProcessCall: Equatable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

final class RecordingUsageProcessRunner: UsageProcessRunning, @unchecked Sendable {
    private struct State {
        var results: [UsageProcessResult]
        var calls: [RecordedUsageProcessCall] = []
    }

    private let state: LockedBox<State>

    init(results: [UsageProcessResult]) {
        state = LockedBox(State(results: results))
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> UsageProcessResult {
        state.withValue { state in
            state.calls.append(
                RecordedUsageProcessCall(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            )
            guard !state.results.isEmpty else {
                return UsageProcessResult(exitCode: 44, standardOutput: Data(), standardError: Data())
            }
            return state.results.removeFirst()
        }
    }

    func capturedCalls() -> [RecordedUsageProcessCall] {
        state.value.calls
    }
}

// MARK: - Recording HTTP client

/// An HTTP client actor that returns queued responses/errors and records
/// the requests it received. Never logs request headers or bodies.
actor RecordingUsageHTTPClient: UsageHTTPClient {
    private var queuedResponses: [UsageHTTPResponse] = []
    private var queuedErrors: [UsageProviderFailure?] = []
    private(set) var capturedRequests: [UsageHTTPRequest] = []

    func enqueue(response: UsageHTTPResponse) {
        queuedResponses.append(response)
    }

    func enqueue(error: UsageProviderFailure) {
        queuedErrors.append(error)
    }

    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        capturedRequests.append(request)
        if !queuedErrors.isEmpty {
            let error = queuedErrors.removeFirst()
            if let error = error {
                throw error
            }
        }
        if queuedResponses.isEmpty {
            return UsageHTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        return queuedResponses.removeFirst()
    }
}

// MARK: - Fake usage provider

/// A controllable usage provider for checks: injectable access result and
/// refresh result/error, plus call counting and an optional continuation
/// gate so a check can pause refresh until it's ready.
actor FakeUsageProvider: UsageProvider {
    nonisolated let providerID: UsageProviderID

    private var resolveResult: ResolvedProviderAccess
    private var refreshResult: UsageRefreshResult?
    private var refreshError: UsageProviderFailure?
    private(set) var resolveCallCount = 0
    private(set) var refreshCallCount = 0
    private var gate: AsyncStream<Void>?
    private var gateContinuation: AsyncStream<Void>.Continuation?

    init(providerID: UsageProviderID, resolveResult: ResolvedProviderAccess = .apiKey) {
        self.providerID = providerID
        self.resolveResult = resolveResult
    }

    func setResolveResult(_ result: ResolvedProviderAccess) {
        resolveResult = result
    }

    func setRefreshResult(_ result: UsageRefreshResult?) {
        refreshResult = result
        refreshError = nil
    }

    func setRefreshError(_ error: UsageProviderFailure?) {
        refreshError = error
    }

    /// Install a one-shot gate: `refresh(using:)` will await a single
    /// `resume()` call before returning. Used to test ordering against
    /// the coordinator.
    func installGate() {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont in
            continuation = cont
        }
        self.gate = stream
        self.gateContinuation = continuation
    }

    func resume() {
        gateContinuation?.finish()
    }

    func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess {
        resolveCallCount += 1
        return resolveResult
    }

    func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        refreshCallCount += 1
        if let gate = gate {
            _ = await firstValue(from: gate)
            self.gate = nil
        }
        if let error = refreshError {
            return UsageRefreshResult(providerID: providerID, snapshot: nil, failure: error)
        }
        if let result = refreshResult {
            return result
        }
        return UsageRefreshResult(providerID: providerID, snapshot: nil, failure: nil)
    }
}

private func firstValue(from stream: AsyncStream<Void>) async -> Void? {
    for await value in stream {
        return value
    }
    return nil
}
