import Foundation

/// The language choice in settings.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, danish, english
    public var id: String { rawValue }

    /// The language's name in that language, so you can find your way back from
    /// a language you don't understand.
    public var label: String {
        switch self {
        case .system: return tr("Som systemet", "Same as system")
        case .danish: return "Dansk"
        case .english: return "English"
        }
    }

    public var isEnglish: Bool {
        switch self {
        case .danish: return false
        case .english: return true
        case .system:
            return !(Locale.preferredLanguages.first?.lowercased().hasPrefix("da") ?? false)
        }
    }
}

/// The active language. Set by the app at launch and when the setting changes,
/// and by the widget from the shared file.
///
/// The strings sit as pairs right in the code — `tr("Opdatér", "Refresh")` —
/// rather than in .strings files. There are two languages, and the language
/// must be switchable while the app runs, without a restart. Bundle
/// localisation follows the system language and can't do that.
public enum Lang {
    public static var isEnglish = false

    public static var locale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "da_DK")
    }
}

/// Danish or English text, depending on the active language.
public func tr(_ danish: String, _ english: String) -> String {
    Lang.isEnglish ? english : danish
}
