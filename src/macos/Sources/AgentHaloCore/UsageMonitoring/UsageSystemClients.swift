import Foundation
import Security

/// Result of running an external process via `UsageProcessRunning`.
public struct UsageProcessResult: Sendable {
    public var exitCode: Int
    public var standardOutput: Data
    public var standardError: Data

    public init(exitCode: Int, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Injectable environment variable reader. Production reads `ProcessInfo`;
/// checks use `FakeUsageEnvironment`.
public protocol UsageEnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

/// Injectable file access. Production writes atomically with mode preservation
/// (see `FilesystemUsageFiles`); checks use `FakeUsageFiles`.
public protocol UsageFileAccessing: Sendable {
    func readDataIfPresent(at path: String) throws -> Data?
    func ensureDirectory(at path: String, mode: mode_t) throws
    func writeAtomically(_ data: Data, to path: String, preservingModeOf existingPath: String?) throws
}

/// Injectable keychain access. Production uses Security.framework; checks use
/// in-memory fakes and never touch the user's real Keychain.
public struct UsageKeychainItem: Equatable, Sendable {
    public var account: String
    public var value: String

    public init(account: String, value: String) {
        self.account = account
        self.value = value
    }
}

public protocol UsageKeychainAccessing: Sendable {
    func read(service: String, account: String?) throws -> String?
    func readFirstMatching(service: String) throws -> UsageKeychainItem?
    func write(service: String, account: String?, value: String) throws
}

/// A deliberately inert credential backend used only by packaged verification.
public struct DisabledUsageKeychain: UsageKeychainAccessing {
    public init() {}
    public func read(service: String, account: String?) throws -> String? { nil }
    public func readFirstMatching(service: String) throws -> UsageKeychainItem? { nil }
    public func write(service: String, account: String?, value: String) throws {
        throw UsageKeychainError.disabled
    }
}

public enum UsageMonitoringRuntimeMode: Equatable, Sendable {
    case production
    case packagedVerification
}

public enum UsageKeychainBackend: Equatable, Sendable {
    case securityFramework
    case disabled
}

public struct UsageKeychainDependency: Sendable {
    public let keychain: any UsageKeychainAccessing
    public let backend: UsageKeychainBackend
}

public enum UsageMonitoringDependencyFactory {
    public static func keychain(
        for mode: UsageMonitoringRuntimeMode,
        securityItems: @Sendable () -> any UsageSecurityItemAccessing = {
            SecurityFrameworkUsageItems()
        }
    ) -> UsageKeychainDependency {
        switch mode {
        case .production:
            return UsageKeychainDependency(
                keychain: SecurityUsageKeychain(items: securityItems()),
                backend: .securityFramework
            )
        case .packagedVerification:
            return UsageKeychainDependency(keychain: DisabledUsageKeychain(), backend: .disabled)
        }
    }
}

/// Injectable external-process runner. Production uses `Process`; checks
/// use a fake.
public protocol UsageProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> UsageProcessResult
}

// MARK: - Production adapters

/// Production environment reader backed by `ProcessInfo`.
public struct ProcessInfoUsageEnvironment: UsageEnvironmentReading {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func value(for name: String) -> String? {
        environment[name]
    }
}

/// Production file access. Atomic-replace writes that preserve the original
/// mode when present (otherwise `0600` for new cache files), clean up the
/// temporary file on every failure path.
///
/// Sequence: create a private temp file in the destination directory, read
/// the existing target mode (or default `0600`), `fchmod`, write all bytes,
/// `fsync`, close, `rename` over the target. Any failure removes the temp
/// file before propagating.
public final class FilesystemUsageFiles: UsageFileAccessing, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func readDataIfPresent(at path: String) throws -> Data? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func ensureDirectory(at path: String, mode: mode_t) throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOTDIR),
                    userInfo: [NSLocalizedDescriptionKey: "private directory path is not a directory: \(path)"]
                )
            }
        } else {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: path
        )
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard
            attributes[.type] as? FileAttributeType == .typeDirectory,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            mode_t(truncating: permissions) == mode
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "private directory permissions could not be enforced: \(path)"]
            )
        }
    }

    public func writeAtomically(
        _ data: Data,
        to path: String,
        preservingModeOf existingPath: String?
    ) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        let tempPath = directory
            .appending("/")
            .appending(".\(filename).tmp.\(UUID().uuidString)")

        // Resolve the mode to preserve: the explicit existing path, then the
        // target itself, otherwise 0600 for new cache files.
        let mode: mode_t
        if let existing = existingPath ?? (fileManager.fileExists(atPath: path) ? path : nil),
           let attributes = try? fileManager.attributesOfItem(atPath: existing),
           let number = attributes[.posixPermissions] as? NSNumber {
            mode = mode_t(truncating: number)
        } else {
            mode = 0o600
        }

        let createdFD = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard createdFD >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open temp file failed: \(tempPath)"]
            )
        }
        let fd = createdFD
        defer { close(fd) }
        var cleanup = TempCleanup(path: tempPath)
        defer { cleanup.runIfNeeded() }

        // Apply the resolved mode explicitly even if the file was just created
        // with it — umask may have masked bits.
        if fchmod(fd, mode) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "fchmod failed"]
            )
        }

        // Write all bytes.
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var remaining = buffer.count
            guard let base = buffer.baseAddress else { return }
            var ptr = base
            while remaining > 0 {
                let written = write(fd, ptr, remaining)
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(err),
                        userInfo: [NSLocalizedDescriptionKey: "write failed"]
                    )
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
        }

        // fsync before rename so the bytes are durable on disk.
        if fsync(fd) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "fsync failed"]
            )
        }

        // rename is atomic on the same filesystem.
        if rename(tempPath, path) != 0 {
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "rename failed"]
            )
        }
        cleanup.cancel()
    }
}

