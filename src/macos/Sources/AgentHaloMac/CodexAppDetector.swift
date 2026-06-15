import AppKit

enum CodexAppDetector {
    static func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains(where: isCodexApp)
    }

    static func isCodexForeground() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return isCodexApp(app)
    }

    static func activateCodex() {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            app.activationPolicy == .regular &&
            isCodexApp(app)
        }
        candidates.first?.activate(options: [.activateIgnoringOtherApps])
    }

    private static func isCodexApp(_ app: NSRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return bundle.contains("codex") || name.contains("codex")
    }
}
