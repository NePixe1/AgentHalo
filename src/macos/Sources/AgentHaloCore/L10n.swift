import Foundation

public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    public static let languageDidChange = Notification.Name("L10n.languageDidChange")

    private static let supportedLanguages = ["zh", "en"]
    private static let fallbackLanguage = "zh"

    private var translations: [String: String] = [:]
    private var _currentLanguage: String = L10n.fallbackLanguage

    public var currentLanguage: String { _currentLanguage }

    private init() {}

    // MARK: - Configuration

    /// Configure language. Pass `nil` to follow the system language.
    /// Call this early in app startup, after loading settings.
    public func setLanguage(_ lang: String?) {
        let resolved = Self.resolveLanguage(lang)
        guard resolved != _currentLanguage else { return }
        _currentLanguage = resolved
        loadTranslations()
        NotificationCenter.default.post(name: Self.languageDidChange, object: self)
    }

    // MARK: - Public API

    public subscript(_ key: String) -> String {
        translations[key] ?? key
    }

    public func format(_ key: String, _ args: CVarArg...) -> String {
        let template = self[key]
        return String(format: template, arguments: args)
    }

    // MARK: - System language detection

    public static func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? ""
        // Extract language code (e.g. "zh-Hans-CN" → "zh", "en-US" → "en")
        if let languageCode = preferred.split(separator: "-").first.map(String.init) {
            let normalized = languageCode.lowercased()
            if supportedLanguages.contains(normalized) {
                return normalized
            }
        }
        return fallbackLanguage
    }

    // MARK: - Private

    private static func resolveLanguage(_ explicit: String?) -> String {
        if let lang = explicit, supportedLanguages.contains(lang) {
            return lang
        }
        return detectSystemLanguage()
    }

    private func loadTranslations() {
        guard let url = Bundle.module.url(
            forResource: _currentLanguage,
            withExtension: "json",
            subdirectory: "locales"
        ) else {
            // Fallback: try loading the fallback language
            if _currentLanguage != Self.fallbackLanguage,
               let fallbackURL = Bundle.module.url(
                forResource: Self.fallbackLanguage,
                withExtension: "json",
                subdirectory: "locales"
               ) {
                translations = Self.parseJSON(at: fallbackURL)
                return
            }
            translations = [:]
            return
        }
        translations = Self.parseJSON(at: url)
    }

    private static func parseJSON(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }
}
