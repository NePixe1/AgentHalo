import Foundation

public enum ClaudeStatusLineConfigurator {
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
        let agentHaloDirectory = home.appendingPathComponent(".agent-halo", isDirectory: true)
        let installedProxy = agentHaloDirectory.appendingPathComponent("claude-code-statusline-proxy")
        let originalCommandURL = agentHaloDirectory.appendingPathComponent("claude-code-statusline-original-command")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        do {
            try fileManager.createDirectory(
                at: agentHaloDirectory,
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
            let alreadyUsesProxy = currentCommand.contains("claude-code-statusline-proxy")

            if !currentCommand.isEmpty, !alreadyUsesProxy {
                do {
                    try Data(currentCommand.utf8).write(to: originalCommandURL, options: [.atomic])
                } catch {
                    AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to preserve original command: \(error)")
                    return
                }
            }

            guard currentCommand != installedProxy.path else {
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
            } catch {
                AgentHaloLogger.log("ClaudeStatusLineConfigurator: failed to update settings: \(error)")
            }
        }

        if let error = coordinatorError {
            AgentHaloLogger.log("ClaudeStatusLineConfigurator: file coordination failed: \(error)")
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
