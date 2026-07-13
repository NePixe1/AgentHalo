import Foundation

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
    func writeAtomically(_ data: Data, to path: String, preservingModeOf existingPath: String?) throws
}

/// Injectable keychain access. Production shells out to `/usr/bin/security`;
/// checks use `FakeUsageKeychain`. Never logs the returned password.
public protocol UsageKeychainAccessing: Sendable {
    func read(service: String, account: String?) throws -> String?
    func write(service: String, account: String?, value: String) throws
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
            var ptr = buffer.baseAddress!
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

        close(fd)
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

/// Production keychain access via `/usr/bin/security`.
///
/// Reads invoke `find-generic-password`; writes invoke `add-generic-password -U`
/// with the same service/account. Exit code 44 means "not found" (returns nil);
/// other nonzero exits are classified errors. The returned password or `-w`
/// value is never logged.
public final class SecurityUsageKeychain: UsageKeychainAccessing {
    private let processRunner: UsageProcessRunning

    public init(processRunner: UsageProcessRunning) {
        self.processRunner = processRunner
    }

    public func read(service: String, account: String?) throws -> String? {
        var arguments = [
            "find-generic-password",
            "-s", service,
            "-w",
            "-g",
        ]
        if let account = account {
            arguments += ["-a", account]
        }
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            timeout: 10
        )
        switch result.exitCode {
        case 0:
            guard let password = String(data: result.standardOutput, encoding: .utf8) else {
                return nil
            }
            // `security` appends a trailing newline; trim it.
            return password.reversed().drop(while: { $0.isWhitespace }).reversed().map(String.init).joined()
        case 44:
            return nil
        default:
            throw UsageKeychainError.unexpectedExitCode(result.exitCode)
        }
    }

    public func write(service: String, account: String?, value: String) throws {
        var arguments = [
            "add-generic-password",
            "-U",
            "-s", service,
            "-w", value,
        ]
        if let account = account {
            arguments += ["-a", account]
        }
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            timeout: 10
        )
        if result.exitCode != 0 {
            throw UsageKeychainError.unexpectedExitCode(result.exitCode)
        }
    }
}

/// Keychain access errors. Does not carry the secret value.
public enum UsageKeychainError: Error, Equatable, Sendable {
    case unexpectedExitCode(Int)
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
            return "keychain command exited with code \(code)"
        }
    }
}
