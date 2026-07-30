import Foundation

/// Writes (or updates) Grok Build hook configuration on first launch so the user
/// never has to manually edit ``~/.grok/hooks/``.
///
/// Design:
/// - Stages the same bundled ``ClaudeCodeStatusHook`` binary used for Claude to
///   ``~/.agent-halo/bin/status-hook`` (shared path; the binary routes Grok vs Claude
///   via ``GROK_*`` env at runtime).
/// - Writes lifecycle hooks into ``~/.grok/hooks/agent-halo-status.json``.
/// - Settings that still point at the legacy root binary are rewritten.
/// - After a successful hooks write (or when already on the new path), removes the
///   root-level legacy hook binary.
/// - Catches all errors — a broken config write must never prevent the app from
///   starting.
public enum GrokHookConfigurator {

    // MARK: - Public API

    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let paths = AgentHaloPaths(homeDirectory: home)
        let destBinary = paths.statusHook
        let hooksDir = home.appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")
        let fileManager = FileManager.default

        // -- 1. Stage the hook binary -------------------------------------------
        guard let bundledBinary,
              fileManager.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("GrokHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        do {
            try fileManager.createDirectory(
                at: paths.binDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: destBinary.path) {
                try fileManager.removeItem(at: destBinary)
            }
            try fileManager.copyItem(at: bundledBinary, to: destBinary)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destBinary.path
            )
            AgentHaloLogger.log("GrokHookConfigurator: staged \(destBinary.path)")
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let hookCommand = destBinary.path

        // -- 2. Build desired hooks config --------------------------------------
        var hooks: [String: Any] = [:]
        for spec in hookSpecs {
            var entry: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": "\(hookCommand) \(spec.event)"]
                ]
            ]
            if let matcher = spec.matcher {
                entry["matcher"] = matcher
            }
            hooks[spec.event] = [entry]
        }
        let config: [String: Any] = ["hooks": hooks]

        // -- 3. Idempotency: skip write when already fully configured at new path
        if isAlreadyConfigured(at: hooksFile, hookCommand: hookCommand) {
            AgentHaloLogger.log("GrokHookConfigurator: hooks already configured — nothing to do")
            removeLegacyHookBinaryIfPresent(paths: paths, fileManager: fileManager)
            return
        }

        // -- 4. Write ----------------------------------------------------------
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
            AgentHaloLogger.log("GrokHookConfigurator: wrote \(hooksFile.path)")
            removeLegacyHookBinaryIfPresent(paths: paths, fileManager: fileManager)
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to write \(hooksFile.path): \(error)")
        }
    }

    // MARK: - Private helpers

    /// Returns true when hooks already register the **new** staged binary for every
    /// lifecycle event. Legacy `claude-code-status-hook` paths are not considered configured.
    private static func isAlreadyConfigured(at url: URL, hookCommand: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for spec in hookSpecs {
            guard let entries = hooks[spec.event] as? [[String: Any]] else {
                return false
            }
            let configured = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                let hasCommand = entryHooks.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return command == "\(hookCommand) \(spec.event)"
                        || command.hasPrefix(hookCommand + " ")
                        || command.contains(hookCommand)
                }
                guard hasCommand else { return false }
                if let matcher = spec.matcher {
                    guard let existing = entry["matcher"] as? String, existing == matcher else {
                        return false
                    }
                }
                return true
            }
            if !configured { return false }
        }
        return true
    }

    private static func removeLegacyHookBinaryIfPresent(paths: AgentHaloPaths, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: paths.legacyStatusHook.path) else { return }
        do {
            try fileManager.removeItem(at: paths.legacyStatusHook)
            AgentHaloLogger.log("GrokHookConfigurator: removed legacy \(paths.legacyStatusHook.path)")
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to remove legacy hook binary: \(error)")
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
