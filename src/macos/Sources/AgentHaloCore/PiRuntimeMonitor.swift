import Darwin
import Foundation

/// Latest Pi session file used to identify a Pi process that predates the
/// Agent Halo extension installation.
public struct PiRuntimeSessionEvidence: Equatable, Sendable {
    public var sessionId: String
    public var workingDirectory: String
    public var path: String
    public var lastModified: Date
    public var length: UInt64
    public var provider: String?
    public var model: String?
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var contextTokens: Int64
    public var contextWindowTokens: Int64

    public init(
        sessionId: String,
        workingDirectory: String,
        path: String,
        lastModified: Date,
        length: UInt64,
        provider: String? = nil,
        model: String? = nil,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        contextTokens: Int64 = -1,
        contextWindowTokens: Int64 = 0
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.path = path
        self.lastModified = lastModified
        self.length = length
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.contextTokens = contextTokens
        self.contextWindowTokens = contextWindowTokens
    }
}

public struct PiRuntimeProcess: Equatable, Sendable {
    public var processId: Int32
    public var parentProcessId: Int32
    public var name: String
    public var startedAt: Date?

    public init(
        processId: Int32,
        parentProcessId: Int32,
        name: String,
        startedAt: Date?
    ) {
        self.processId = processId
        self.parentProcessId = parentProcessId
        self.name = name
        self.startedAt = startedAt
    }
}

/// Presence fallback for Pi sessions that were already running before the
/// Agent Halo extension was installed. Extension records remain authoritative;
/// this monitor only supplies an idle/present snapshot when no hook event exists.
public final class PiRuntimeMonitor: @unchecked Sendable {
    private static let checkInterval: TimeInterval = 2
    private static let evidenceLifetime: TimeInterval = 3 * 24 * 60 * 60
    private static let futureTolerance: TimeInterval = 5 * 60
    private static let processStartTolerance: TimeInterval = 5
    private static let sessionTailBytes: UInt64 = 512 * 1024

    private let agentRoot: URL
    private let processReader: @Sendable () -> [PiRuntimeProcess]
    private var nextCheckAt = Date.distantPast
    private var running = false
    private var latestSession: PiRuntimeSessionEvidence?

    public init(
        agentRoot: URL = PiExtensionConfigurator.resolveAgentRoot(),
        processReader: @escaping @Sendable () -> [PiRuntimeProcess] = PiRuntimeMonitor.readProcesses
    ) {
        self.agentRoot = agentRoot
        self.processReader = processReader
    }

    public var isRunning: Bool {
        running
    }

    @discardableResult
    public func refresh(now: Date = Date()) -> Bool {
        guard now >= nextCheckAt else { return false }
        nextCheckAt = now.addingTimeInterval(Self.checkInterval)
        let before = fingerprint()
        latestSession = Self.readLatestSession(
            agentRoot: agentRoot,
            previous: latestSession,
            now: now
        )
        running = Self.isRunning(
            session: latestSession,
            now: now,
            processes: processReader()
        )
        return before != fingerprint()
    }

    public func snapshot() -> SessionSnapshot? {
        guard running, let session = latestSession else { return nil }
        let contextPercent: Double?
        if session.contextTokens >= 0, session.contextWindowTokens > 0 {
            contextPercent = min(
                100,
                max(0, Double(session.contextTokens) * 100 / Double(session.contextWindowTokens))
            )
        } else {
            contextPercent = nil
        }
        return SessionSnapshot(
            threadId: session.sessionId,
            projectName: Self.projectName(from: session.workingDirectory),
            workingDirectory: session.workingDirectory,
            state: .idle,
            action: "Ready",
            lastEventAt: session.lastModified,
            completedAt: nil,
            active: false,
            agent: .pi,
            modelName: session.model,
            inputTokens: session.inputTokens > 0 ? session.inputTokens : nil,
            outputTokens: session.outputTokens > 0 ? session.outputTokens : nil,
            contextUsedPercent: contextPercent
        )
    }

