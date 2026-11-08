import AppKit
import SwiftUI

// MARK: - Time ranges

public enum Period: String, CaseIterable, Identifiable, Codable {
    // rawValue is the key in UserDefaults and must not change. The text lives in label.
    case day = "1D"
    case week = "1U"
    case month = "1M"
    case quarter = "3M"
    case halfYear = "6M"
    case ytd = "ÅTD"
    case year = "1Å"
    case threeYears = "3Å"
    case fiveYears = "5Å"
    case all = "Alt"

    public var id: String { rawValue }

    /// The short label: "1U" in Danish, "1W" in English.
    public var label: String {
        switch self {
        case .day: return "1D"
        case .week: return tr("1U", "1W")
        case .month: return "1M"
        case .quarter: return "3M"
        case .halfYear: return "6M"
        case .ytd: return tr("ÅTD", "YTD")
        case .year: return tr("1Å", "1Y")
        case .threeYears: return tr("3Å", "3Y")
        case .fiveYears: return tr("5Å", "5Y")
        case .all: return tr("Alt", "All")
        }
    }

    public var longName: String {
        switch self {
        case .day: return tr("1 dag", "1 day")
        case .week: return tr("1 uge", "1 week")
        case .month: return tr("1 måned", "1 month")
        case .quarter: return tr("3 måneder", "3 months")
        case .halfYear: return tr("6 måneder", "6 months")
        case .ytd: return tr("År til dato", "Year to date")
        case .year: return tr("1 år", "1 year")
        case .threeYears: return tr("3 år", "3 years")
        case .fiveYears: return tr("5 år", "5 years")
        case .all: return tr("Hele historikken", "All time")
        }
    }

    /// Yahoo's `range`. `chartPreviousClose` in the response is the close just before
    /// the range starts, so the change is price / chartPreviousClose − 1. With
    /// `max` it is the first price Yahoo has for the symbol (checked: ^GSPC gives
    /// 17.66, its price at the end of 1927).
    ///
    /// Yahoo has no documented 3-year range ("3y" happens to be accepted, but
    /// isn't in the `validRanges` it lists), so 3Å reads the daily closes over
    /// 5 years and takes the close on or just before the day three years ago
    /// (see `Yahoo.fetch`).
    public var yahooRange: String {
        switch self {
        case .day: return "1d"
        case .week: return "5d"
        case .month: return "1mo"
        case .quarter: return "3mo"
        case .halfYear: return "6mo"
        case .ytd: return "ytd"
        case .year: return "1y"
        case .threeYears, .fiveYears: return "5y"
        case .all: return "max"
        }
    }

    /// We only read `meta`, so the interval is chosen to keep the response small —
    /// except for 3Å, whose figure comes from the daily closes themselves.
    public var yahooInterval: String {
        switch self {
        case .day, .week, .month, .threeYears: return "1d"
        case .quarter, .halfYear, .ytd, .year: return "1wk"
        case .fiveYears: return "1mo"
        case .all: return "3mo"
        }
    }

    /// True when the change is measured from a close found in the series
    /// (3Å), not from Yahoo's `chartPreviousClose`.
    public var baseFromSeries: Bool { self == .threeYears }

    /// When the range starts: the base date the change is measured from. Nil
    /// for 1D (yesterday's close, whenever that was) and for Alt, which starts
    /// at each symbol's first price.
    public func start(now: Date = Date()) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        switch self {
        case .day, .all: return nil
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .halfYear: return calendar.date(byAdding: .month, value: -6, to: now)
        case .ytd: return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .threeYears: return calendar.date(byAdding: .year, value: -3, to: now)
        case .fiveYears: return calendar.date(byAdding: .year, value: -5, to: now)
        }
    }

    /// The change that gives full colour. 3 % is a lot in a day but nothing
    /// over five years, so the scale follows the time range.
    ///
    /// Alt is logarithmic: since the first price, Apple is up some 270,000 %
    /// and the S&P 500 40,000 %, while a stock listed last year may be at
    /// +30 %. On a linear scale every tile would be full colour. Measured in
    /// growth factors instead, full colour is ×100 up (+9,900 %) — ×2 is a
    /// quarter of the way, ×10 a little over half — and ÷10 down (−90 %),
    /// since a loss can't go below −100 %.
    public var colorScale: ColorScale {
        switch self {
        case .day: return 3
        case .week: return 6
        case .month: return 10
        case .quarter: return 15
        case .halfYear: return 20
        case .ytd: return 25
        case .year: return 35
        case .threeYears: return 50
        case .fiveYears: return 80
        case .all: return ColorScale(full: 9_900, fullDown: 90, logarithmic: true)
        }
    }
}

