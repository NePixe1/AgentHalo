import Foundation

public final class CodexSessionMonitor {
    private let sessionsRoot: URL
    private var reducers: [URL: SessionReducer] = [:]
    private var offsets: [URL: UInt64] = [:]
    private var pending: [URL: String] = [:]
    private var lastModified: [URL: Date] = [:]
    private var lastDiscoveryAt = Date.distantPast
    private let fileManager: FileManager

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
    }

    public func refresh(now: Date = Date()) -> Bool {
        var changed = false
        if now.timeIntervalSince(lastDiscoveryAt) >= 2 {
            changed = discover(now: now) || changed
        }
        for url in Array(reducers.keys) {
            changed = readNewLines(from: url, now: now) || changed
            reducers[url]?.applyWorkingVisibility(now: now)
        }
        return changed
    }

    public func snapshots() -> [SessionSnapshot] {
        reducers.values.map(\.snapshot)
    }

    private func discover(now: Date) -> Bool {
        lastDiscoveryAt = now
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= now.addingTimeInterval(-172_800) else {
                continue
            }
            files.append((url, modifiedAt))
        }

        let recent = Set(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(16).map(\.url))
        var changed = false
        for url in recent where reducers[url] == nil {
            reducers[url] = SessionReducer(filePath: url.path(percentEncoded: false), liveTracking: false)
            readInitialTail(from: url)
            let meta = FastFileMetadata.read(url)
            offsets[url] = meta?.size ?? 0
            lastModified[url] = meta?.modifiedAt
            reducers[url]?.setLiveTracking(true)
            changed = true
        }
        for url in reducers.keys where !recent.contains(url) {
            reducers.removeValue(forKey: url)
            offsets.removeValue(forKey: url)
            pending.removeValue(forKey: url)
            lastModified.removeValue(forKey: url)
            changed = true
        }
        return changed
    }

    private func readInitialTail(from url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer {
            try? handle.close()
        }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 393_216 ? size - 393_216 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else {
            return
        }
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }
        let complete = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !complete {
            let trailing = lines.popLast() ?? ""
            if !trailing.isEmpty {
                pending[url] = trailing
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !trimmed.isEmpty {
                reducers[url]?.consume(jsonLine: trimmed)
            }
        }
    }

    private func readNewLines(from url: URL, now: Date) -> Bool {
        let previous = offsets[url] ?? 0
        let meta = FastFileMetadata.read(url)
        let current = meta?.size ?? 0
        let mtime = meta?.modifiedAt
        let priorMtime = lastModified[url]
        let mtimeChanged = mtime != nil && priorMtime != nil && mtime != priorMtime
        let truncated = current < previous || (mtimeChanged && current <= previous)
        if truncated {
            offsets[url] = 0
            pending[url] = nil
            lastModified[url] = mtime
            reducers[url] = SessionReducer(filePath: url.path(percentEncoded: false), liveTracking: true)
            return false
        }
        guard current > previous, let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }
        do {
            try handle.seek(toOffset: previous)
            let data = try handle.readToEnd() ?? Data()
            offsets[url] = current
            lastModified[url] = mtime
            guard let chunk = String(data: data, encoding: .utf8) else {
                return false
            }
            let text = (pending[url] ?? "") + chunk
            let complete = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !complete {
                pending[url] = lines.popLast() ?? ""
            } else {
                pending[url] = nil
            }
            for line in lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !trimmed.isEmpty {
                    reducers[url]?.consume(jsonLine: trimmed, now: now)
                }
            }
            return !lines.isEmpty
        } catch {
            AgentHaloLogger.log("Session refresh failed: \(error)")
            return false
        }
    }
}
