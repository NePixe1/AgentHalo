import Foundation

/// Writes (or updates) Antigravity (`agy`) named-group hooks so the user
/// never has to manually edit ``~/.gemini/config/hooks.json``.
///
/// Merges group ``agent-halo-status``; never replaces other groups
/// (e.g. ``orca-status``). Does not write ``settings.json``.
public enum AntigravityHookConfigurator {
    public static let groupName = "agent-halo-status"

    public static func hooksFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/config/hooks.json")
    }

    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledHookBinary: bundledHookBinary())
    }

    public static func configure(homeDirectory home: URL, bundledHookBinary bundledBinary: URL?) {
        let paths = AgentHaloPaths(homeDirectory: home)
        let hooksURL = hooksFile(homeDirectory: home)
        let fileManager = FileManager.default

        guard let bundledBinary,
              fileManager.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("AntigravityHookConfigurator: bundled binary not found — skipping hook setup (development mode?)")
            return
        }

        do {
            try AgentHaloBinaryStaging.stageStatusHook(
                from: bundledBinary,
                homeDirectory: home,
                fileManager: fileManager
            )
            AgentHaloLogger.log("AntigravityHookConfigurator: staged \(paths.statusHook.path)")
        } catch {
            AgentHaloLogger.log("AntigravityHookConfigurator: failed to stage binary: \(error)")
            return
        }

        let preferredPath = paths.statusHook.path
        if isOnPreferredPath(at: hooksURL, preferredPath: preferredPath, fileManager: fileManager) {
            AgentHaloLogger.log("AntigravityHookConfigurator: hooks already on preferred path — nothing to do")
            return
        }

        var config: [String: Any]
        if fileManager.fileExists(atPath: hooksURL.path) {
            guard let data = try? Data(contentsOf: hooksURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AgentHaloLogger.log("AntigravityHookConfigurator: \(hooksURL.path) root is not a dictionary — skipping")
                return
            }
            config = json
        } else {
            config = [:]
        }

        config[groupName] = preferredGroup(preferredPath: preferredPath)

        do {
            try fileManager.createDirectory(
                at: hooksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: hooksURL, options: [.atomic])
            AgentHaloLogger.log("AntigravityHookConfigurator: wrote \(hooksURL.path)")
        } catch {
            AgentHaloLogger.log("AntigravityHookConfigurator: failed to write \(hooksURL.path): \(error)")
        }
    }

    /// True when group ``agent-halo-status`` already points at preferred
    /// ``bin/status-hook`` for all five events (and that binary is live).
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
              let group = json[groupName] as? [String: Any] else {
            return false
        }

        for spec in hookSpecs {
            guard let entries = group[spec.event] as? [[String: Any]] else {
                return false
            }
            let found = entries.contains { entry in
                if spec.nested {
                    guard let matcher = entry["matcher"] as? String, matcher == "*" else {
                        return false
                    }
                    guard let hooks = entry["hooks"] as? [[String: Any]] else {
                        return false
                    }
                    return hooks.contains { hook in
                        isPreferredCommand(hook["command"] as? String, preferredPath: preferredPath, event: spec.event)
                    }
                }
                return isPreferredCommand(entry["command"] as? String, preferredPath: preferredPath, event: spec.event)
            }
            if !found { return false }
        }
        return true
    }

    // MARK: - Private

    private static func preferredGroup(preferredPath: String) -> [String: Any] {
        var group: [String: Any] = [:]
        for spec in hookSpecs {
            let hook: [String: Any] = [
                "type": "command",
                "command": "\(preferredPath) \(spec.event)",
                "timeout": 10,
            ]
            if spec.nested {
                group[spec.event] = [[
                    "matcher": "*",
                    "hooks": [hook],
                ]]
            } else {
                group[spec.event] = [hook]
            }
        }
        return group
    }

    private static func isPreferredCommand(
        _ command: String?,
        preferredPath: String,
        event: String
    ) -> Bool {
        guard let command else { return false }
        let exe = AgentHaloBinaryStaging.commandExecutablePath(command)
        return exe == preferredPath && command.hasSuffix(" \(event)")
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
        let nested: Bool
    }

    private static let hookSpecs: [HookSpec] = [
        HookSpec(event: "PreInvocation", nested: false),
        HookSpec(event: "PostInvocation", nested: false),
        HookSpec(event: "Stop", nested: false),
        HookSpec(event: "PreToolUse", nested: true),
        HookSpec(event: "PostToolUse", nested: true),
    ]
}
