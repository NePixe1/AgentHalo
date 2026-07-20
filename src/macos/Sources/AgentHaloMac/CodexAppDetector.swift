import AppKit

@MainActor
enum CodexAppDetector {
    private static var runningCacheValue: Bool?

    static func isCodexRunning() -> Bool {
        if let runningCacheValue {
            return runningCacheValue
        }
        let value = NSWorkspace.shared.runningApplications.contains { app in
            isCodexApp(app, allowLocalizedName: false)
        }
        runningCacheValue = value
        return value
    }

    @discardableResult
    static func noteApplicationDidLaunch(_ app: NSRunningApplication?) -> Bool {
        guard let app, isCodexApp(app, allowLocalizedName: false) else { return false }
        let changed = runningCacheValue != true
        runningCacheValue = true
        return changed
    }

    @discardableResult
    static func noteApplicationDidTerminate(_ app: NSRunningApplication?) -> Bool {
        guard let app, isCodexApp(app, allowLocalizedName: false) else { return false }
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
            app.activationPolicy == .regular &&
            isCodexApp(app, allowLocalizedName: true)
        }
        candidates.first?.activate(options: [.activateIgnoringOtherApps])
    }

    private static func isCodexApp(
        _ app: NSRunningApplication,
        allowLocalizedName: Bool
    ) -> Bool {
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let executableName = app.executableURL?.lastPathComponent.lowercased() ?? ""
        if bundle.contains("codex") || executableName.contains("codex") {
            return true
        }
        guard allowLocalizedName else {
            return false
        }
        let name = app.localizedName?.lowercased() ?? ""
        return name.contains("codex")
    }
}
