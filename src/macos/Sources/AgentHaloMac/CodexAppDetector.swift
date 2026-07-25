import AppKit

@MainActor
enum CodexAppDetector {
    private static var runningCacheValue: Bool?

    static func isCodexRunning() -> Bool {
        if let runningCacheValue {
            return runningCacheValue
        }
        // Only the regular Codex desktop app counts as "running". Background
        // helpers (for example host processes with "codex" in the name) must not
        // keep the halo online after the user quits the main app.
        let value = NSWorkspace.shared.runningApplications.contains { app in
            isPrimaryCodexApp(app)
        }
        runningCacheValue = value
        return value
    }

    @discardableResult
    static func noteApplicationDidLaunch(_ app: NSRunningApplication?) -> Bool {
        guard let app, isPrimaryCodexApp(app) else { return false }
        let changed = runningCacheValue != true
        runningCacheValue = true
        return changed
    }

    @discardableResult
    static func noteApplicationDidTerminate(_ app: NSRunningApplication?) -> Bool {
        // Invalidate any positive cache so the next scan re-reads running apps.
        // When the terminated process is not Codex, the rescan still keeps the
        // correct answer; when it is Codex (or a helper we previously matched),
        // offline becomes visible without waiting for another event.
        guard runningCacheValue == true else { return false }
        runningCacheValue = nil
        return true
    }

    static func isCodexForeground(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        return isCodexApp(app, allowLocalizedName: true)
    }

    static func activateCodex() {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            isPrimaryCodexApp(app)
        }
        candidates.first?.activate(options: [.activateIgnoringOtherApps])
    }

    /// Main Codex desktop app used for presence (STANDBY vs OFFLINE).
    private static func isPrimaryCodexApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else {
            return false
        }
        return isCodexApp(app, allowLocalizedName: false)
    }

    private static func isCodexApp(
        _ app: NSRunningApplication,
        allowLocalizedName: Bool
    ) -> Bool {
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let executableName = app.executableURL?.lastPathComponent.lowercased() ?? ""
        // Exact executable name avoids helpers such as "codex-code-mode-host".
        if executableName == "codex" {
            return true
        }
        // Official desktop bundles contain "codex" but helpers usually do not
        // ship as regular apps with a product bundle id.
        if bundle.contains("codex") {
            return true
        }
        guard allowLocalizedName else {
            return false
        }
        let name = app.localizedName?.lowercased() ?? ""
        return name == "codex"
    }
}
