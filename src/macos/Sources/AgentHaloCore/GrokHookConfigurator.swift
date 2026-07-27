import Foundation

/// Writes (or updates) Grok Build hook configuration on first launch so the user
/// never has to manually edit ``~/.grok/hooks/``.
///
/// Design:
/// - Stages the same bundled ``ClaudeCodeStatusHook`` binary used for Claude to
///   ``~/.agent-halo/claude-code-status-hook`` (shared path; the binary routes
///   Grok vs Claude via ``GROK_*`` env at runtime — see Task 6).
/// - Writes lifecycle hooks into ``~/.grok/hooks/agent-halo-status.json`` so
///   Grok Build loads them even when Claude-compat mode is off.
/// - Idempotent: if the hook command is already present for all lifecycle events,
///   the file is left untouched (mtime stable).
/// - Catches all errors — a broken config write must never prevent the app from
///   starting.
public enum GrokHookConfigurator {

    // MARK: - Public API

    /// Ensure the hook binary and ``~/.grok/hooks/agent-halo-status.json`` are configured.
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
    /// without touching the user's real Grok settings.
    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let destDir = home.appendingPathComponent(".agent-halo", isDirectory: true)
        let destBinary = destDir.appendingPathComponent("claude-code-status-hook")
        let hooksDir = home.appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")

        // -- 1. Stage the hook binary -------------------------------------------
        guard let bundledBinary,
              FileManager.default.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("GrokHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
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

        // -- 3. Idempotency: skip write when already fully configured ----------
        if isAlreadyConfigured(at: hooksFile, hookCommand: hookCommand) {
            AgentHaloLogger.log("GrokHookConfigurator: hooks already configured — nothing to do")
            return
        }

        // -- 4. Write ----------------------------------------------------------
        do {
            try FileManager.default.createDirectory(
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
        } catch {
            AgentHaloLogger.log("GrokHookConfigurator: failed to write \(hooksFile.path): \(error)")
        }
    }

    // MARK: - Private helpers

    /// Returns true when ``agent-halo-status.json`` already registers our staged
    /// binary for every lifecycle event we care about (including matchers).
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
                    (hook["command"] as? String)?.contains(hookCommand) == true
                        || (hook["command"] as? String)?.contains("claude-code-status-hook") == true
                }
                guard hasCommand else { return false }
                if let matcher = spec.matcher {
                    // Matcher must be present (including empty string for Pre/PostCompact).
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

    /// Minimal Grok Build lifecycle event set (design §GrokHookConfigurator).
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
