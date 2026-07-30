import Foundation

/// Writes (or updates) Claude Code hook configuration on first launch so the user
/// never has to manually edit ``~/.claude/settings.json``.
///
/// On every launch:
/// 1. Atomically stage preferred ``bin/status-hook``.
/// 2. Rewrite any Agent Halo hook still on a legacy path to that preferred path.
public enum ClaudeHookConfigurator {

    // MARK: - Public API

    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let paths = AgentHaloPaths(homeDirectory: home)
        let destBinary = paths.statusHook
        let claudeSettings = home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let fileManager = FileManager.default

        guard let bundledBinary,
              fileManager.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("ClaudeHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        do {
            try AgentHaloBinaryStaging.stageStatusHook(
                from: bundledBinary,
                homeDirectory: home,
                fileManager: fileManager
            )
            AgentHaloLogger.log("ClaudeHookConfigurator: staged \(destBinary.path)")
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let hookCommand = destBinary.path

        var config: [String: Any]
        if let data = try? Data(contentsOf: claudeSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        } else {
            config = [:]
        }

        var hooks = (config["hooks"] as? [String: Any]) ?? [:]
        var changed = false

        for spec in hookSpecs {
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []

            // Preferred path only — legacy names must be rewritten on launch.
            let alreadyOnPreferred = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                let hasHook = entryHooks.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    let exe = AgentHaloBinaryStaging.commandExecutablePath(command)
                    guard exe == destBinary.path else { return false }
                    return AgentHaloBinaryStaging.commandPointsToLiveExecutable(
                        command,
                        fileManager: fileManager
                    )
                }
                guard hasHook else { return false }
                if spec.matcher != nil, entry["matcher"] == nil {
                    return false
                }
                return true
            }
            if alreadyOnPreferred { continue }

            // Drop any Agent Halo entry (legacy or wrong matcher), then append preferred.
            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    isAgentHaloHookCommand(hook["command"] as? String, paths: paths, home: home)
                }
            }

            var newEntry: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": "\(hookCommand) \(spec.event)"]
                ]
            ]
            if let matcher = spec.matcher {
                newEntry["matcher"] = matcher
            }
            entries.append(newEntry)
            hooks[spec.event] = entries
            changed = true
        }

        guard changed || settingsJSONNeedsPrettyPrint(at: claudeSettings) else {
            AgentHaloLogger.log("ClaudeHookConfigurator: hooks already configured — nothing to do")
            return
        }

        config["hooks"] = hooks

        do {
            try fileManager.createDirectory(
                at: claudeSettings.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: claudeSettings, options: [.atomic])
            AgentHaloLogger.log("ClaudeHookConfigurator: wrote \(claudeSettings.path)")
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to write \(claudeSettings.path): \(error)")
        }
    }

    // MARK: - Private helpers

    private static func settingsJSONNeedsPrettyPrint(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if text.contains("\n") || text.contains("\r") {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isAgentHaloHookCommand(
        _ command: String?,
        paths: AgentHaloPaths,
        home: URL
    ) -> Bool {
        guard let command else { return false }
        // Detect both preferred and any legacy Agent Halo paths so we can rewrite them.
        let roots = [
            paths.statusHook.path,
            paths.legacyStatusHook.path,
        ]
        return GrokHookConfigurator.isAgentHaloHookCommand(command, acceptedRoots: roots)
    }

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
        HookSpec(event: "PostToolBatch", matcher: nil),
        HookSpec(event: "Notification", matcher: nil),
        HookSpec(event: "PermissionRequest", matcher: nil),
        HookSpec(event: "PermissionDenied", matcher: nil),
        HookSpec(event: "Stop", matcher: nil),
        HookSpec(event: "StopFailure", matcher: nil),
        HookSpec(event: "SessionEnd", matcher: nil),
        HookSpec(event: "PreCompact", matcher: ""),
        HookSpec(event: "PostCompact", matcher: ""),
    ]
}
