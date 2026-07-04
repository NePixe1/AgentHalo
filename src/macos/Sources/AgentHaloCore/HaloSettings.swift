import Foundation

public struct HaloSettings: Codable, Equatable, Sendable {
    public static let currentAlwaysOnTopBehaviorVersion = 1
    public static let defaultHaloSize = 112.0
    public static let minimumHaloSize = 72.0
    public static let maximumHaloSize = 180.0

    public var hasPosition: Bool
    public var left: Double
    public var top: Double
    public var preferredDisplayUUID: String?
    public var preferredDisplayOffsetX: Double?
    public var preferredDisplayOffsetY: Double?
    public var haloSize: Double
    public var alwaysOnTop: Bool
    public var alwaysOnTopBehaviorVersion: Int
    public var paused: Bool
    public var focusedAgent: AgentKind
    public var installedAt: Date
    public var acknowledged: [String: Date]
    public var acknowledgedErrorAt: Date?
    public var language: String?

    private enum CodingKeys: String, CodingKey {
        case hasPosition
        case left
        case top
        case preferredDisplayUUID
        case preferredDisplayOffsetX
        case preferredDisplayOffsetY
        case haloSize
        case alwaysOnTop
        case alwaysOnTopBehaviorVersion
        case paused
        case focusedAgent
        case installedAt
        case acknowledged
        case acknowledgedErrorAt
        case language
    }

    public init(
        hasPosition: Bool = false,
        left: Double = 0,
        top: Double = 0,
        preferredDisplayUUID: String? = nil,
        preferredDisplayOffsetX: Double? = nil,
        preferredDisplayOffsetY: Double? = nil,
        haloSize: Double = HaloSettings.defaultHaloSize,
        alwaysOnTop: Bool = true,
        alwaysOnTopBehaviorVersion: Int = HaloSettings.currentAlwaysOnTopBehaviorVersion,
        paused: Bool = false,
        focusedAgent: AgentKind = .codex,
        installedAt: Date = Date(),
        acknowledged: [String: Date] = [:],
        acknowledgedErrorAt: Date? = nil,
        language: String? = nil
    ) {
        self.hasPosition = hasPosition
        self.left = left
        self.top = top
        self.preferredDisplayUUID = preferredDisplayUUID
        self.preferredDisplayOffsetX = preferredDisplayOffsetX
        self.preferredDisplayOffsetY = preferredDisplayOffsetY
        self.haloSize = Self.clampedHaloSize(haloSize)
        self.alwaysOnTop = alwaysOnTop
        self.alwaysOnTopBehaviorVersion = alwaysOnTopBehaviorVersion
        self.paused = paused
        self.focusedAgent = focusedAgent
        self.installedAt = installedAt
        self.acknowledged = acknowledged
        self.acknowledgedErrorAt = acknowledgedErrorAt
        self.language = language
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasPosition = try container.decodeIfPresent(Bool.self, forKey: .hasPosition) ?? false
        self.left = try container.decodeIfPresent(Double.self, forKey: .left) ?? 0
        self.top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 0
        self.preferredDisplayUUID = try container.decodeIfPresent(String.self, forKey: .preferredDisplayUUID)
        self.preferredDisplayOffsetX = try container.decodeIfPresent(Double.self, forKey: .preferredDisplayOffsetX)
        self.preferredDisplayOffsetY = try container.decodeIfPresent(Double.self, forKey: .preferredDisplayOffsetY)
        self.haloSize = Self.clampedHaloSize(
            try container.decodeIfPresent(Double.self, forKey: .haloSize) ?? Self.defaultHaloSize
        )
        self.alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true
        self.alwaysOnTopBehaviorVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .alwaysOnTopBehaviorVersion
        ) ?? 0
        self.paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        self.focusedAgent = try container.decodeIfPresent(AgentKind.self, forKey: .focusedAgent) ?? .codex
        self.installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        self.acknowledged = try container.decodeIfPresent([String: Date].self, forKey: .acknowledged) ?? [:]
        self.acknowledgedErrorAt = try container.decodeIfPresent(Date.self, forKey: .acknowledgedErrorAt)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
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

    public func acknowledgingError(at eventAt: Date) -> HaloSettings {
        var next = self
        if eventAt > (next.acknowledgedErrorAt ?? .distantPast) {
            next.acknowledgedErrorAt = eventAt
        }
        return next
    }

    public func shouldShowError(eventAt: Date) -> Bool {
        eventAt > (acknowledgedErrorAt ?? .distantPast)
    }

    public static func clampedHaloSize(_ size: Double) -> Double {
        min(maximumHaloSize, max(minimumHaloSize, size))
    }
}

public struct SettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL = SettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
    }

    public func load(now: Date = Date()) -> HaloSettings {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return HaloSettings(installedAt: now)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if var settings = try? decoder.decode(HaloSettings.self, from: data) {
            if settings.alwaysOnTopBehaviorVersion < HaloSettings.currentAlwaysOnTopBehaviorVersion {
                settings.alwaysOnTop = true
                settings.alwaysOnTopBehaviorVersion = HaloSettings.currentAlwaysOnTopBehaviorVersion
                save(settings)
            }
            settings.paused = false
            return settings
        }
        AgentHaloLogger.log("Settings load failed: could not decode \(settingsURL.path)")
        return HaloSettings(installedAt: now)
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
