import Foundation

public enum ClaudeStatusLineConfigurator {
    // Local settings do not require a file-coordination service. Serialize our
    // read/modify/write operations and replace the JSON atomically for readers.
    private static let settingsWriteLock = NSLock()

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
                at: paths.stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try AgentHaloBinaryStaging.stageStatuslineProxy(
                from: bundledBinary,
                homeDirectory: home,
                fileManager: fileManager
            )
        } catch {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to stage proxy: \(error)")
            return
        }

        settingsWriteLock.lock()
        defer { settingsWriteLock.unlock() }

        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
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

        guard currentCommand != installedProxy.path else { return }

        statusLine["type"] = "command"
        statusLine["command"] = installedProxy.path
        settings["statusLine"] = statusLine

        do {
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to update settings: \(error)")
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
