import Foundation

/// Sprogvalget i indstillingerne.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, danish, english
    public var id: String { rawValue }

    /// Navnet på sproget på sproget selv, så man kan finde tilbage fra et
    /// sprog man ikke forstår.
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

/// Det aktive sprog. Sættes af appen ved start og når indstillingen skifter,
/// og af widget'en ud fra den delte fil.
///
/// Teksterne står som par direkte i koden — `tr("Opdatér", "Refresh")` —
/// frem for i .strings-filer. Det er to sprog, og sproget skal kunne skiftes
/// mens appen kører, uden genstart. Bundle-lokalisering følger systemets sprog
/// og kan ikke det.
public enum Lang {
    public static var isEnglish = false

    public static var locale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "da_DK")
    }
}

/// Dansk eller engelsk tekst, efter det aktive sprog.
public func tr(_ danish: String, _ english: String) -> String {
    Lang.isEnglish ? english : danish
}
