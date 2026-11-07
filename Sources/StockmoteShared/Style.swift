import AppKit
import SwiftUI

// MARK: - Tidsrum

public enum Period: String, CaseIterable, Identifiable, Codable {
    // rawValue er nøglen i UserDefaults og må ikke ændres. Teksten står i label.
    case day = "1D"
    case week = "1U"
    case month = "1M"
    case quarter = "3M"
    case ytd = "ÅTD"
    case year = "1Å"

    public var id: String { rawValue }

    /// Den korte etiket: "1U" på dansk, "1W" på engelsk.
    public var label: String {
        switch self {
        case .day: return "1D"
        case .week: return tr("1U", "1W")
        case .month: return "1M"
        case .quarter: return "3M"
        case .ytd: return tr("ÅTD", "YTD")
        case .year: return tr("1Å", "1Y")
        }
    }

    public var longName: String {
        switch self {
        case .day: return tr("1 dag", "1 day")
        case .week: return tr("1 uge", "1 week")
        case .month: return tr("1 måned", "1 month")
        case .quarter: return tr("3 måneder", "3 months")
        case .ytd: return tr("År til dato", "Year to date")
        case .year: return tr("1 år", "1 year")
        }
    }

    /// Yahoo's `range`. `chartPreviousClose` i svaret er lukkekursen lige før
    /// tidsrummet starter, så ændringen er kurs / chartPreviousClose − 1.
    public var yahooRange: String {
        switch self {
        case .day: return "1d"
        case .week: return "5d"
        case .month: return "1mo"
        case .quarter: return "3mo"
        case .ytd: return "ytd"
        case .year: return "1y"
        }
    }

    /// Vi læser kun `meta`, så intervallet vælges for at holde svaret lille.
    public var yahooInterval: String {
        switch self {
        case .day, .week, .month: return "1d"
        case .quarter, .ytd, .year: return "1wk"
        }
    }

    /// Den ændring i procent der giver fuld farve. 3 % er meget på en dag men
    /// ingenting over et år, så skalaen følger tidsrummet.
    public var colorScale: Double {
        switch self {
        case .day: return 3
        case .week: return 6
        case .month: return 10
        case .quarter: return 15
        case .ytd: return 25
        case .year: return 35
        }
    }
}

public enum ColorStyle: String, CaseIterable, Identifiable {
    case redGreen, blueOrange
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .redGreen: return tr("Rød / grøn", "Red / green")
        case .blueOrange: return tr("Orange / blå", "Orange / blue")
        }
    }
}

// MARK: - Tema

public enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return tr("Som systemet", "System")
        case .light: return tr("Lyst", "Light")
        case .dark: return tr("Mørkt", "Dark")
        }
    }
}

/// Farverne på selve kortet. Panelets øvrige flader følger macOS' udseende via
/// `Palette`; kortet tegnes i en Canvas og får temaet med eksplicit.
///
/// Det lyse tema er ikke det mørke vendt om. Fugerne er hvide, så felterne
/// står som fliser på papir, og neutral er lysegrå med mørk tekst — hvid tekst
/// på lysegrå kan ikke læses. Teksten vælges derfor efter feltets lyshed.
public struct Theme: Equatable {
    public typealias RGB = (r: Double, g: Double, b: Double)

    public let isDark: Bool

    public static let dark = Theme(isDark: true)
    public static let light = Theme(isDark: false)

    public init(isDark: Bool) { self.isDark = isDark }

    public static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.isDark == rhs.isDark }

    /// Fugerne mellem felterne.
    public var gap: Color { isDark ? .black : Color(white: 0.985) }
    public var sectorHeader: Color { isDark ? Color(white: 0.17) : Color(.sRGB, red: 0.88, green: 0.89, blue: 0.92) }
    public var sectorText: Color { isDark ? .white : Color(white: 0.08) }
    public var industryHeader: Color { isDark ? Color(white: 0.10) : Color(.sRGB, red: 0.94, green: 0.945, blue: 0.96) }
    public var industryText: Color { isDark ? Color(white: 0.86) : Color(white: 0.30) }
    public var highlight: Color { isDark ? .white : Color(white: 0.05) }

    var neutral: RGB { isDark ? (0.255, 0.271, 0.329) : (0.70, 0.72, 0.77) }
    var missing: RGB { isDark ? (0.20, 0.20, 0.22) : (0.86, 0.865, 0.88) }

    func ends(_ style: ColorStyle) -> (up: RGB, down: RGB) {
        switch (style, isDark) {
        case (.redGreen, true): return ((0.188, 0.800, 0.353), (0.965, 0.208, 0.220))
        case (.redGreen, false): return ((0.07, 0.66, 0.31), (0.90, 0.17, 0.20))
        // Til rød-grøn farveblindhed: blå op, orange ned.
        case (.blueOrange, true): return ((0.20, 0.52, 0.98), (0.98, 0.56, 0.12))
        case (.blueOrange, false): return ((0.10, 0.42, 0.92), (0.95, 0.50, 0.05))
        }
    }
}

