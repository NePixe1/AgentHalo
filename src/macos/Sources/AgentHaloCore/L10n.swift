import Foundation

public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    public static let languageDidChange = Notification.Name("L10n.languageDidChange")

    private static let supportedLanguages = ["zh", "en"]
    private static let fallbackLanguage = "zh"

    private var translations: [String: String] = [:]
    private var _currentLanguage: String = L10n.fallbackLanguage

    public var currentLanguage: String { _currentLanguage }

    private init() {
        // Load fallback translations eagerly so call sites work even before
        // someone explicitly calls setLanguage() (e.g. command-line tools that
        // never wire up settings).
        loadTranslations()
    }

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
        if let value = translations[key] {
            return value
        }
        #if DEBUG
        NSLog("[L10n] missing translation for key: %@", key)
        #endif
        return key
    }

    /// Replace `{0}`, `{1}`, ... placeholders in the looked-up template with
    /// the supplied arguments. Uses a single pass over the template so an
    /// argument value containing `{1}` cannot be re-rewritten by a later
    /// substitution.
    public func format(_ key: String, _ args: CVarArg...) -> String {
        let template = self[key]
        guard !args.isEmpty else { return template }
        let stringArgs = args.map { "\($0)" }
        var result = ""
        result.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            if ch == "{" {
                // Look ahead for `{digits}` — emit replacement if it matches and
                // the index is in range, otherwise pass the brace through verbatim.
                var cursor = template.index(after: index)
                var digits = ""
                while cursor < template.endIndex, let scalar = template[cursor].asciiValue,
                      scalar >= 0x30 && scalar <= 0x39 {
                    digits.append(template[cursor])
                    cursor = template.index(after: cursor)
                }
                if !digits.isEmpty, cursor < template.endIndex, template[cursor] == "}",
                   let position = Int(digits), position >= 0, position < stringArgs.count {
                    result.append(stringArgs[position])
                    index = template.index(after: cursor)
                    continue
                }
            }
            result.append(ch)
            index = template.index(after: index)
        }
        return result
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
