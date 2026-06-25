import AppKit

@MainActor
enum CodexAppDetector {
    private static let runningCacheInterval: TimeInterval = 2
    private static var runningCacheValue = false
    private static var runningCacheExpiresAt = Date.distantPast

    static func isCodexRunning(now: Date = Date()) -> Bool {
        if now < runningCacheExpiresAt {
            return runningCacheValue
        }
        let value = NSWorkspace.shared.runningApplications.contains { app in
            isCodexApp(app, allowLocalizedName: false)
        }
        runningCacheValue = value
        runningCacheExpiresAt = now.addingTimeInterval(runningCacheInterval)
        return value
    }

    static func isCodexForeground() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
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
