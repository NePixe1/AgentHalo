import Foundation

public enum StartupLaunchAgent {
    public static func executablePath(appBundleURL: URL) -> String {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AgentHaloMac")
            .path(percentEncoded: false)
    }
}
