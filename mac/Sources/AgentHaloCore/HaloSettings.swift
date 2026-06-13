import Foundation

public struct HaloSettings: Codable, Equatable, Sendable {
    public var installedAt: Date
    public var acknowledged: [String: Date]
    public var paused: Bool
    public var left: Double?
    public var top: Double?

    public init(
        installedAt: Date = Date(),
        acknowledged: [String: Date] = [:],
        paused: Bool = false,
        left: Double? = nil,
        top: Double? = nil
    ) {
        self.installedAt = installedAt
        self.acknowledged = acknowledged
        self.paused = paused
        self.left = left
        self.top = top
    }

    public func acknowledgingCompletedSessions(_ sessions: [SessionSnapshot]) -> HaloSettings {
        var next = self
        for session in sessions where session.state == .done {
            guard let completedAt = session.completedAt else {
                continue
            }
            let current = next.acknowledged[session.threadId] ?? .distantPast
            if completedAt > current {
                next.acknowledged[session.threadId] = completedAt
            }
        }
        return next
    }
}

public struct SettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL = SettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
    }

    public func load() -> HaloSettings {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return HaloSettings()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if var settings = try? decoder.decode(HaloSettings.self, from: data) {
            settings.paused = false
            return settings
        }
        return HaloSettings()
    }

    public func save(_ settings: HaloSettings) {
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var persisted = settings
            persisted.paused = false
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persisted)
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            AgentHaloLogger.log("Settings save failed: \(error)")
        }
    }

    public static func defaultSettingsURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let root = support ?? FileManager.default.homeDirectoryForCurrentUser
        return root.appendingPathComponent("AgentHalo", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
