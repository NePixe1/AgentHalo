import Foundation

public final class AntigravityHookStatusMonitor {
    private let statusURL: URL
    private var reducers: [String: AntigravityHookStatusReducer] = [:]
    private var offset: UInt64 = 0
    private var pending = ""
    private var lastModified: Date?
    private let fileManager: FileManager

    public init(
        statusURL: URL = AgentHaloPaths().antigravityStatusLog,
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL
        self.fileManager = fileManager
    }

    public func refresh(now: Date = Date()) -> Bool {
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
            return false
        }

        guard current > previous, let handle = try? FileHandle(forReadingFrom: statusURL) else {
            for key in reducers.keys {
                reducers[key]?.applyWorkingVisibility(now: now)
            }
            pruneStaleReducers(now: now)
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
                guard let sessionId = Self.sessionId(from: trimmed) else {
                    continue
                }
                if reducers[sessionId] == nil {
                    reducers[sessionId] = AntigravityHookStatusReducer(threadId: sessionId, now: now)
                }
                reducers[sessionId]?.consume(jsonLine: trimmed, now: now)
            }

            for key in reducers.keys {
                reducers[key]?.applyWorkingVisibility(now: now)
            }
            pruneStaleReducers(now: now)
            return !lines.isEmpty
        } catch {
            AgentHaloLogger.log("Antigravity hook status refresh failed: \(error)")
            return false
        }
    }

    public func snapshots() -> [SessionSnapshot] {
        if reducers.isEmpty {
            return []
        }
        return reducers.values.map(\.snapshot)
    }

    private static func sessionId(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let value = root["sessionId"] else {
            return "antigravity"
        }
        let sessionId = String(describing: value)
        return sessionId.isEmpty ? "antigravity" : sessionId
    }

    private func pruneStaleReducers(now: Date) {
        reducers = reducers.filter { _, reducer in
            Self.shouldRetainSnapshot(reducer.snapshot, now: now)
        }
    }

    /// Whether an Antigravity hook snapshot should survive age-based pruning.
    ///
    /// Windows match `ClaudeHookStatusMonitor.shouldRetainSnapshot`:
    /// active 600s, idle 300s. `.attention` is retained indefinitely (unused
    /// by the AG reducer, which never paints attention).
    public static func shouldRetainSnapshot(_ snapshot: SessionSnapshot, now: Date) -> Bool {
        ClaudeHookStatusMonitor.shouldRetainSnapshot(snapshot, now: now)
    }
}