/// Helper that removes the temp file on failure paths and is a no-op once
/// the rename succeeds.
fileprivate struct TempCleanup {
    let path: String
    private var cancelled: Bool = false

    init(path: String) {
        self.path = path
    }

    mutating func cancel() { cancelled = true }
    mutating func runIfNeeded() {
        guard !cancelled else { return }
        unlink(path)
    }
}

public enum UsageSecurityStatus {
    public static let success: Int32 = errSecSuccess
    public static let itemNotFound: Int32 = errSecItemNotFound
}

public struct SecurityUsageKeychainQuery: Equatable, Sendable {
    public var service: String
    public var account: String?
    public var returnAttributes: Bool
    public var returnData: Bool

    public init(
        service: String,
        account: String?,
        returnAttributes: Bool,
        returnData: Bool
    ) {
        self.service = service
        self.account = account
        self.returnAttributes = returnAttributes
        self.returnData = returnData
    }
}

public struct SecurityUsageKeychainResult: Sendable {
    public var status: Int32
    public var account: String?
    public var data: Data?

    public init(status: Int32, account: String?, data: Data?) {
        self.status = status
        self.account = account
        self.data = data
    }
}

/// Injectable Security.framework boundary. Checks use an in-memory fake and
/// therefore never read or mutate the developer's real Keychain.
public protocol UsageSecurityItemAccessing: Sendable {
    func copyMatching(_ query: SecurityUsageKeychainQuery) -> SecurityUsageKeychainResult
    func update(_ query: SecurityUsageKeychainQuery, value: Data) -> Int32
    func add(service: String, account: String?, value: Data) -> Int32
}

public final class SecurityFrameworkUsageItems: UsageSecurityItemAccessing, @unchecked Sendable {
    public init() {}

    public func copyMatching(
        _ query: SecurityUsageKeychainQuery
    ) -> SecurityUsageKeychainResult {
        var attributes = baseQuery(service: query.service, account: query.account)
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        if query.returnAttributes { attributes[kSecReturnAttributes] = kCFBooleanTrue }
        if query.returnData { attributes[kSecReturnData] = kCFBooleanTrue }

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &rawResult)
        guard status == errSecSuccess else {
            return SecurityUsageKeychainResult(status: status, account: nil, data: nil)
        }

