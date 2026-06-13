import Foundation

public enum AgentHaloLogger {
    public static func log(_ text: String) {
        let logURL = SettingsStore.defaultSettingsURL()
            .deletingLastPathComponent()
            .appendingPathComponent("halo.log")
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = "\(Date()) \(text)\n"
            if FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: logURL)
            }
        } catch {
        }
    }
}
