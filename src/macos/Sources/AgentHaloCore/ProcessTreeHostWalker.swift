import Foundation

public struct HostProcessRecord: Equatable, Sendable {
    public var processId: Int32
    public var parentProcessId: Int32
    public var name: String
    public var isRegularApp: Bool

    public init(
        processId: Int32,
        parentProcessId: Int32,
        name: String,
        isRegularApp: Bool
    ) {
        self.processId = processId
        self.parentProcessId = parentProcessId
        self.name = name
        self.isRegularApp = isRegularApp
    }
}

public enum ProcessTreeHostWalker {
    public static let maxDepth = 32

    private static let skipNames: Set<String> = [
        "claude", "grok", "pi", "agy", "node", "bun",
        "conhost", "openconsole", "wslrelay", "wslhost",
        "language_server", "agenthalo", "agenthalomac"
    ]

    public static func shouldSkipName(_ name: String) -> Bool {
        let normalized = normalize(name)
        if skipNames.contains(normalized) {
            return true
        }
        return normalized.hasSuffix(" helper")
    }

    public static func resolveHost(
        startingProcessId: Int32,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32
    ) -> Int32? {
        var current = startingProcessId
        var visited = Set<Int32>()
        var depth = 0
        while current > 1, depth < maxDepth {
            if visited.contains(current) {
                return nil
            }
            visited.insert(current)
            guard let record = processes[current] else {
                return nil
            }
            let skipSelf = record.processId == selfProcessId
            if !skipSelf && !shouldSkipName(record.name) && record.isRegularApp {
                return record.processId
            }
            current = record.parentProcessId
            depth += 1
        }
        return nil
    }

    private static func normalize(_ name: String) -> String {
        var value = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        if value.hasSuffix(".exe") {
            value = String(value.dropLast(4))
        }
        return value
    }
}
