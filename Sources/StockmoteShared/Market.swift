import Foundation

/// Symbols. Internally we use Yahoo's spelling for European stocks
/// ("NOVO-B.CO") and Nasdaq's for US ones ("BRK.B").
public enum Symbols {
    /// Yahoo's exchange suffixes for the exchanges Stockmote knows: the European
    /// indices', and those of the rest of the world where stocks in global funds
    /// are listed (Tokyo, Toronto, Sydney, Hong Kong …).
    private static let exchangeSuffixes: Set<String> = [
        "CO", "DE", "F", "PA", "L", "ST", "OL", "HE", "SW", "AS", "MI", "MC", "BR", "VI", "IR", "LS",
        "T", "TO", "V", "AX", "HK", "KS", "KQ", "TW", "TWO", "SI", "NZ", "SA", "JO", "TA", "SS", "SZ",
        "NS", "BO", "WA", "IS", "PR", "AT", "MU", "DU", "BE", "SG", "HM", "HA", "MX", "BD", "XC", "XD", "AQ", "IL", "NE"
    ]

    /// A stock on an exchange outside the US, recognised by its suffix.
    public static func isForeign(_ symbol: String) -> Bool {
        guard let dot = symbol.lastIndex(of: ".") else { return false }
        return exchangeSuffixes.contains(String(symbol[symbol.index(after: dot)...]))
    }

    /// What Yahoo wants: US share classes with a hyphen
    /// ("BRK-B"), everything else as is.
    public static func yahoo(_ symbol: String) -> String {
        if symbol.hasPrefix("^") || symbol.contains("=") || isForeign(symbol) { return symbol }
        return symbol.replacingOccurrences(of: ".", with: "-")
    }

    /// What's shown on the tile: "NOVO B" rather than "NOVO-B.CO".
    public static func display(_ symbol: String) -> String {
        // A fund priced by its daily NAV (see FundNAV) has no ticker.
        if symbol.hasPrefix("NAV:") { return "NAV" }
        guard isForeign(symbol), let dot = symbol.lastIndex(of: ".") else { return symbol }
        return String(symbol[..<dot]).replacingOccurrences(of: "-", with: " ")
    }
}

/// An exchange's trading hours in its own time zone. Holidays aren't known — on
/// those the app thinks the exchange is open and refreshes a bit too often. That's harmless.
public struct MarketHours: Hashable, Codable {
    public let timezone: String
    public let open: String
    public let close: String

    public init(timezone: String, open: String, close: String) {
        self.timezone = timezone
        self.open = open
        self.close = close
    }

    public static let newYork = MarketHours(timezone: "America/New_York", open: "09:30", close: "16:00")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar
    }

    private static func minutes(_ text: String) -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return (parts.first ?? 0) * 60 + (parts.count > 1 ? parts[1] : 0)
    }

    public func isOpen(at date: Date = Date()) -> Bool {
        let calendar = calendar
        guard (2...6).contains(calendar.component(.weekday, from: date)) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return now >= Self.minutes(open) && now < Self.minutes(close)
    }

    public func nextOpen(after date: Date = Date()) -> Date? {
        let calendar = calendar
        let start = Self.minutes(open)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            if let candidate = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
               candidate > date, (2...6).contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return nil
    }

    /// "Åben · lukker 17.30" or "Lukket · åbner man. 09.00", in local time.
    public var statusText: String {
        let formatter = DateFormatter()
        formatter.locale = Lang.locale
        if isOpen() {
            let close = Self.minutes(self.close)
            if let closing = calendar.date(bySettingHour: close / 60, minute: close % 60, second: 0, of: Date()) {
                formatter.dateFormat = "HH.mm"
                return tr("Åben · lukker \(formatter.string(from: closing))", "Open · closes \(formatter.string(from: closing))")
            }
            return tr("Åben", "Open")
        }
        guard let open = nextOpen() else { return tr("Lukket", "Closed") }
        if Calendar.current.isDateInToday(open) {
            formatter.dateFormat = Lang.isEnglish ? "'today' HH.mm" : "'i dag' HH.mm"
        } else if Calendar.current.isDateInTomorrow(open) {
            formatter.dateFormat = Lang.isEnglish ? "'tomorrow' HH.mm" : "'i morgen' HH.mm"
        } else {
            formatter.dateFormat = "EEE HH.mm"
        }
        return tr("Lukket · åbner \(formatter.string(from: open))", "Closed · opens \(formatter.string(from: open))")
    }
}

/// Currencies: symbol for display and Yahoo symbol for conversion to dollars.
public enum Currency {
    /// Rates used until Yahoo has answered. Only for tile size, so they
    /// needn't be precise.
    private static let fallback: [String: Double] = [
        "USD": 1, "EUR": 1.10, "DKK": 0.148, "GBP": 1.30, "SEK": 0.095,
        "NOK": 0.090, "CHF": 1.15
    ]

    /// The Yahoo symbols for the currencies that occur.
    public static let yahooSymbols = ["EURUSD=X", "DKKUSD=X", "GBPUSD=X", "SEKUSD=X", "NOKUSD=X", "CHFUSD=X"]

    /// How many dollars one unit is worth. GBp (pence) is a hundredth of a pound.
    public static func toUSD(_ currency: String?, rates: [String: Double]) -> Double {
        guard let currency else { return 1 }
        if currency == "GBp" || currency == "GBX" { return toUSD("GBP", rates: rates) / 100 }
        if currency == "USD" { return 1 }
        return rates["\(currency)USD=X"] ?? fallback[currency] ?? 1
    }

    public static func symbol(_ currency: String?) -> String {
        switch currency ?? "USD" {
        case "USD": return "$"
        case "EUR": return "€"
        case "DKK": return "kr."
        case "SEK", "NOK": return "kr"
        case "GBP": return "£"
        case "GBp", "GBX": return "p"
        case "CHF": return "CHF"
        case "JPY": return "¥"
        case "ZAc": return "ZAc"
        default: return currency ?? ""
        }
    }
}
