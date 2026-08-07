import Foundation

/// Installs the shared Pi status extension into the Pi agent extensions directory.
///
/// Source of truth: `src/shared/integrations/pi/agent-halo-status.ts` (mirrored into
/// the AgentHaloCore resource bundle by `scripts/build-macos.sh`).
public enum PiExtensionConfigurator {
    public static let extensionFileName = "agent-halo-status.ts"

    @discardableResult
    public static func configure(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let source = readEmbeddedSource() else {
            AgentHaloLogger.log("Pi extension configure failed: embedded source missing")
            return nil
        }
        let target = extensionURL(homeDirectory: homeDirectory)
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
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: temp, to: target)
            return target
        } catch {
            AgentHaloLogger.log("Pi extension configure failed: \(error)")
            return nil
        }
    }

    public static func resolveAgentRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    public static func extensionURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolveAgentRoot(homeDirectory: homeDirectory)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(extensionFileName)
    }

    public static func readEmbeddedSource() -> String? {
        if let bundled = Bundle.module.url(
            forResource: "agent-halo-status",
            withExtension: "ts",
            subdirectory: "integrations/pi"
        ),
           let text = try? String(contentsOf: bundled, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        // Development fallback: walk up from this source file to the repo root.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentHaloCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // src
        let shared = sourceRoot
            .appendingPathComponent("shared/integrations/pi", isDirectory: true)
            .appendingPathComponent(extensionFileName)
        if let text = try? String(contentsOf: shared, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }
}