/// Farveskalaen. Neutral grå i midten, fuld farve ved `scale` procent.
public enum Heat {
    public static func rgb(_ change: Double?, scale: Double, style: ColorStyle, theme: Theme = .dark) -> Theme.RGB {
        guard let change, change.isFinite else { return theme.missing }
        let (up, down) = theme.ends(style)
        let target = change >= 0 ? up : down
        let neutral = theme.neutral
        // Lidt hurtigere ud af det grå end lineært, så små bevægelser kan ses.
        let t = pow(min(abs(change) / scale, 1), 0.75)
        return (neutral.r + (target.r - neutral.r) * t,
                neutral.g + (target.g - neutral.g) * t,
                neutral.b + (target.b - neutral.b) * t)
    }

    public static func color(_ change: Double?, scale: Double, style: ColorStyle, theme: Theme = .dark) -> Color {
        let c = rgb(change, scale: scale, style: style, theme: theme)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// Hvid tekst på mørke felter, næsten sort på lyse.
    public static func label(on change: Double?, scale: Double, style: ColorStyle, theme: Theme) -> Color {
        let c = rgb(change, scale: scale, style: style, theme: theme)
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return luminance > (theme.isDark ? 0.75 : 0.50) ? Color(white: 0.1) : .white
    }

    /// Tekstfarve for et tal: grøn/rød (eller blå/orange) i fuld styrke.
    public static func textColor(_ change: Double?, style: ColorStyle, theme: Theme = .dark) -> Color {
        guard let change, change != 0 else { return .secondary }
        let (up, down) = theme.ends(style)
        let c = change > 0 ? up : down
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }
}

// MARK: - Tal

public enum Format {
    private static var decimal: String { Lang.isEnglish ? "." : "," }

    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: decimal)
    }

    /// "+3,03%"
    public static func percent(_ value: Double?, digits: Int = 2) -> String {
        guard let value, value.isFinite else { return "–" }
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        return "\(sign)\(number(abs(value), digits: digits))%"
    }

    /// Til menubaren: "▲ 0,42%"
    public static func arrowPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        let arrow = value > 0 ? "▲" : value < 0 ? "▼" : "■"
        return "\(arrow) \(number(abs(value), digits: 2))%"
    }

    /// "182,29 $", "1.234,50 kr.", "$182.29" på engelsk.
    public static func price(_ value: Double?, currency: String? = "USD") -> String {
        guard let value else { return "–" }
        let formatter = NumberFormatter()
        formatter.locale = Lang.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = value < 1 ? 4 : 2
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let symbol = Currency.symbol(currency)
        if Lang.isEnglish, ["$", "€", "£"].contains(symbol) { return symbol + text }
        return "\(text) \(symbol)"
    }

    /// Store tal: dansk 1 bio. = 10¹² og 1 mia. = 10⁹; engelsk T og B.
    public static func marketCap(_ value: Double?) -> String {
        guard let value, value > 0 else { return "–" }
        let (scaled, unit): (Double, String) = value >= 1e12 ? (value / 1e12, tr("bio.", "T"))
            : value >= 1e9 ? (value / 1e9, tr("mia.", "B")) : (value / 1e6, tr("mio.", "M"))
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return Lang.isEnglish ? "$\(number(scaled, digits: digits))\(unit)" : "\(number(scaled, digits: digits)) \(unit) $"
    }

    /// "1.276" på dansk, "1,276" på engelsk.
    public static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Lang.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Vægt i en fond: "5,79%" — med flere decimaler for de små.
    public static func weight(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(number(value, digits: value < 0.1 ? 3 : 2))%"
    }

    public static func time(_ date: Date?) -> String {
        guard let date else { return "–" }
        let formatter = DateFormatter()
        formatter.locale = Lang.locale
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH.mm" : (Lang.isEnglish ? "MMM d HH.mm" : "d. MMM HH.mm")
        return formatter.string(from: date)
    }
}

// MARK: - Panelets flader

/// Farver der følger macOS' udseende — lyst eller mørkt — af sig selv, fordi
/// de er dynamiske NSColors. Panelets NSHostingView får det valgte udseende,
/// og så skifter alt med.
public enum Palette {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func gray(_ white: CGFloat) -> NSColor { NSColor(white: white, alpha: 1) }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Bag kortet og toppen.
    public static let background = dynamic(dark: gray(0.0), light: gray(0.985))
    /// Sidebjælken.
    public static let sidebar = dynamic(dark: gray(0.075), light: rgb(0.935, 0.94, 0.95))
    /// Kort, tooltips, felter i indstillinger.
    public static let surface = dynamic(dark: gray(0.11), light: gray(1.0))
    /// Knapper og søgefelter.
    public static let raised = dynamic(dark: gray(0.17), light: rgb(0.90, 0.905, 0.92))
    public static let hover = dynamic(dark: gray(0.24), light: rgb(0.84, 0.85, 0.87))
    public static let separator = dynamic(dark: gray(0.18), light: rgb(0.86, 0.87, 0.89))
    /// Kanten om tooltip og kort i det lyse tema; næsten usynlig i det mørke.
    public static let outline = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.10))
}