/// How a change maps to colour strength: full colour at `full` percent up
/// and `fullDown` percent down. Logarithmic scales measure the growth factor
/// (1 + change/100), so ×2 is as far from ×1 as ×4 is from ×2.
public struct ColorScale: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, Sendable {
    public let full: Double
    public let fullDown: Double
    public let logarithmic: Bool

    public init(full: Double, fullDown: Double? = nil, logarithmic: Bool = false) {
        self.full = full
        self.fullDown = fullDown ?? full
        self.logarithmic = logarithmic
    }
    public init(integerLiteral value: Int) { self.init(full: Double(value)) }
    public init(floatLiteral value: Double) { self.init(full: value) }

    /// 0 … 1: how far from neutral towards full colour.
    public func strength(_ change: Double) -> Double {
        let limit = change >= 0 ? full : fullDown
        guard logarithmic else { return min(abs(change) / limit, 1) }
        let factor = max(1 + change / 100, 1e-6)
        let end = change >= 0 ? 1 + limit / 100 : 1 - min(limit, 99.99) / 100
        return min(abs(log(factor)) / abs(log(end)), 1)
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

// MARK: - Theme

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

/// The colours of the map itself. The window's other surfaces follow macOS's
/// appearance via `Palette`; the map is drawn in a Canvas and gets the theme explicitly.
///
/// The light theme isn't the dark one inverted. The gaps are white, so the
/// tiles read like squares on paper, and neutral is light grey with dark text —
/// white text on light grey is unreadable. So the text colour follows the tile's lightness.
public struct Theme: Equatable {
    public typealias RGB = (r: Double, g: Double, b: Double)

    public let isDark: Bool

    public static let dark = Theme(isDark: true)
    public static let light = Theme(isDark: false)

    public init(isDark: Bool) { self.isDark = isDark }

    public static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.isDark == rhs.isDark }

    /// The gaps between the tiles.
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
        // For red-green colour blindness: blue up, orange down.
        case (.blueOrange, true): return ((0.20, 0.52, 0.98), (0.98, 0.56, 0.12))
        case (.blueOrange, false): return ((0.10, 0.42, 0.92), (0.95, 0.50, 0.05))
        }
    }
}

/// The colour scale. Neutral grey in the middle, full colour at `scale` percent.
public enum Heat {
    public static func rgb(_ change: Double?, scale: ColorScale, style: ColorStyle, theme: Theme = .dark) -> Theme.RGB {
        guard let change, change.isFinite else { return theme.missing }
        let (up, down) = theme.ends(style)
        let target = change >= 0 ? up : down
        let neutral = theme.neutral
        // Leaves the grey a little faster than linear, so small moves are visible.
        let t = pow(scale.strength(change), 0.75)
        return (neutral.r + (target.r - neutral.r) * t,
                neutral.g + (target.g - neutral.g) * t,
                neutral.b + (target.b - neutral.b) * t)
    }

