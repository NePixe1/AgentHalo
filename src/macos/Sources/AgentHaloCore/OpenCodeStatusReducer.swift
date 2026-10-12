import Foundation

public struct OpenCodeObservation: Equatable, Sendable {
    public var sessions: [SessionSnapshot]
    public var pluginPresent: Bool
    public var processPresent: Bool
    public var hostPid: Int32

    public static let empty = OpenCodeObservation(
        sessions: [],
        pluginPresent: false,
        processPresent: false,
        hostPid: 0
    )

    public init(sessions: [SessionSnapshot], pluginPresent: Bool, processPresent: Bool, hostPid: Int32) {
        self.sessions = sessions
        self.pluginPresent = pluginPresent
        self.processPresent = processPresent
        self.hostPid = hostPid
    }

    /// Newest plugin session, including idle, for standby session details.
    public var preferredSession: SessionSnapshot? {
        sessions.max { $0.lastEventAt < $1.lastEventAt }
    }
}

/// Reduces OpenCode plugin snapshots written under `~/.agent-halo/cache/opencode`.
public enum OpenCodeStatusReducer {
    public static let heartbeatStaleSeconds: TimeInterval = 15
    public static let maxSnapshotBytes = 1_048_576
    public static let maxFiles = 128
    private static let processName = "opencode"

    public static func cacheDirectory(homeDirectory: URL) -> URL {
        AgentHaloPaths(homeDirectory: homeDirectory)
            .cacheDirectory
            .appendingPathComponent("opencode", isDirectory: true)
    }

    public static func scan(
        homeDirectory: URL,
        processes: [LiveProcess],
        launched: Date,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> OpenCodeObservation {
        let root = cacheDirectory(homeDirectory: homeDirectory)
        let files = snapshotFiles(in: root, now: now, fileManager: fileManager)
        return reduce(
            files: files,
            processes: processes,
            launched: launched,
            now: now
        )
    }

    public static func reduce(
        files: [(modifiedAt: Date, body: String)],
        processes: [LiveProcess],
        launched: Date,
        now: Date
    ) -> OpenCodeObservation {
        let processPresent = processes.contains { LiveProcessProbe.isNamed($0, processName) }
        let byPid = LiveProcessProbe.indexed(processes)
        var sessions: [SessionSnapshot] = []
        var pids: [String: Int32] = [:]
        var pluginPresent = false
        var newestFilePid: Int32 = 0
        var newestFileAt = Date.distantPast

        for file in files {
            guard let data = file.body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  intValue(object["version"]) == 1
            else { continue }
            let pid = Int32(intValue(object["pid"]))
            guard let startedAt = dateValue(object["startedAt"]),
                  let stamped = dateValue(object["timestamp"]),
                  LiveProcessProbe.matchesStart(byPid[pid], expected: startedAt),
                  abs(now.timeIntervalSince(stamped)) <= heartbeatStaleSeconds
            else { continue }
            pluginPresent = true
            if stamped >= newestFileAt {
                newestFileAt = stamped
                newestFilePid = pid
            }
            for session in parseSessions(object, launched: launched) {
                if let existing = sessions.firstIndex(where: { $0.threadId == session.threadId }) {
                    if session.lastEventAt >= sessions[existing].lastEventAt {
                        sessions[existing] = session
                        pids[session.threadId] = pid
                    }
                } else {
                    sessions.append(session)
                    pids[session.threadId] = pid
                }
            }
        }

        let hostPid = preferredHostPid(sessions: sessions, pids: pids) ?? (pluginPresent ? newestFilePid : 0)
        return OpenCodeObservation(
            sessions: sessions,
            pluginPresent: pluginPresent,
            processPresent: processPresent,
            hostPid: hostPid
        )
    }

    /// Child completion never completes the root. Child attention stays visible.
    public static func parseSessions(_ object: [String: Any], launched: Date) -> [SessionSnapshot] {
        guard let rows = object["sessions"] as? [Any] else { return [] }
        var result: [SessionSnapshot] = []
        for row in rows {
            guard let record = row as? [String: Any] else { continue }
            let id = text(record["id"])
            guard !id.isEmpty else { continue }
            let stateName = text(record["state"])
            let child = !text(record["parentID"]).isEmpty
            if child && stateName != "attention" { continue }
            var session = mapSession(record, id: id, stateName: stateName)
            if session.state == .done, let completedAt = session.completedAt, completedAt < launched {
                session.state = .idle
                session.completedAt = nil
                session.active = false
                session.action = "Ready"
            }
            result.append(session)
        }
        return result
    }

    private static func mapSession(_ record: [String: Any], id: String, stateName: String) -> SessionSnapshot {
        let directory = text(record["directory"])
        var title = text(record["title"])
        if title.isEmpty {
            title = URL(fileURLWithPath: directory).lastPathComponent
        }
        let input = intValue(record["input"])
        let output = intValue(record["output"])
        let context = intValue(record["context"])
        let window = intValue(record["contextWindow"])
        let hasUsage = input > 0 || output > 0
        let (state, action, active) = mappedState(stateName, event: text(record["event"]))
        let percent: Double? = window > 0 ? min(100, Double(context) / Double(window) * 100) : nil
        return SessionSnapshot(
            threadId: id,
            projectName: title,
            workingDirectory: directory,
            state: state,
            action: action,
            lastEventAt: dateValue(record["updatedAt"]) ?? .distantPast,
            completedAt: state == .done ? dateValue(record["completedAt"]) : nil,
            active: active,
            agent: .opencode,
            modelName: text(record["model"]).nilIfEmpty,
            inputTokens: hasUsage ? input : nil,
            outputTokens: hasUsage ? output : nil,
            contextUsedPercent: percent,
            sessionTitle: title.nilIfEmpty
        )
    }

    private static func mappedState(_ name: String, event: String) -> (HaloState, String, Bool) {
        switch name {
        case "thinking":
            return (.thinking, "Thinking", true)
        case "working":
            let action = event == "context.compacting" ? "Compressing context" : "Using tools"
            return (.working, action, true)
        case "attention":
            return (.attention, "Awaiting permission or input", true)
        case "error":
            return (.error, L10n.shared["status.error"], false)
        case "done":
            return (.done, "Complete", false)
        default:
            return (.idle, "Ready", false)
        }
    }

    private static func preferredHostPid(sessions: [SessionSnapshot], pids: [String: Int32]) -> Int32? {
        let ranked = sessions.sorted { left, right in
            let leftPriority = SessionAggregator.priority(left.state)
            let rightPriority = SessionAggregator.priority(right.state)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return left.lastEventAt > right.lastEventAt
        }
        for session in ranked {
            if let pid = pids[session.threadId], pid > 0 { return pid }
        }
        return nil
    }

    private static func snapshotFiles(
        in root: URL,
        now: Date,
        fileManager: FileManager
    ) -> [(modifiedAt: Date, body: String)] {
        guard let names = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return []
        }
        let candidates = names.filter { $0.pathExtension == "json" }.compactMap { url -> (Date, URL)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            guard size > 0, size <= maxSnapshotBytes, now.timeIntervalSince(modified) <= heartbeatStaleSeconds else {
                return nil
            }
            return (modified, url)
        }
        .sorted { $0.0 > $1.0 }
        .prefix(maxFiles)
        return candidates.compactMap { modified, url in
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (modified, body)
        }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func intValue(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return max(0, number.int64Value)
        case let string as String:
            return Int64(string).map { max(0, $0) } ?? 0
        default:
            return 0
        }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        let raw = text(value)
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
