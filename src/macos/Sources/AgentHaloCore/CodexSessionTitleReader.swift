import Foundation

public struct CodexSessionTitleReader: Sendable {
    public var indexURL: URL
    private var cachedSize: UInt64?
    private var cachedModifiedAt: Date?
    private var cachedTitles: [String: String] = [:]

    public init(
        indexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("session_index.jsonl")
    ) {
        self.indexURL = indexURL
    }

    public mutating func read() -> [String: String] {
        guard let metadata = FastFileMetadata.read(indexURL) else {
            cachedSize = nil
            cachedModifiedAt = nil
            cachedTitles = [:]
            return cachedTitles
        }
        if cachedSize == metadata.size, cachedModifiedAt == metadata.modifiedAt {
            return cachedTitles
        }
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else {
            return cachedTitles
        }

        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["id"] as? String,
                  let rawTitle = record["thread_name"] as? String else {
                continue
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !title.isEmpty {
                titles[id] = title
            }
        }
        cachedSize = metadata.size
        cachedModifiedAt = metadata.modifiedAt
        cachedTitles = titles
        return titles
    }
}
