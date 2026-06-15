import Foundation
import AgentHaloCore

enum StartupManager {
    static let label = "local.agenthalo.mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
    }

    static func setEnabled(_ enabled: Bool, appBundleURL: URL) {
        if enabled {
            writePlist(appBundleURL: appBundleURL)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func writePlist(appBundleURL: URL) {
        let executable = StartupLaunchAgent.executablePath(appBundleURL: appBundleURL)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(executable)</string></array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(plist.utf8).write(to: plistURL, options: [.atomic])
        } catch {
            AgentHaloLogger.log("Startup plist write failed: \(error)")
        }
    }
}
