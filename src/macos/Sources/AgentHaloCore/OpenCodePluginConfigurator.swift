import Foundation

/// Installs the shared OpenCode status plugin.
///
/// Source of truth: `src/shared/integrations/opencode/agent-halo-status.js`,
/// mirrored into the AgentHaloCore resource bundle by `scripts/build-macos.sh`.
public enum OpenCodePluginConfigurator {
    public static let pluginFileName = "agent-halo-status.js"

    @discardableResult
    public static func configure(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let source = readEmbeddedSource() else {
            AgentHaloLogger.log("OpenCode plugin configure failed: embedded source missing")
            return nil
        }
        let target = pluginURL(homeDirectory: homeDirectory, environment: environment)
        do {
            if fileManager.fileExists(atPath: target.path),
               let existing = try? String(contentsOf: target, encoding: .utf8),
               existing == source {
                return target
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temp = target.appendingPathExtension("tmp")
            try source.write(to: temp, atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: target)
            }
            return target
        } catch {
            AgentHaloLogger.log("OpenCode plugin configure failed: \(error)")
            return nil
        }
    }

    public static func pluginURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginFileName)
    }

    public static func configDirectory(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        if let override = trimmed(environment["OPENCODE_CONFIG_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let xdg = trimmed(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    public static func readEmbeddedSource() -> String? {
        if let bundled = AgentHaloResources.bundle.url(
            forResource: "agent-halo-status",
            withExtension: "js",
            subdirectory: "integrations/opencode"
        ),
           let text = try? String(contentsOf: bundled, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shared = sourceRoot
            .appendingPathComponent("shared/integrations/opencode", isDirectory: true)
            .appendingPathComponent(pluginFileName)
        if let text = try? String(contentsOf: shared, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
