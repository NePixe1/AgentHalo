import Foundation

/// Single launch-time upgrade entry point.
///
/// Order is intentional and must stay this way across releases:
/// 1. Migrate data layout (logs/state/cache) — never deletes staged binaries.
/// 2. Prune context cache (best-effort).
/// 3. Stage hook/proxy binaries to **all** advertised paths (atomic, no gap).
/// 4. Rewrite Claude/Grok/statusline config only when unhealthy.
///
/// Configurators remain callable independently for tests; production app code
/// should prefer ``bootstrap()`` so upgrade order cannot drift.
public enum AgentHaloRuntimeBootstrap {
    public static func bootstrap(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledHookBinary: URL? = nil,
        bundledStatuslineProxy: URL? = nil,
        fileManager: FileManager = .default,
        enabledAgents: [AgentKind] = HaloSettings.defaultEnabledAgents
    ) {
        let paths = AgentHaloPaths(homeDirectory: homeDirectory)
        AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fileManager)
        ClaudeContextUsageStorage.prune(
            directory: paths.claudeContextsDirectory,
            force: true,
            fileManager: fileManager
        )

        let hook = bundledHookBinary ?? bundledResource("claude-code-status-hook")
        let proxy = bundledStatuslineProxy ?? bundledResource("claude-code-statusline-proxy")

        // Stage binaries before any settings rewrite so a hot-reloading Grok
        // session never points at a missing path during configure().
        if let hook {
            do {
                try AgentHaloBinaryStaging.stageStatusHookEverywhere(
                    from: hook,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
            } catch {
                AgentHaloLogger.log("AgentHaloRuntimeBootstrap: hook stage failed: \(error)")
            }
        }

        if let proxy {
            do {
                try AgentHaloBinaryStaging.stageStatuslineProxyEverywhere(
                    from: proxy,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
            } catch {
                AgentHaloLogger.log("AgentHaloRuntimeBootstrap: proxy stage failed: \(error)")
            }
        }

        // Only repair user configs for agents the user has enabled. Binary
        // staging above always runs so re-enabling later finds hooks ready.
        if enabledAgents.contains(.claudeCode) {
            ClaudeHookConfigurator.configure(
                homeDirectory: homeDirectory,
                bundledHookBinary: hook
            )
            ClaudeStatusLineConfigurator.configure(
                homeDirectory: homeDirectory,
                bundledProxyBinary: proxy
            )
        }
        if enabledAgents.contains(.grok) {
            GrokHookConfigurator.configure(
                homeDirectory: homeDirectory,
                bundledHookBinary: hook
            )
        }
        // Shared TS extension (no separate binary). Install/overwrite when the
        // embedded source differs from ~/.pi/agent/extensions/agent-halo-status.ts.
        if enabledAgents.contains(.pi) {
            PiExtensionConfigurator.configure(homeDirectory: homeDirectory)
        }
        if enabledAgents.contains(.antigravity) {
            AntigravityHookConfigurator.configure(
                homeDirectory: homeDirectory,
                bundledHookBinary: hook
            )
        }

        // Settings now point at bin/* — drop root-level legacy binaries that
        // nothing references anymore (claude-code-status-hook, etc.).
        AgentHaloBinaryStaging.scrubUnreferencedLegacyBinaries(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    private static func bundledResource(_ name: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return nil
        }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