        let dictionary = rawResult as? NSDictionary
        let account = dictionary?[kSecAttrAccount] as? String
        let data = (rawResult as? Data) ?? (dictionary?[kSecValueData] as? Data)
        return SecurityUsageKeychainResult(status: status, account: account, data: data)
    }

    public func update(_ query: SecurityUsageKeychainQuery, value: Data) -> Int32 {
        let matching = baseQuery(service: query.service, account: query.account)
        let changes: [CFString: Any] = [kSecValueData: value]
        return SecItemUpdate(matching as CFDictionary, changes as CFDictionary)
    }

    public func add(service: String, account: String?, value: Data) -> Int32 {
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData] = value
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(service: String, account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account { query[kSecAttrAccount] = account }
        return query
    }
}

/// Production keychain access through Security.framework. Metadata lookup
/// requests attributes only; secret data is requested only by exact reads and
/// write bytes never leave the process through argv, stdin, stderr or logs.
public final class SecurityUsageKeychain: UsageKeychainAccessing {
    private let items: any UsageSecurityItemAccessing

    public init(items: any UsageSecurityItemAccessing = SecurityFrameworkUsageItems()) {
        self.items = items
    }

    public func read(service: String, account: String?) throws -> String? {
        guard let account, !account.isEmpty else {
            throw UsageKeychainError.missingExactAccount
        }
        let result = items.copyMatching(
            SecurityUsageKeychainQuery(
                service: service,
                account: account,
                returnAttributes: false,
                returnData: true
            )
        )
        switch result.status {
        case UsageSecurityStatus.success:
            guard let data = result.data else { return nil }
            return String(data: data, encoding: .utf8)
        case UsageSecurityStatus.itemNotFound:
            return nil
        default:
            throw UsageKeychainError.unexpectedExitCode(Int(result.status))
        }
    }

    public func readFirstMatching(service: String) throws -> UsageKeychainItem? {
        let metadata = items.copyMatching(
            SecurityUsageKeychainQuery(
                service: service,
                account: nil,
                returnAttributes: true,
                returnData: false
            )
        )
        switch metadata.status {
        case UsageSecurityStatus.success:
            guard let account = metadata.account, !account.isEmpty,
                  let value = try read(service: service, account: account)
            else {
                return nil
            }
            return UsageKeychainItem(account: account, value: value)
        case UsageSecurityStatus.itemNotFound:
            return nil
        default:
            throw UsageKeychainError.unexpectedExitCode(Int(metadata.status))
        }
    }

    public func write(service: String, account: String?, value: String) throws {
        guard let account, !account.isEmpty else {
            throw UsageKeychainError.missingExactAccount
        }
        let data = Data(value.utf8)
        let query = SecurityUsageKeychainQuery(
            service: service,
            account: account,
            returnAttributes: false,
            returnData: false
        )
        let updateStatus = items.update(query, value: data)
        switch updateStatus {
        case UsageSecurityStatus.success:
            return
        case UsageSecurityStatus.itemNotFound:
            let addStatus = items.add(service: service, account: account, value: data)
            guard addStatus == UsageSecurityStatus.success else {
                throw UsageKeychainError.unexpectedExitCode(Int(addStatus))
            }
        default:
            throw UsageKeychainError.unexpectedExitCode(Int(updateStatus))
        }
    }
}

/// Keychain access errors. Does not carry the secret value.
public enum UsageKeychainError: Error, Equatable, Sendable {
    case unexpectedExitCode(Int)
    case missingExactAccount
    case disabled
}

/// Production process runner backed by `Process`. Enforces a timeout so a
/// hung `security` invocation cannot wedge the monitor.
public final class ProcessUsageRunner: UsageProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> UsageProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "process timed out: \(executable)"]
            )
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return UsageProcessResult(exitCode: Int(process.terminationStatus), standardOutput: stdout, standardError: stderr)
    }
}

/// Usage keychain errors as a discrete error type so callers can classify
/// without parsing messages.
extension UsageKeychainError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unexpectedExitCode(let code):
            return "keychain operation failed with status \(code)"
        case .missingExactAccount:
            return "keychain write requires an exact account"
        case .disabled:
            return "keychain access is disabled"
        }
    }
}
