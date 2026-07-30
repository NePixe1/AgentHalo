import Foundation

/// Writes (or updates) Claude Code hook configuration on first launch so the user
/// never has to manually edit ``~/.claude/settings.json``.
///
/// Design:
/// - Copies the bundled ``ClaudeCodeStatusHook`` binary to
///   ``~/.agent-halo/bin/status-hook`` — a stable path that survives app-bundle moves.
/// - Merges hook entries into ``~/.claude/settings.json`` at the **user** level so every
///   Claude Code project inherits the hooks automatically.
/// - Settings that still point at the legacy root binary are rewritten to the new path
///   (no short-circuit on legacy-only configuration).
/// - After a successful settings write, removes the root-level legacy binary.
/// - Catches all errors — a broken config write must never prevent the app from
///   starting.
public enum ClaudeHookConfigurator {

    // MARK: - Public API

    /// Ensure the hook binary and user-level ``~/.claude/settings.json`` are configured.
    ///
    /// Safe to call on every launch; the implementation short-circuits when
    /// everything is already in place at the **new** path.
    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    /// Ensure hook configuration for a specific home directory.
    ///
    /// Exposed for the self-check target so configuration behavior can be tested
    /// without touching the user's real Claude Code settings.
    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let paths = AgentHaloPaths(homeDirectory: home)
        let destBinary = paths.statusHook
        let claudeSettings = home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let fileManager = FileManager.default

        // -- 1. Stage the hook binary -------------------------------------------
        guard let bundledBinary,
              fileManager.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("ClaudeHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        do {
            try fileManager.createDirectory(
                at: paths.binDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Always overwrite so the binary stays up-to-date across app upgrades.
            if fileManager.fileExists(atPath: destBinary.path) {
                try fileManager.removeItem(at: destBinary)
            }
            try fileManager.copyItem(at: bundledBinary, to: destBinary)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destBinary.path
            )
            AgentHaloLogger.log("ClaudeHookConfigurator: staged \(destBinary.path)")
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let hookCommand = destBinary.path

        // -- 2. Read existing ~/.claude/settings.json --------------------------
        var config: [String: Any]
        if let data = try? Data(contentsOf: claudeSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        } else {
            config = [:]
        }

        var hooks = (config["hooks"] as? [String: Any]) ?? [:]

        // -- 3. Merge our lifecycle events --------------------------------------
        var changed = false
        for spec in hookSpecs {
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []

            // Idempotency: only treat the **new** staged path as configured.
            // Legacy `claude-code-status-hook` paths must be rewritten.
            let alreadyConfigured = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                let hasHook = entryHooks.contains { hook in
                    commandReferencesPath(hook["command"] as? String, destBinary.path)
                }
                guard hasHook else { return false }
                if spec.matcher != nil, entry["matcher"] == nil {
                    return false
                }
                return true
            }
            if alreadyConfigured { continue }

            // Remove stale Agent Halo entries (legacy path or missing matcher).
            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    isAgentHaloHookCommand(hook["command"] as? String, paths: paths)
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
            removeLegacyHookBinaryIfPresent(paths: paths, fileManager: fileManager)
            return
        }

        config["hooks"] = hooks

        // -- 4. Write back -----------------------------------------------------
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
            removeLegacyHookBinaryIfPresent(paths: paths, fileManager: fileManager)
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to write \(claudeSettings.path): \(error)")
        }
    }

    // MARK: - Private helpers

    /// Detects a valid `settings.json` that's been written as a single compact
    /// line. Returning true lets the configurator re-emit it pretty even when
    /// none of our hook entries changed.
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

    private static func commandReferencesPath(_ command: String?, _ path: String) -> Bool {
        guard let command else { return false }
        return command == path || command.hasPrefix(path + " ") || command.contains(path)
    }

    private static func isAgentHaloHookCommand(_ command: String?, paths: AgentHaloPaths) -> Bool {
        guard let command else { return false }
        return commandReferencesPath(command, paths.statusHook.path)
            || command.contains("claude-code-status-hook")
            || command.contains("/bin/status-hook")
    }

    private static func removeLegacyHookBinaryIfPresent(paths: AgentHaloPaths, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: paths.legacyStatusHook.path) else { return }
        do {
            try fileManager.removeItem(at: paths.legacyStatusHook)
            AgentHaloLogger.log("ClaudeHookConfigurator: removed legacy \(paths.legacyStatusHook.path)")
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to remove legacy hook binary: \(error)")
        }
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
        let matcher: String?  // nil = no matcher, fires for every event
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
