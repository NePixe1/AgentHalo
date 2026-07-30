import Foundation

public final class GrokHookStatusMonitor {
    private let statusURL: URL
    private let sessionsRoot: URL
    private var reducers: [String: GrokHookStatusReducer] = [:]
    private var offset: UInt64 = 0
    private var pending = ""
    private var lastModified: Date?
    private let fileManager: FileManager
    private let turnEventsReader: GrokSessionTurnEventsReader

    public init(
        statusURL: URL = AgentHaloPaths().grokStatusLog,
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
        self.turnEventsReader = GrokSessionTurnEventsReader(fileManager: fileManager)
    }

    public func refresh(now: Date = Date()) -> Bool {
        let hooksChanged = refreshHooks(now: now)
        let turnChanged = applySessionTurnEvents(now: now)

        for key in reducers.keys {
            reducers[key]?.applyWorkingVisibility(now: now)
        }
        pruneStaleReducers(now: now)
        return hooksChanged || turnChanged
    }

    public func snapshots() -> [SessionSnapshot] {
        // Return empty when no hook data is available (file missing, empty, partial
        // line pending, or freshly truncated). Avoid phantom idle snapshots.
        if reducers.isEmpty {
            return []
        }
        return reducers.values.map(\.snapshot)
    }

    private func refreshHooks(now: Date) -> Bool {
        let previous = offset
        let meta = FastFileMetadata.read(statusURL)
        let current = meta?.size ?? 0
        let mtime = meta?.modifiedAt
        let mtimeChanged = mtime != nil && lastModified != nil && mtime != lastModified
        let truncated = current < previous || (mtimeChanged && current <= previous)

        if truncated {
            offset = 0
            pending = ""
            lastModified = mtime
            reducers.removeAll()
            turnEventsReader.reset()
            return false
        }

        guard current > previous, let handle = try? FileHandle(forReadingFrom: statusURL) else {
            return false
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: previous)
            let data = try handle.readToEnd() ?? Data()
            offset = current
            lastModified = mtime
            guard let chunk = String(data: data, encoding: .utf8) else {
                return false
            }

            let text = pending + chunk
            let complete = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !complete {
                pending = lines.popLast() ?? ""
            } else {
                pending = ""
            }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if trimmed.isEmpty {
                    continue
                }
                let sessionId = Self.sessionId(from: trimmed)
                if reducers[sessionId] == nil {
                    reducers[sessionId] = GrokHookStatusReducer(threadId: sessionId, now: now)
                }
                reducers[sessionId]?.consume(jsonLine: trimmed, now: now)
            }

            return !lines.isEmpty
        } catch {
            AgentHaloLogger.log("Grok hook status refresh failed: \(error)")
            return false
        }
    }

    /// Esc cancel does not emit Stop hooks. For still-active sessions, poll
    /// `events.jsonl` and map cancelled/failed `turn_ended` onto the fault ring.
    private func applySessionTurnEvents(now: Date) -> Bool {
        var changed = false
        for (sessionId, reducer) in reducers {
            let snapshot = reducer.snapshot
            let needsWatch = snapshot.active
                || snapshot.state == .thinking
                || snapshot.state == .working
                || snapshot.state == .attention
            guard needsWatch else {
                continue
            }
            guard let eventsURL = eventsURL(for: snapshot) else {
                continue
            }
            guard let turnEnd = turnEventsReader.poll(eventsURL: eventsURL) else {
                continue
            }
            switch turnEnd.outcome {
            case .cancelled, .failed:
                // A newer hook event means the session already moved on (e.g.
                // UserPromptSubmit after a prior Esc cancel). Skip stale ends.
                if turnEnd.endedAt.addingTimeInterval(0.25) < snapshot.lastEventAt {
                    continue
                }
                let before = reducers[sessionId]?.snapshot
                if turnEnd.outcome == .cancelled {
                    reducers[sessionId]?.applyTurnCancelled(at: turnEnd.endedAt)
                } else {
                    reducers[sessionId]?.applyTurnFailed(at: turnEnd.endedAt)
                }
                if reducers[sessionId]?.snapshot != before {
                    changed = true
                }
            case .completed, .other:
                break
            }
        }
        return changed
    }

    private func eventsURL(for snapshot: SessionSnapshot) -> URL? {
        let cwd = snapshot.workingDirectory.isEmpty ? nil : snapshot.workingDirectory
        guard let directory = resolveSessionDirectory(
            sessionId: snapshot.threadId,
            cwd: cwd
        ) else {
            return nil
        }
        return directory.appendingPathComponent("events.jsonl")
    }

    private func resolveSessionDirectory(sessionId: String, cwd: String?) -> URL? {
        if let cwd, !cwd.isEmpty {
            let encoded = GrokSessionContextReader.encodeWorkspaceDirectory(cwd)
            let candidate = sessionsRoot
                .appendingPathComponent(encoded, isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            if isSessionDirectory(candidate) {
                return candidate
            }
        }

        guard fileManager.fileExists(atPath: sessionsRoot.path),
              let workspaces = try? fileManager.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }
        for workspace in workspaces {
            let candidate = workspace.appendingPathComponent(sessionId, isDirectory: true)
            if isSessionDirectory(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isSessionDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        for name in ["events.jsonl", "signals.json", "updates.jsonl", "summary.json", "chat_history.jsonl"] {
            if fileManager.fileExists(atPath: url.appendingPathComponent(name).path) {
                return true
            }
        }
        return false
    }

    private static func sessionId(from line: String) -> String {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["sessionId"] else {
            return "grok"
        }
        let sessionId = String(describing: value)
        return sessionId.isEmpty ? "grok" : sessionId
    }

    private func pruneStaleReducers(now: Date) {
        let activeStaleThreshold = now.addingTimeInterval(-600)
        let inactiveStaleThreshold = now.addingTimeInterval(-300)
        reducers = reducers.filter { _, reducer in
            let t = reducer.snapshot.lastEventAt
            if reducer.snapshot.active {
                return t >= activeStaleThreshold
            }
            return t >= inactiveStaleThreshold
        }
    }
}
