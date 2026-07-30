import Foundation

/// Atomic install helpers for staged hook / statusline binaries under
/// ``~/.agent-halo/bin``.
///
/// Upgrade sequence (prevent exit 127):
/// 1. Atomically stage the **preferred** binary under ``bin/`` (never delete-first).
/// 2. Configurators rewrite Claude/Grok settings so every Agent Halo command
///    points at that preferred path.
/// 3. Only then may leftover root-level legacy names be removed if nothing
///    references them.
public enum AgentHaloBinaryStaging {
    /// Copy `source` onto `destination` via a same-directory temp file, then
    /// replace. The destination path stays executable for concurrent hook runs
    /// when it already existed.
    public static func stageExecutable(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temp = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".staging-\(destination.lastPathComponent)-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temp) }

        if fileManager.fileExists(atPath: temp.path) {
            try fileManager.removeItem(at: temp)
        }
        try fileManager.copyItem(at: source, to: temp)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: temp.path
        )

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
    }

    /// Stage only the preferred ``bin/status-hook`` path.
    public static func stageStatusHook(
        from bundled: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let paths = AgentHaloPaths(homeDirectory: homeDirectory)
        try stageExecutable(from: bundled, to: paths.statusHook, fileManager: fileManager)
    }

    /// Stage only the preferred ``bin/statusline-proxy`` path.
    public static func stageStatuslineProxy(
        from bundled: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let paths = AgentHaloPaths(homeDirectory: homeDirectory)
        try stageExecutable(from: bundled, to: paths.statuslineProxy, fileManager: fileManager)
    }

    /// Backward-compatible name used by bootstrap / older call sites.
    public static func stageStatusHookEverywhere(
        from bundled: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try stageStatusHook(from: bundled, homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public static func stageStatuslineProxyEverywhere(
        from bundled: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try stageStatuslineProxy(from: bundled, homeDirectory: homeDirectory, fileManager: fileManager)
    }

    /// First path token of a hook command (`"/path/bin args"` → `"/path/bin"`).
    public static func commandExecutablePath(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""),
           let end = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        guard let space = trimmed.firstIndex(of: " ") else {
            return trimmed
        }
        return String(trimmed[..<space])
    }

    public static func commandPointsToLiveExecutable(
        _ command: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let command, !command.isEmpty else { return false }
        let path = commandExecutablePath(command)
        guard !path.isEmpty else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }

    public static func commandReferencesPath(_ command: String?, _ path: String) -> Bool {
        guard let command else { return false }
        let exe = commandExecutablePath(command)
        return exe == path || command == path || command.hasPrefix(path + " ") || command.contains(path)
    }

    /// After settings have been rewritten to preferred paths, drop root-level
    /// legacy binaries that nothing still references.
    public static func scrubUnreferencedLegacyBinaries(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) {
        let paths = AgentHaloPaths(homeDirectory: homeDirectory)
        let referenced = referencedExecutablePaths(homeDirectory: homeDirectory, fileManager: fileManager)

        for legacy in [paths.legacyStatusHook, paths.legacyStatuslineProxy] {
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            if referenced.contains(legacy.path) {
                continue
            }
            do {
                try fileManager.removeItem(at: legacy)
                AgentHaloLogger.log("AgentHaloBinaryStaging: removed unreferenced \(legacy.path)")
            } catch {
                AgentHaloLogger.log(
                    "AgentHaloBinaryStaging: failed to remove \(legacy.path): \(error)"
                )
            }
        }

        // Emergency Grok-local binary from the 127 incident.
        let grokOrphan = homeDirectory
            .appendingPathComponent(".grok/hooks/agent-halo-status-hook")
        if fileManager.fileExists(atPath: grokOrphan.path),
           !referenced.contains(grokOrphan.path) {
            try? fileManager.removeItem(at: grokOrphan)
        }
    }

    private static func referencedExecutablePaths(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> Set<String> {
        var refs = Set<String>()
        let candidates = [
            homeDirectory.appendingPathComponent(".claude/settings.json"),
            homeDirectory.appendingPathComponent(".grok/hooks/agent-halo-status.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            // Cheap scan: collect absolute path-like tokens that look like our binaries.
            for name in [
                "claude-code-status-hook",
                "claude-code-statusline-proxy",
                "status-hook",
                "statusline-proxy",
                "agent-halo-status-hook",
            ] {
                if text.contains(name) {
                    // If the file mentions the legacy basename, treat legacy path as referenced.
                    let paths = AgentHaloPaths(homeDirectory: homeDirectory)
                    switch name {
                    case "claude-code-status-hook":
                        refs.insert(paths.legacyStatusHook.path)
                    case "claude-code-statusline-proxy":
                        refs.insert(paths.legacyStatuslineProxy.path)
                    case "status-hook":
                        refs.insert(paths.statusHook.path)
                    case "statusline-proxy":
                        refs.insert(paths.statuslineProxy.path)
                    case "agent-halo-status-hook":
                        refs.insert(
                            homeDirectory
                                .appendingPathComponent(".grok/hooks/agent-halo-status-hook").path
                        )
                    default:
                        break
                    }
                }
            }
        }
        return refs
    }
}