    public static func color(_ change: Double?, scale: ColorScale, style: ColorStyle, theme: Theme = .dark) -> Color {
        let c = rgb(change, scale: scale, style: style, theme: theme)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// White text on dark tiles, near-black on light ones.
    public static func label(on change: Double?, scale: ColorScale, style: ColorStyle, theme: Theme) -> Color {
        let c = rgb(change, scale: scale, style: style, theme: theme)
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return luminance > (theme.isDark ? 0.75 : 0.50) ? Color(white: 0.1) : .white
    }

    /// Text colour for a figure: green/red (or blue/orange) at full strength.
    public static func textColor(_ change: Double?, style: ColorStyle, theme: Theme = .dark) -> Color {
        guard let change, change != 0 else { return .secondary }
        let (up, down) = theme.ends(style)
        let c = change > 0 ? up : down
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }
}

// MARK: - Numbers

public enum Format {
    private static var decimal: String { Lang.isEnglish ? "." : "," }

    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: decimal)
    }

    /// "+3,03%". Large changes (Alt, 5Å) keep the label short: one decimal
    /// from 100 %, none and thousands grouped from 1,000 % ("+9.439%" in
    /// Danish, "+9,439%" in English), and thousands as K from 10,000 %
    /// ("+41,7K%", "+424K%") and millions as M ("+1,1M%").
    public static func percent(_ value: Double?, digits: Int = 2) -> String {
        guard let value, value.isFinite else { return "–" }
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        let size = abs(value)
        if size >= 999_500 {
            let millions = size / 1_000_000
            return "\(sign)\(number(millions, digits: millions >= 99.95 ? 0 : 1))M%"
        }
        if size >= 9_999.5 {
            let thousands = size / 1000
            return "\(sign)\(number(thousands, digits: thousands >= 99.95 ? 0 : 1))K%"
        }
        if size >= 999.5 { return "\(sign)\(integer(Int(size.rounded())))%" }
        return "\(sign)\(number(size, digits: size >= 99.95 ? min(digits, 1) : digits))%"
    }

    /// Short, for the period picker: one decimal under 100 %, none above —
    /// "+8,4%", "+124%", "+41.672%".
    public static func shortPercent(_ value: Double?) -> String {
        guard let value, value.isFinite, abs(value) >= 99.95 else { return percent(value, digits: 1) }
        return percent(value, digits: 0)
    }

    /// For the menu bar: "▲ 0,42%"
    public static func arrowPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        let arrow = value > 0 ? "▲" : value < 0 ? "▼" : "■"
        return "\(arrow) \(number(abs(value), digits: 2))%"
    }

    /// "182,29 $", "1.234,50 kr.", "$182.29" in English.
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

    /// Large numbers: Danish 1 bio. = 10¹² and 1 mia. = 10⁹; English T and B.
    public static func marketCap(_ value: Double?) -> String {
        guard let value, value > 0 else { return "–" }
        let (scaled, unit): (Double, String) = value >= 1e12 ? (value / 1e12, tr("bio.", "T"))
            : value >= 1e9 ? (value / 1e9, tr("mia.", "B")) : (value / 1e6, tr("mio.", "M"))
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return Lang.isEnglish ? "$\(number(scaled, digits: digits))\(unit)" : "\(number(scaled, digits: digits)) \(unit) $"
    }

    /// "1.276" in Danish, "1,276" in English.
    public static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Lang.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Weight in a fund: "5,79%" — with more decimals for the small ones.
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

// MARK: - Window surfaces

/// Colours that follow macOS's appearance — light or dark — on their own, because
/// they're dynamic NSColors. The windows get the chosen appearance,
/// and everything follows.
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

    /// Behind the map and the top bar.
    public static let background = dynamic(dark: gray(0.0), light: gray(0.985))
    /// The sidebar.
    public static let sidebar = dynamic(dark: gray(0.075), light: rgb(0.935, 0.94, 0.95))
    /// Cards, tooltips, fields in settings.
    public static let surface = dynamic(dark: gray(0.11), light: gray(1.0))
    /// Buttons and search fields.
    public static let raised = dynamic(dark: gray(0.17), light: rgb(0.90, 0.905, 0.92))
    public static let hover = dynamic(dark: gray(0.24), light: rgb(0.84, 0.85, 0.87))
    public static let separator = dynamic(dark: gray(0.18), light: rgb(0.86, 0.87, 0.89))
    /// The border around tooltips and cards in the light theme; nearly invisible in the dark one.
    public static let outline = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.10))
}
