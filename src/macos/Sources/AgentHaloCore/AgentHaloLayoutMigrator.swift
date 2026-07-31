import Foundation

/// Idempotent best-effort migration of `~/.agent-halo` to layout version 2.
///
/// Moves data paths into `state/` / `logs/` / `cache/`, deletes legacy **data**
/// paths after success, and writes `.layout-version = 2`.
///
/// Never deletes staged binaries (`claude-code-status-hook`,
/// `claude-code-statusline-proxy`, or anything under `bin/`). Configurators keep
/// those paths populated as upgrade-compat mirrors so running Grok/Claude
/// sessions do not fail with hook exit 127 mid-upgrade.
public enum AgentHaloLayoutMigrator {
    public static func migrateIfNeeded(
        paths: AgentHaloPaths = AgentHaloPaths(),
        fileManager: FileManager = .default
    ) {
        guard ensureLayoutDirectories(paths: paths, fileManager: fileManager) else {
            return
        }

        let currentVersion = readVersion(paths: paths, fileManager: fileManager)
        let migrated = [
            moveOrReplace(
                from: paths.legacyClaudeStatusLog,
                to: paths.claudeStatusLog,
                fileManager: fileManager
            ),
            moveOrReplace(
                from: paths.legacyGrokStatusLog,
                to: paths.grokStatusLog,
                fileManager: fileManager
            ),
            moveDirectoryContents(
                from: paths.legacyClaudeContextsDirectory,
                to: paths.claudeContextsDirectory,
                fileManager: fileManager
            ),
            moveOrReplace(
                from: paths.legacyUsageSnapshots,
                to: paths.usageSnapshots,
                fileManager: fileManager
            ),
            moveOrReplace(
                from: paths.legacyStatuslineOriginalCommand,
                to: paths.statuslineOriginalCommand,
                requireNonEmptyDestination: true,
                fileManager: fileManager
            ),
            removeIfExists(paths.legacyClaudeContextFile, fileManager: fileManager),
            removeEmptyDirectoryIfExists(
                paths.legacyClaudeContextsDirectory,
                fileManager: fileManager
            ),
        ].allSatisfy { $0 }

        guard migrated else {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: migration incomplete; preserving legacy data for retry"
            )
            return
        }

        if currentVersion < AgentHaloPaths.layoutVersion {
            guard writeLayoutVersion(
                AgentHaloPaths.layoutVersion,
                paths: paths,
                fileManager: fileManager
            ) else {
                return
            }
        }

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

    @discardableResult
    static func writeLayoutVersion(
        _ version: Int,
        paths: AgentHaloPaths,
        fileManager: FileManager
    ) -> Bool {
        do {
            try "\(version)\n".write(to: paths.layoutVersionFile, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.layoutVersionFile.path
            )
            return true
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: failed to write layout version: \(error)")
            return false
        }
    }

    // MARK: - Directories

    static func ensureLayoutDirectories(paths: AgentHaloPaths, fileManager: FileManager) -> Bool {
        [
            paths.root,
            paths.binDirectory,
            paths.stateDirectory,
            paths.logsDirectory,
            paths.cacheDirectory,
            paths.claudeContextsDirectory,
        ].allSatisfy {
            ensureDirectory($0, mode: 0o700, fileManager: fileManager)
        }
    }

    @discardableResult
    static func ensureDirectory(_ url: URL, mode: Int, fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: mode]
            )
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                AgentHaloLogger.log(
                    "AgentHaloLayoutMigrator: expected directory at \(url.path)"
                )
                return false
            }
            try fileManager.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: failed to prepare \(url.path): \(error)")
            return false
        }
    }

    // MARK: - Move / scrub

    @discardableResult
    static func moveOrReplace(
        from: URL,
        to: URL,
        requireNonEmptyDestination: Bool = false,
        fileManager: FileManager
    ) -> Bool {
        let fromExists = fileManager.fileExists(atPath: from.path)
        let toExists = fileManager.fileExists(atPath: to.path)

        if toExists {
            guard fromExists else { return true }
            guard isUsableRegularFile(
                to,
                requireNonEmpty: requireNonEmptyDestination,
                fileManager: fileManager
            ) else {
                AgentHaloLogger.log(
                    "AgentHaloLayoutMigrator: destination is not a usable file: \(to.path)"
                )
                return false
            }
            return removeIfExists(from, fileManager: fileManager)
        }
        guard fromExists else { return true }
        guard isUsableRegularFile(
            from,
            requireNonEmpty: requireNonEmptyDestination,
            fileManager: fileManager
        ) else {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: source is not a regular file: \(from.path)"
            )
            return false
        }

        guard ensureDirectory(
            to.deletingLastPathComponent(),
            mode: 0o700,
            fileManager: fileManager
        ) else {
            return false
        }

        do {
            try fileManager.moveItem(at: from, to: to)
            return isUsableRegularFile(
                to,
                requireNonEmpty: requireNonEmptyDestination,
                fileManager: fileManager
            )
        } catch {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: move failed \(from.lastPathComponent) → \(to.path): \(error); trying copy"
            )
        }

        do {
            try fileManager.copyItem(at: from, to: to)
            guard isUsableRegularFile(
                to,
                requireNonEmpty: requireNonEmptyDestination,
                fileManager: fileManager
            ) else {
                AgentHaloLogger.log(
                    "AgentHaloLayoutMigrator: copied destination failed validation: \(to.path)"
                )
                return false
            }
            return removeIfExists(from, fileManager: fileManager)
        } catch {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: copy failed \(from.path) → \(to.path): \(error)"
            )
            return false
        }
    }

    static func moveDirectoryContents(from: URL, to: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue else {
            return !fileManager.fileExists(atPath: from.path)
        }

        guard ensureDirectory(to, mode: 0o700, fileManager: fileManager) else {
            return false
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: from,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: list \(from.path) failed: \(error)")
            return false
        }

        var succeeded = true
        for child in children {
            let destination = to.appendingPathComponent(child.lastPathComponent)
            var childIsDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: child.path,
                isDirectory: &childIsDirectory
            )
            if exists, childIsDirectory.boolValue {
                succeeded = moveDirectoryContents(
                    from: child,
                    to: destination,
                    fileManager: fileManager
                ) && succeeded
            } else {
                succeeded = moveOrReplace(
                    from: child,
                    to: destination,
                    fileManager: fileManager
                ) && succeeded
            }
        }

        return removeEmptyDirectoryIfExists(from, fileManager: fileManager) && succeeded
    }

    @discardableResult
    static func removeIfExists(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            AgentHaloLogger.log("AgentHaloLayoutMigrator: remove \(url.path) failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func removeEmptyDirectoryIfExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return true
        }
        guard isDir.boolValue else {
            AgentHaloLogger.log(
                "AgentHaloLayoutMigrator: expected directory while cleaning \(url.path)"
            )
            return false
        }
        if let children = try? fileManager.contentsOfDirectory(atPath: url.path), !children.isEmpty {
            return false
        }
        return removeIfExists(url, fileManager: fileManager)
    }

    static func isUsableRegularFile(
        _ url: URL,
        requireNonEmpty: Bool,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        guard requireNonEmpty else { return true }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0
    }
}
