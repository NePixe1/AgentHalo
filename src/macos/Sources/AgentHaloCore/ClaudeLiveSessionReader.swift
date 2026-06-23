import Darwin
import Foundation

public enum ClaudeLiveSessionReader {
    public static func hasStandbySession(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let sessionsDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return files.contains { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            let status = String(describing: root["status"] ?? "").lowercased()
            guard status == "waiting" || status == "idle",
                  let number = root["pid"] as? NSNumber,
                  number.int32Value > 0 else {
                return false
            }
            errno = 0
            return kill(number.int32Value, 0) == 0 || errno == EPERM
        }
    }
}