    public static func isRunning(
        session: PiRuntimeSessionEvidence?,
        now: Date,
        processes: [PiRuntimeProcess]
    ) -> Bool {
        guard let session,
              session.lastModified <= now.addingTimeInterval(futureTolerance),
              now.timeIntervalSince(session.lastModified) <= evidenceLifetime
        else {
            return false
        }

        let byId = Dictionary(
            processes.filter { $0.processId > 0 }.map { ($0.processId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for process in byId.values where isPiProcess(process.name) {
            let name = executableName(process.name)
            // Modern Pi exposes its process title as `pi`. Older Node-based
            // builds are accepted only when their parent is a terminal shell.
            if name == "node" {
                guard let parent = byId[process.parentProcessId],
                      isShellProcess(parent.name)
                else {
                    continue
                }
            }
            if process.startedAt == nil
                || process.startedAt! <= session.lastModified.addingTimeInterval(processStartTolerance) {
                return true
            }
        }
        return false
    }

    public static func readLatestSession(
        agentRoot: URL,
        previous: PiRuntimeSessionEvidence? = nil,
        now: Date = Date()
    ) -> PiRuntimeSessionEvidence? {
        let root = agentRoot.appendingPathComponent("sessions", isDirectory: true)
        let cutoff = now.addingTimeInterval(-evidenceLifetime)
        let candidates = FastFileMetadata
            .discoverJsonlFiles(root: root, cutoff: cutoff, skipSubagents: false)
            .sorted { $0.modifiedAt > $1.modifiedAt }
        for candidate in candidates {
            guard let metadata = FastFileMetadata.read(candidate.url) else { continue }
            if let previous,
               previous.path == candidate.url.path,
               previous.lastModified == metadata.modifiedAt,
               previous.length == metadata.size {
                return previous
            }
            if let evidence = readSession(
                candidate.url,
                metadata: metadata,
                agentRoot: agentRoot
            ) {
                return evidence
            }
        }
        return nil
    }

    public static func readProcesses() -> [PiRuntimeProcess] {
        let requested = proc_listallpids(nil, 0)
        guard requested > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(requested) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        var result: [PiRuntimeProcess] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
            }
            guard read == size else { continue }
            let name = cStringTuple(info.pbi_name).isEmpty
                ? cStringTuple(info.pbi_comm)
                : cStringTuple(info.pbi_name)
            let startedAt: Date?
            if info.pbi_start_tvsec > 0 {
                startedAt = Date(
                    timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                        + TimeInterval(info.pbi_start_tvusec) / 1_000_000
                )
            } else {
                startedAt = nil
            }
            result.append(PiRuntimeProcess(
                processId: Int32(info.pbi_pid),
                parentProcessId: Int32(info.pbi_ppid),
                name: name,
                startedAt: startedAt
            ))
        }
        return result
    }

    // MARK: - Session parsing

    private static func readSession(
        _ url: URL,
        metadata: FastFileMetadata,
        agentRoot: URL
    ) -> PiRuntimeSessionEvidence? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let head = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard let firstLine = String(data: head, encoding: .utf8)?
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first,
                let header = jsonObject(String(firstLine)),
                string(header["type"])?.lowercased() == "session"
            else {
                return nil
            }

            let tailOffset = metadata.size > sessionTailBytes
                ? metadata.size - sessionTailBytes
                : 0
            try handle.seek(toOffset: tailOffset)
            let tail = try handle.readToEnd() ?? Data()
            guard let tailText = String(data: tail, encoding: .utf8) else { return nil }
            var lines = tailText.split(separator: "\n", omittingEmptySubsequences: true)
            if tailOffset > 0, !lines.isEmpty {
                lines.removeFirst() // discard a partial line at the tail boundary
            }

            var changedProvider: String?
            var changedModel: String?
            var assistant: [String: Any]?
            for line in lines.reversed() {
                let text = String(line)
                if changedModel == nil, text.contains(#""type":"model_change""#),
                   let entry = jsonObject(text) {
                    changedProvider = string(entry["provider"])
                    changedModel = string(entry["modelId"])
                }
                if assistant == nil, text.contains(#""role":"assistant""#),
                   let entry = jsonObject(text),
                   let message = entry["message"] as? [String: Any],
                   string(message["role"])?.lowercased() == "assistant" {
                    assistant = message
                }
                if assistant != nil, changedModel != nil { break }
            }

            let usage = assistant?["usage"] as? [String: Any]
            let input = int64(usage?["input"]) ?? 0
            let output = int64(usage?["output"]) ?? 0
            let cacheRead = int64(usage?["cacheRead"]) ?? 0
            let cacheWrite = int64(usage?["cacheWrite"]) ?? 0
            let total = int64(usage?["totalTokens"])
                ?? (usage == nil ? -1 : input + output + cacheRead + cacheWrite)
            let provider = changedProvider ?? string(assistant?["provider"])
            let model = changedModel ?? string(assistant?["model"])
            let contextWindow = total >= 0
                ? readContextWindow(agentRoot: agentRoot, provider: provider, model: model)
                : 0
            return PiRuntimeSessionEvidence(
                sessionId: string(header["id"])
                    ?? url.deletingPathExtension().lastPathComponent,
                workingDirectory: string(header["cwd"]) ?? "",
                path: url.path,
                lastModified: metadata.modifiedAt,
                length: metadata.size,
                provider: provider,
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                contextTokens: total,
                contextWindowTokens: contextWindow
            )
        } catch {
            return nil
        }
    }

    private static func readContextWindow(
        agentRoot: URL,
        provider: String?,
        model: String?
    ) -> Int64 {
        guard let model, !model.isEmpty else { return 0 }
        for name in ["models.json", "models-store.json"] {
            let url = agentRoot.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let node = try? JSONSerialization.jsonObject(with: data)
            else {
                continue
            }
            let value = findContextWindow(
                node,
                provider: provider,
                model: model,
                inheritedProvider: nil
            )
            if value > 0 { return value }
        }
        return 0
    }

    private static func findContextWindow(
        _ node: Any,
        provider: String?,
        model: String,
        inheritedProvider: String?
    ) -> Int64 {
        if let data = node as? [String: Any] {
            let currentProvider = string(data["provider"]) ?? inheritedProvider
            let identifier = string(data["id"])
                ?? string(data["model"])
                ?? string(data["modelId"])
            let providerMatches = provider == nil || currentProvider == nil
                || provider?.caseInsensitiveCompare(currentProvider!) == .orderedSame
            if identifier?.caseInsensitiveCompare(model) == .orderedSame, providerMatches {
                let value = int64(data["contextWindow"])
                    ?? int64(data["context_window"])
                    ?? 0
                if value > 0 { return value }
            }
            if let providers = data["providers"] as? [String: Any] {
                for (name, child) in providers {
                    let value = findContextWindow(
                        child,
                        provider: provider,
                        model: model,
                        inheritedProvider: name
                    )
                    if value > 0 { return value }
                }
            }
            for (key, child) in data where key != "providers" {
                let childProvider: String?
                if currentProvider == nil,
                   let dictionary = child as? [String: Any],
                   dictionary["models"] != nil {
                    childProvider = key
                } else {
                    childProvider = currentProvider
                }
                let value = findContextWindow(
                    child,
                    provider: provider,
                    model: model,
                    inheritedProvider: childProvider
                )
                if value > 0 { return value }
            }
        } else if let items = node as? [Any] {
            for child in items {
                let value = findContextWindow(
                    child,
                    provider: provider,
                    model: model,
                    inheritedProvider: inheritedProvider
                )
                if value > 0 { return value }
            }
        }
        return 0
    }

    // MARK: - Helpers

    private func fingerprint() -> String {
        guard let latestSession else { return running ? "1" : "0" }
        return [
            running ? "1" : "0",
            latestSession.sessionId,
            String(latestSession.lastModified.timeIntervalSince1970),
            String(latestSession.length),
            latestSession.model ?? "",
            String(latestSession.contextTokens),
        ].joined(separator: "|")
    }

    private static func isPiProcess(_ name: String) -> Bool {
        let value = executableName(name)
        return value == "pi" || value == "node"
    }

    private static func isShellProcess(_ name: String) -> Bool {
        ["zsh", "bash", "fish", "sh", "dash", "ksh", "nu", "tmux"]
            .contains(executableName(name))
    }

    private static func executableName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func projectName(from workingDirectory: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "Pi" }
        let leaf = (trimmed as NSString).lastPathComponent
        return leaf.isEmpty ? "Pi" : leaf
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String ?? String(describing: value)
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func cStringTuple<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
