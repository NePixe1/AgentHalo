import Foundation

/// Writes (or updates) Claude Code hook configuration on first launch so the user
/// never has to manually edit ``~/.claude/settings.json``.
///
/// Design:
/// - Copies the bundled ``ClaudeCodeStatusHook`` binary to
///   ``~/.agent-halo/claude-code-status-hook`` — a stable path that survives
///   app-bundle moves.
/// - Merges hook entries into ``~/.claude/settings.json`` at the **user** level so every
///   Claude Code project inherits the hooks automatically.
/// - Idempotent: if the hook command is already present for all lifecycle events,
///   the file is left untouched.
/// - Catches all errors — a broken config write must never prevent the app from
///   starting.
public enum ClaudeHookConfigurator {

    // MARK: - Public API

    /// Ensure the hook binary and user-level ``~/.claude/settings.json`` are configured.
    ///
    /// Safe to call on every launch; the implementation short-circuits when
    /// everything is already in place.
    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    /// Ensure hook configuration for a specific home directory.
    ///
    /// Exposed for the self-check target so configuration behavior can be tested
    /// without touching the user's real Claude Code settings.
    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let destDir = home.appendingPathComponent(".agent-halo", isDirectory: true)
        let destBinary = destDir.appendingPathComponent("claude-code-status-hook")
        let claudeSettings = home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        // -- 1. Stage the hook binary -------------------------------------------
        guard let bundledBinary,
              FileManager.default.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("ClaudeHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Always overwrite so the binary stays up-to-date across app upgrades.
            if FileManager.default.fileExists(atPath: destBinary.path) {
                try FileManager.default.removeItem(at: destBinary)
            }
            try FileManager.default.copyItem(at: bundledBinary, to: destBinary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destBinary.path
            )
            AgentHaloLogger.log("ClaudeHookConfigurator: staged \(destBinary.path)")
        } catch {
            AgentHaloLogger.log("ClaudeHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let hookCommand = "\(destBinary.path)"

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

            // Idempotency: skip if this event already references our binary
            // with the correct matcher.  Events like PreCompact/PostCompact
            // require a matcher (even an empty string); omitting it causes CC
            // to ignore the hook silently.
            let alreadyConfigured = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                let hasHook = entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains("claude-code-status-hook") == true
                }
                guard hasHook else { return false }
                // If the spec carries a matcher (including ""), the entry must
                // have the key — otherwise fix it on the next pass.
                if spec.matcher != nil, entry["matcher"] == nil {
                    return false
                }
                return true
            }
            if alreadyConfigured { continue }

            // Remove a stale entry (e.g. one missing a required matcher) so we
            // can append the corrected version below.
            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains("claude-code-status-hook") == true
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

        guard changed else {
            AgentHaloLogger.log("ClaudeHookConfigurator: hooks already configured — nothing to do")
            return
        }

        config["hooks"] = hooks

        // -- 4. Write back -----------------------------------------------------
        do {
            try FileManager.default.createDirectory(
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
        HookSpec(event: "Notification", matcher: nil),
        HookSpec(event: "Stop", matcher: nil),
        HookSpec(event: "StopFailure", matcher: nil),
        HookSpec(event: "SessionEnd", matcher: nil),
        HookSpec(event: "PreCompact", matcher: ""),
        HookSpec(event: "PostCompact", matcher: ""),
    ]
}
