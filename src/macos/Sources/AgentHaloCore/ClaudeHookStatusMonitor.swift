import Foundation

public final class ClaudeHookStatusMonitor {
    private let statusURL: URL
    private var reducers: [String: ClaudeHookStatusReducer] = [:]
    private var offset: UInt64 = 0
    private var pending = ""
    private var lastModified: Date?
    private let fileManager: FileManager

    public init(
        statusURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("claude-code-status.jsonl"),
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL
        self.fileManager = fileManager
    }

    public func refresh(now: Date = Date()) -> Bool {
        let previous = offset
        let current = fileSize(statusURL)
        let mtime = modificationDate(statusURL)
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
                    reducers[sessionId] = ClaudeHookStatusReducer(threadId: sessionId, now: now)
                }
                reducers[sessionId]?.consume(jsonLine: trimmed, now: now)
            }

            for key in reducers.keys {
                reducers[key]?.applyWorkingVisibility(now: now)
            }
            return !lines.isEmpty
        } catch {
            AgentHaloLogger.log("Claude hook status refresh failed: \(error)")
            return false
        }
    }

    public func snapshots() -> [SessionSnapshot] {
        if reducers.isEmpty {
            return [ClaudeHookStatusReducer().snapshot]
        }
        return reducers.values.map(\.snapshot)
    }

    private static func sessionId(from line: String) -> String {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["sessionId"] else {
            return "claude-code"
        }
        let sessionId = String(describing: value)
        return sessionId.isEmpty ? "claude-code" : sessionId
    }

    private func fileSize(_ url: URL) -> UInt64 {
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private func modificationDate(_ url: URL) -> Date? {
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path) {
            return attrs[.modificationDate] as? Date
        }
        return nil
    }
}
