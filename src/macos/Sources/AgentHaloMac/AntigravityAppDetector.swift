import AppKit

/// Desktop-app presence for Antigravity 2.0 (`/Applications/Antigravity.app`).
/// Mirrors `CodexAppDetector`: only the regular app counts, never Helper
/// processes or `language_server`. `agy` CLI presence stays in
/// `AntigravityActivityMonitor`.
enum AntigravityAppDetector {
    @MainActor
    static func isAntigravityRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            isPrimaryApp(app)
        }
    }

    static func isPrimaryApp(_ app: NSRunningApplication) -> Bool {
        matchesPrimaryApp(
            bundleIdentifier: app.bundleIdentifier,
            executableName: app.executableURL?.lastPathComponent,
            activationPolicy: app.activationPolicy
        )
    }

    static func matchesPrimaryApp(
        bundleIdentifier: String?,
        executableName: String?,
        activationPolicy: NSApplication.ActivationPolicy
    ) -> Bool {
        guard activationPolicy == .regular else {
            return false
        }
        if executableName == "Antigravity" {
            return true
        }
        return (bundleIdentifier ?? "").lowercased() == "com.google.antigravity"
    }
}
