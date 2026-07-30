import Foundation

/// Writes (or updates) Grok Build hook configuration on first launch so the user
/// never has to manually edit ``~/.grok/hooks/``.
///
/// On every launch the preferred command is ``~/.agent-halo/bin/status-hook``.
/// Any Agent Halo entry still pointing at a legacy path
/// (``claude-code-status-hook``, Grok-local orphan, etc.) is rewritten to that
/// preferred path. Config JSON stays in ``~/.grok/hooks/`` (discovery only).
public enum GrokHookConfigurator {

    // MARK: - Public API

    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let paths = AgentHaloPaths(homeDirectory: home)
        let hooksDir = home.appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")
        let fileManager = FileManager.default

        guard let bundledBinary,
              fileManager.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("GrokHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        // 1) Preferred binary must exist before settings point at it.
        do {
            try AgentHaloBinaryStaging.stageStatusHook(
                from: bundledBinary,
                homeDirectory: home,
                fileManager: fileManager
            )
            AgentHaloLogger.log("GrokHookConfigurator: staged \(paths.statusHook.path)")
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let preferredCommand = paths.statusHook.path

        // 2) Already on preferred path for every event → done.
        if isOnPreferredPath(at: hooksFile, preferredPath: preferredCommand, fileManager: fileManager) {
            AgentHaloLogger.log("GrokHookConfigurator: hooks already on preferred path — nothing to do")
            return
        }

        // 3) Rewrite entire Agent Halo Grok config to preferred path.
        var hooks: [String: Any] = [:]
        for spec in hookSpecs {
            var entry: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": preferredCommand]
                ]
            ]
            if let matcher = spec.matcher {
                entry["matcher"] = matcher
            }
            hooks[spec.event] = [entry]
        }
        let config: [String: Any] = ["hooks": hooks]

        do {
            try fileManager.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: hooksFile, options: [.atomic])
            AgentHaloLogger.log("GrokHookConfigurator: rewrote \(hooksFile.path) → \(preferredCommand)")
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to write \(hooksFile.path): \(error)")
        }
    }

    // MARK: - Preferred-path check

    /// True when every required event's Agent Halo command is exactly the
    /// preferred ``bin/status-hook`` path (and that binary is live).
    /// Legacy paths are **not** accepted — they must be rewritten on launch.
    public static func isOnPreferredPath(
        at url: URL,
        preferredPath: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: preferredPath) else {
            return false
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for spec in hookSpecs {
            guard let entries = hooks[spec.event] as? [[String: Any]] else {
                return false
            }
            let ok = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                let hasPreferred = entryHooks.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    // Exact preferred path (optional trailing event arg from old Claude-style).
                    let exe = AgentHaloBinaryStaging.commandExecutablePath(command)
                    return exe == preferredPath
                }
                guard hasPreferred else { return false }
                if let matcher = spec.matcher {
                    guard let existing = entry["matcher"] as? String, existing == matcher else {
                        return false
                    }
                }
                return true
            }
            if !ok { return false }
        }
        return true
    }

    /// - Note: Kept for tests / callers that still use the old name.
    public static func isHealthyConfiguration(
        at url: URL,
        paths: AgentHaloPaths,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        isOnPreferredPath(at: url, preferredPath: paths.statusHook.path, fileManager: fileManager)
    }

    public static func acceptedCommandRoots(paths: AgentHaloPaths, homeDirectory: URL) -> [String] {
        // Preferred only. Legacy names remain detectable via fragment helpers
        // so configurators can identify Agent Halo entries to rewrite.
        [paths.statusHook.path]
    }

    public static func isAgentHaloHookCommand(_ command: String, acceptedRoots: [String]) -> Bool {
        let path = AgentHaloBinaryStaging.commandExecutablePath(command)
        if acceptedRoots.contains(where: { path == $0 || command.contains($0) }) {
            return true
        }
        return command.contains("/bin/status-hook")
            || command.contains("claude-code-status-hook")
            || command.contains("agent-halo-status-hook")
            || command.contains("status-hook")
    }

    // MARK: - Private

    private static func bundledHookBinary() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return nil
        }
        return URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("claude-code-status-hook")
    }

    private struct HookSpec {
        let event: String
        let matcher: String?
    }

    private static let hookSpecs: [HookSpec] = [
        HookSpec(event: "SessionStart", matcher: nil),
        HookSpec(event: "UserPromptSubmit", matcher: nil),
        HookSpec(event: "PreToolUse", matcher: ".*"),
        HookSpec(event: "PostToolUse", matcher: ".*"),
        HookSpec(event: "PostToolUseFailure", matcher: ".*"),
        HookSpec(event: "Notification", matcher: nil),
        HookSpec(event: "Stop", matcher: nil),
        HookSpec(event: "StopFailure", matcher: nil),
        HookSpec(event: "SessionEnd", matcher: nil),
        HookSpec(event: "PreCompact", matcher: ""),
        HookSpec(event: "PostCompact", matcher: ""),
    ]
}
