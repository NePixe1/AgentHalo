import Darwin
import Foundation

public struct ClaudeLiveSessionSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var workingDirectory: String
    public var processId: Int32
    public var status: String
    public var updatedAt: Date

    public init(
        sessionId: String,
        workingDirectory: String,
        processId: Int32,
        status: String,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.processId = processId
        self.status = status
        self.updatedAt = updatedAt
    }

    public var safeProjectName: String? {
        let url = URL(fileURLWithPath: workingDirectory)
        let components = url.pathComponents
        if let claudeIndex = components.firstIndex(of: ".claude"),
           components.indices.contains(claudeIndex + 2),
           components[claudeIndex + 1] == "worktrees",
           components[claudeIndex + 2].hasPrefix("agent-") {
            return nil
        }
        let name = url.lastPathComponent
        return name.isEmpty ? nil : name
    }
}

public enum ClaudeLiveSessionReader {
    public static func hasStandbySession(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        !standbySessions(homeDirectory: homeDirectory, fileManager: fileManager).isEmpty
    }

    public static func standbySessions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [ClaudeLiveSessionSnapshot] {
        // Claude Code keeps `status` at "busy" while a turn is in flight and
        // only briefly visits "waiting"/"idle" between turns — gating standby
        // detection on those two values caused the ring to flicker off during
        // long answers. The on-disk file existing + the pid being alive is
        // enough; the actual CLI state is reflected by the hook stream.
        liveSessions(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public static func liveSessions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [ClaudeLiveSessionSnapshot] {
        let sessionsDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let status = String(describing: root["status"] ?? "").lowercased()
            guard status == "busy" || status == "waiting" || status == "idle",
                  let sessionId = root["sessionId"] as? String,
                  !sessionId.isEmpty,
                  let number = root["pid"] as? NSNumber,
                  number.int32Value > 0 else {
                return nil
            }
            errno = 0
            guard kill(number.int32Value, 0) == 0 || errno == EPERM else {
                return nil
            }
            let updatedMilliseconds = (root["updatedAt"] as? NSNumber)?.doubleValue
                ?? (root["statusUpdatedAt"] as? NSNumber)?.doubleValue
                ?? 0
            return ClaudeLiveSessionSnapshot(
                sessionId: sessionId,
                workingDirectory: root["cwd"] as? String ?? "",
                processId: number.int32Value,
                status: status,
                updatedAt: Date(timeIntervalSince1970: updatedMilliseconds / 1_000)
            )
        }
    }

    public static func preferredStandbySession(
        sessions: [ClaudeLiveSessionSnapshot],
        hookSnapshots: [SessionSnapshot]
    ) -> ClaudeLiveSessionSnapshot? {
        let hooksBySession = Dictionary(grouping: hookSnapshots, by: \.threadId)
            .mapValues { snapshots in
                snapshots.max { $0.lastEventAt < $1.lastEventAt }!
            }
        let matching = sessions.compactMap { session -> (ClaudeLiveSessionSnapshot, SessionSnapshot)? in
            guard let hook = hooksBySession[session.sessionId] else { return nil }
            return (session, hook)
        }
        if let preferred = matching.max(by: { lhs, rhs in
            if lhs.1.lastEventAt != rhs.1.lastEventAt {
                return lhs.1.lastEventAt < rhs.1.lastEventAt
            }
            return lhs.0.updatedAt < rhs.0.updatedAt
        }) {
            return preferred.0
        }
        return sessions.max { $0.updatedAt < $1.updatedAt }
    }
}
