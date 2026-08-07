import Foundation

/// Canonical paths under `~/.agent-halo` for layout version 2.
///
/// Production code must resolve runtime paths through this type (or inject an
/// instance built for a test home). Legacy properties exist only for migration
/// and scrub decisions — business readers/writers must not open them.
public struct AgentHaloPaths: Sendable, Equatable {
    public static let layoutVersion: Int = 2

    public let root: URL
    public let homeDirectory: URL

    public var layoutVersionFile: URL {
        root.appendingPathComponent(".layout-version")
    }

    public var binDirectory: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    public var stateDirectory: URL {
        root.appendingPathComponent("state", isDirectory: true)
    }

    public var logsDirectory: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    public var cacheDirectory: URL {
        root.appendingPathComponent("cache", isDirectory: true)
    }

    public var statusHook: URL {
        binDirectory.appendingPathComponent("status-hook")
    }

    public var statuslineProxy: URL {
        binDirectory.appendingPathComponent("statusline-proxy")
    }

    public var statuslineOriginalCommand: URL {
        stateDirectory.appendingPathComponent("statusline-original-command")
    }

    public var claudeStatusLog: URL {
        logsDirectory.appendingPathComponent("claude-status.jsonl")
    }

    public var grokStatusLog: URL {
        logsDirectory.appendingPathComponent("grok-status.jsonl")
    }

    public var piStatusLog: URL {
        logsDirectory.appendingPathComponent("pi-status.jsonl")
    }

    public var claudeContextsDirectory: URL {
        cacheDirectory.appendingPathComponent("claude-contexts", isDirectory: true)
    }

    public var usageSnapshots: URL {
        cacheDirectory.appendingPathComponent("usage-snapshots-v1.json")
    }

    // MARK: - Legacy (migration / scrub only)

    public var legacyStatusHook: URL {
        root.appendingPathComponent("claude-code-status-hook")
    }

    public var legacyStatuslineProxy: URL {
        root.appendingPathComponent("claude-code-statusline-proxy")
    }

    public var legacyStatuslineOriginalCommand: URL {
        root.appendingPathComponent("claude-code-statusline-original-command")
    }

    public var legacyClaudeStatusLog: URL {
        root.appendingPathComponent("claude-code-status.jsonl")
    }

    public var legacyGrokStatusLog: URL {
        root.appendingPathComponent("grok-build-status.jsonl")
    }

    public var legacyClaudeContextsDirectory: URL {
        root.appendingPathComponent("claude-code-contexts", isDirectory: true)
    }

    public var legacyClaudeContextFile: URL {
        root.appendingPathComponent("claude-code-context.json")
    }

    public var legacyUsageSnapshots: URL {
        root.appendingPathComponent("usage-snapshots-v1.json")
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.root = homeDirectory.appendingPathComponent(".agent-halo", isDirectory: true)
    }
}
