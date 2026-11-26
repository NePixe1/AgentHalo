import Darwin
import Foundation

/// Finds a running Antigravity `language_server` or `agy` process and returns
/// the CSRF token plus listening ports needed for the local Connect-RPC.
///
/// Prefers `~/.gemini/antigravity/daemon/*.json` (and `antigravity-cli/daemon`
/// for `agy`) when a `homeDirectory` is supplied (Antigravity 2.35+ passes the
/// bridge token via stdin instead of `--csrf_token` in argv), then falls back
/// to scanning `ps` + `lsof` for legacy processes.
public struct AntigravityLanguageServerDiscovery: Sendable {
    public struct Options: Sendable {
        /// Executable name to match (e.g. `language_server`, `agy`).
        public var processName: String
        /// Lowercased marker values matched against `--app_data_dir` / `--ide_name` /
        /// `--override_ide_name` (exact), falling back to a `/marker/` path substring.
        /// Empty means "match any instance".
        public var markers: [String]
        /// Flag whose value is the CSRF token (e.g. `--csrf_token`). Empty means none.
        public var csrfFlag: String
        /// Optional flag carrying an HTTP fallback port (e.g. `--extension_server_port`).
        public var portFlag: String?

        public init(processName: String, markers: [String], csrfFlag: String, portFlag: String?) {
            self.processName = processName
            self.markers = markers
            self.csrfFlag = csrfFlag
            self.portFlag = portFlag
        }
    }

    public struct Result: Sendable, Equatable {
        public var pid: Int32
        public var csrf: String
        public var ports: [Int]
        public var extensionPort: Int?

        public init(pid: Int32, csrf: String, ports: [Int], extensionPort: Int?) {
            self.pid = pid
            self.csrf = csrf
            self.ports = ports
            self.extensionPort = extensionPort
        }
    }

    private let homeDirectory: URL?
    private let files: any UsageFileAccessing
    private let daemonFileLister: (@Sendable (URL) -> [URL])?
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let processRunner: any UsageProcessRunning

    public init(
        homeDirectory: URL? = nil,
        files: any UsageFileAccessing = FilesystemUsageFiles(),
        daemonFileLister: (@Sendable (URL) -> [URL])? = nil,
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = AntigravityLanguageServerDiscovery.defaultProcessIsAlive,
        processRunner: any UsageProcessRunning = ProcessUsageRunner()
    ) {
        self.homeDirectory = homeDirectory
        self.files = files
        self.daemonFileLister = daemonFileLister
        self.isProcessAlive = isProcessAlive
        self.processRunner = processRunner
    }

    public func discover(_ options: Options) -> Result? {
        if let daemonResult = discoverFromDaemonFiles(options) {
            return daemonResult
        }

        guard let psOutput = try? processRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 5
        ), psOutput.exitCode == 0 else {
            return nil
        }
        let stdout = String(data: psOutput.standardOutput, encoding: .utf8) ?? ""

