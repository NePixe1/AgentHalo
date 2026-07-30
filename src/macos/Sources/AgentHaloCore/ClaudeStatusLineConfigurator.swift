import Foundation

public enum ClaudeStatusLineConfigurator {
    public static func isConfigured(
        homeDirectory home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let settingsURL = home.appendingPathComponent(".claude/settings.json", isDirectory: false)
        let installedProxy = AgentHaloPaths(homeDirectory: home).statuslineProxy
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return URL(fileURLWithPath: command).standardizedFileURL == installedProxy.standardizedFileURL
    }

    public static func configure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configure(homeDirectory: home, bundledProxyBinary: bundledProxyBinary())
    }

    public static func configure(homeDirectory home: URL, bundledProxyBinary bundledBinary: URL?) {
        guard let bundledBinary,
              FileManager.default.fileExists(atPath: bundledBinary.path) else {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: bundled proxy not found")
            return
        }

        let fileManager = FileManager.default
        let paths = AgentHaloPaths(homeDirectory: home)
        let installedProxy = paths.statuslineProxy
        let originalCommandURL = paths.statuslineOriginalCommand
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        do {
            try fileManager.createDirectory(
                at: paths.binDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: paths.stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: installedProxy.path) {
                try fileManager.removeItem(at: installedProxy)
            }
            try fileManager.copyItem(at: bundledBinary, to: installedProxy)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedProxy.path)
        } catch {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to stage proxy: \(error)")
            return
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var wroteSettingsSuccessfully = false

        coordinator.coordinate(writingItemAt: settingsURL, options: [], error: &coordinatorError) { url in
            var settings: [String: Any]
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            } else {
                settings = [:]
            }

            var statusLine = (settings["statusLine"] as? [String: Any]) ?? [:]
            let currentCommand = statusLine["command"] as? String ?? ""
            let alreadyUsesNewProxy =
                URL(fileURLWithPath: currentCommand).standardizedFileURL
                == installedProxy.standardizedFileURL
            let alreadyUsesLegacyProxy = currentCommand.contains("claude-code-statusline-proxy")

            if !currentCommand.isEmpty, !alreadyUsesNewProxy, !alreadyUsesLegacyProxy {
                do {
                    try Data(currentCommand.utf8).write(to: originalCommandURL, options: [.atomic])
                    try? fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: originalCommandURL.path
                    )
                } catch {
                    AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to preserve original command: \(error)")
                    return
                }
            }

            guard currentCommand != installedProxy.path else {
                wroteSettingsSuccessfully = true
                return
            }

            statusLine["type"] = "command"
            statusLine["command"] = installedProxy.path
            settings["statusLine"] = statusLine

            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: [.atomic])
                wroteSettingsSuccessfully = true
            } catch {
                AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to update settings: \(error)")
            }
        }

        if let error = coordinatorError {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: file coordination failed: \(error)")
        }

        // Only delete the legacy proxy after settings point at the new path (or
        // were already correct). Missing bundled binary is handled above by early return.
        if wroteSettingsSuccessfully || isConfigured(homeDirectory: home) {
            removeLegacyProxyBinaryIfPresent(paths: paths, fileManager: fileManager)
        }
    }

    private static func removeLegacyProxyBinaryIfPresent(paths: AgentHaloPaths, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: paths.legacyStatuslineProxy.path) else { return }
        do {
            try fileManager.removeItem(at: paths.legacyStatuslineProxy)
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: removed legacy \(paths.legacyStatuslineProxy.path)")
        } catch {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to remove legacy proxy binary: \(error)")
        }
    }

    private static func bundledProxyBinary() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return nil
        }
        return URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("claude-code-statusline-proxy")
    }
}
