import Foundation

/// Idempotent best-effort migration of `~/.agent-halo` to layout version 2.
///
/// Moves data paths into `state/` / `logs/` / `cache/`, deletes legacy data
/// paths after success, and writes `.layout-version = 2`. Does **not** delete
/// staged legacy binaries (`claude-code-status-hook`, `claude-code-statusline-proxy`);
/// configurators remove those after settings rewrite.
public enum AgentHaloLayoutMigrator {
    public static func migrateIfNeeded(
        paths: AgentHaloPaths = AgentHaloPaths(),
        fileManager: FileManager = .default
    ) {
        ensureLayoutDirectories(paths: paths, fileManager: fileManager)

        if readVersion(paths: paths, fileManager: fileManager) >= AgentHaloPaths.layoutVersion {
            scrubLegacyDataPaths(paths: paths, fileManager: fileManager)
            return
        }

        moveOrReplace(from: paths.legacyClaudeStatusLog, to: paths.claudeStatusLog, fileManager: fileManager)
        moveOrReplace(from: paths.legacyGrokStatusLog, to: paths.grokStatusLog, fileManager: fileManager)
        moveDirectoryContents(
            from: paths.legacyClaudeContextsDirectory,
            to: paths.claudeContextsDirectory,
            fileManager: fileManager
        )
        moveOrReplace(from: paths.legacyUsageSnapshots, to: paths.usageSnapshots, fileManager: fileManager)
        moveOrReplace(
            from: paths.legacyStatuslineOriginalCommand,
            to: paths.statuslineOriginalCommand,
            fileManager: fileManager
        )
        removeIfExists(paths.legacyClaudeContextFile, fileManager: fileManager)
        removeEmptyDirectoryIfExists(paths.legacyClaudeContextsDirectory, fileManager: fileManager)

        writeLayoutVersion(AgentHaloPaths.layoutVersion, paths: paths, fileManager: fileManager)
        scrubLegacyDataPaths(paths: paths, fileManager: fileManager)
        ClaudeContextUsageStorage.prune(
            directory: paths.claudeContextsDirectory,
            force: true,
            fileManager: fileManager
        )
    }

    // MARK: - Version

    static func readVersion(paths: AgentHaloPaths, fileManager: FileManager) -> Int {
        guard fileManager.fileExists(atPath: paths.layoutVersionFile.path) else {
            return 0
        }
        guard let raw = try? String(contentsOf: paths.layoutVersionFile, encoding: .utf8) else {
            return 0
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? 0
    }

    static func writeLayoutVersion(_ version: Int, paths: AgentHaloPaths, fileManager: FileManager) {
        do {
            try "\(version)\n".write(to: paths.layoutVersionFile, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.layoutVersionFile.path
            )
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: failed to write layout version: \(error)")
        }
    }

    // MARK: - Directories

    static func ensureLayoutDirectories(paths: AgentHaloPaths, fileManager: FileManager) {
        for directory in [
            paths.root,
            paths.binDirectory,
            paths.stateDirectory,
            paths.logsDirectory,
            paths.cacheDirectory,
            paths.claudeContextsDirectory,
        ] {
            ensureDirectory(directory, mode: 0o700, fileManager: fileManager)
        }
    }

    static func ensureDirectory(_ url: URL, mode: Int, fileManager: FileManager) {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: mode]
            )
        } catch {
            // Directory may already exist without matching attributes.
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: url.path
                )
            } else {
                AgentHaloLogger.log("AgentHaloLayoutMigrator: failed to create \(url.path): \(error)")
            }
        }
    }

    // MARK: - Move / scrub

    /// Scrub only **data** legacy paths. Never deletes legacy binaries.
    static func scrubLegacyDataPaths(paths: AgentHaloPaths, fileManager: FileManager) {
        removeIfExists(paths.legacyClaudeStatusLog, fileManager: fileManager)
        removeIfExists(paths.legacyGrokStatusLog, fileManager: fileManager)
        removeIfExists(paths.legacyUsageSnapshots, fileManager: fileManager)
        removeIfExists(paths.legacyStatuslineOriginalCommand, fileManager: fileManager)
        removeIfExists(paths.legacyClaudeContextFile, fileManager: fileManager)
        removeDirectoryTreeIfExists(paths.legacyClaudeContextsDirectory, fileManager: fileManager)
    }

    static func moveOrReplace(from: URL, to: URL, fileManager: FileManager) {
        let fromExists = fileManager.fileExists(atPath: from.path)
        let toExists = fileManager.fileExists(atPath: to.path)

        if toExists {
            if fromExists {
                removeIfExists(from, fileManager: fileManager)
            }
            return
        }
        guard fromExists else { return }

        ensureDirectory(to.deletingLastPathComponent(), mode: 0o700, fileManager: fileManager)

        do {
            try fileManager.moveItem(at: from, to: to)
            return
        } catch {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: move failed \(from.lastPathComponent) → \(to.path): \(error); trying copy"
            )
        }

        do {
            try fileManager.copyItem(at: from, to: to)
            removeIfExists(from, fileManager: fileManager)
        } catch {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: copy failed \(from.path) → \(to.path): \(error)"
            )
        }
    }

    static func moveDirectoryContents(from: URL, to: URL, fileManager: FileManager) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        ensureDirectory(to, mode: 0o700, fileManager: fileManager)

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: from,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: list \(from.path) failed: \(error)")
            return
        }

        for child in children {
            let destination = to.appendingPathComponent(child.lastPathComponent)
            moveOrReplace(from: child, to: destination, fileManager: fileManager)
        }

        removeEmptyDirectoryIfExists(from, fileManager: fileManager)
    }

    static func removeIfExists(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: remove \(url.path) failed: \(error)")
        }
    }

    static func removeDirectoryTreeIfExists(_ url: URL, fileManager: FileManager) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        removeIfExists(url, fileManager: fileManager)
    }

    static func removeEmptyDirectoryIfExists(_ url: URL, fileManager: FileManager) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        if let children = try? fileManager.contentsOfDirectory(atPath: url.path), !children.isEmpty {
            return
        }
        removeIfExists(url, fileManager: fileManager)
    }
}