        let candidates = Self.rankedCandidates(psOutput: stdout, options: options)
        guard !candidates.isEmpty else { return nil }

        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.fileExists(atPath: $0) }

        for candidate in candidates {
            let csrf: String
            if options.csrfFlag.trimmingCharacters(in: .whitespaces).isEmpty {
                csrf = ""
            } else if let value = Self.extractFlag(command: candidate.command, flag: options.csrfFlag) {
                csrf = value
            } else {
                continue
            }

            let extensionPort = options.portFlag
                .flatMap { Self.extractFlag(command: candidate.command, flag: $0) }
                .flatMap { Int($0) }

            var ports: [Int] = []
            if let lsofPath, let result = try? processRunner.run(
                executable: lsofPath,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                timeout: 5
            ), result.exitCode == 0 {
                let lsofOutput = String(data: result.standardOutput, encoding: .utf8) ?? ""
                ports = Self.parseListeningPorts(lsofOutput)
            }

            if ports.isEmpty && extensionPort == nil {
                continue
            }

            return Result(pid: candidate.pid, csrf: csrf, ports: ports, extensionPort: extensionPort)
        }

        return nil
    }

    public static func defaultProcessIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func discoverFromDaemonFiles(_ options: Options) -> Result? {
        guard let homeDirectory,
              let daemonDirectory = Self.daemonDirectory(for: options.processName, homeDirectory: homeDirectory)
        else {
            return nil
        }
        let candidates = (daemonFileLister ?? Self.defaultDaemonFiles)(daemonDirectory)
            .filter { $0.pathExtension.lowercased() == "json" }
        let requiresCSRF = !options.csrfFlag.trimmingCharacters(in: .whitespaces).isEmpty

        for fileURL in candidates {
            guard let data = try? files.readDataIfPresent(at: fileURL.path),
                  let info = try? JSONDecoder().decode(DaemonHubInfo.self, from: data),
                  let pid = info.pid,
                  isProcessAlive(pid)
            else {
                continue
            }
            let csrf = (info.csrfToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if requiresCSRF && csrf.isEmpty {
                continue
            }
            let validHTTPS = info.httpsPort.flatMap { (1..<65_536).contains($0) ? $0 : nil }
            let validHTTP = info.httpPort.flatMap { (1..<65_536).contains($0) ? $0 : nil }
            let ports = validHTTPS.map { [$0] } ?? []
            let extensionPort: Int? = if let validHTTP, validHTTP != validHTTPS {
                validHTTP
            } else {
                nil
            }
            guard !ports.isEmpty || extensionPort != nil else {
                continue
            }
            return Result(pid: pid, csrf: csrf, ports: ports, extensionPort: extensionPort)
        }
        return nil
    }

    private static func daemonDirectory(for processName: String, homeDirectory: URL) -> URL? {
        switch processName.lowercased() {
        case "language_server":
            return homeDirectory.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        case "agy":
            return homeDirectory.appendingPathComponent(".gemini/antigravity-cli/daemon", isDirectory: true)
        default:
            return nil
        }
    }

    private static func defaultDaemonFiles(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { url in
                guard url.pathExtension.lowercased() == "json" else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile ?? true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    /// Parse `ps -ax -o pid=,command=` output into candidates matching the process + markers,
    /// sorted by marker rank (exact flag match before path-substring match).
    static func rankedCandidates(psOutput: String, options: Options) -> [(pid: Int32, command: String)] {
        let processNameLower = options.processName.lowercased()
        let markersLower = options.markers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let spaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let pidString = String(line[..<spaceIndex])
            let command = String(line[line.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidString),
                  commandMatchesProcess(command: command, processNameLower: processNameLower),
                  let rank = markerRank(command: command, markersLower: markersLower)
            else { continue }
            ranked.append((rank, pid, command))
        }

        return ranked
            .sorted { $0.rank < $1.rank }
            .map { (pid: $0.pid, command: $0.command) }
    }

    /// Extract the value of a CLI flag from a command string. Handles `--flag value` and `--flag=value`.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEq = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flagEq) {
                return String(part.dropFirst(flagEq.count))
            }
        }
        return nil
    }

    /// Marker match priority: exact `--ide_name` / `--override_ide_name` / `--app_data_dir`
    /// value (rank 0); else `/marker/` path substring (rank 1). No markers means match any
    /// instance (rank 0). Returns nil when nothing matches.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }

        let ideName = extractFlag(command: command, flag: "--ide_name")?.lowercased()
        let overrideIdeName = extractFlag(command: command, flag: "--override_ide_name")?.lowercased()
        let appData = extractFlag(command: command, flag: "--app_data_dir")?.lowercased()
        if ideName != nil || overrideIdeName != nil || appData != nil {
            let matches = markersLower.contains { marker in
                ideName == marker || overrideIdeName == marker || appData == marker
            }
            return matches ? 0 : nil
        }

        let commandLower = command.lowercased()
        let matches = markersLower.contains { commandLower.contains("/\($0)/") }
        return matches ? 1 : nil
    }

    /// First argv token, honoring a quoted executable path.
    static func argv0(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) {
            return String(rest[..<end])
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func commandMatchesProcess(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }

        let exeName = (argv0(command: command) as NSString).lastPathComponent.lowercased()
        if exeName == processNameLower { return true }

        let commandLower = command.lowercased()
        if processNameLower.count >= 8 {
            return exeName.hasPrefix("\(processNameLower)_") || commandLower.contains(processNameLower)
        }
        return commandLower.hasSuffix("/\(processNameLower)")
            || commandLower.contains("/\(processNameLower) ")
            || commandLower.contains("/\(processNameLower)\t")
    }

    /// Parse listening port numbers from `lsof -nP -iTCP -sTCP:LISTEN` output (deduped, ascending).
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }
}

private struct DaemonHubInfo: Decodable {
    let pid: Int32?
    let httpsPort: Int?
    let httpPort: Int?
    let csrfToken: String?
}
