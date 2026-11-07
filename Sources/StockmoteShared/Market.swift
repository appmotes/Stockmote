import Foundation

/// Symboler. Internt bruges Yahoo's skrivemåde for europæiske aktier
/// ("NOVO-B.CO") og Nasdaq's for amerikanske ("BRK.B").
public enum Symbols {
    /// Yahoo's børs-suffikser for de børser Stockmote kender.
    private static let exchangeSuffixes: Set<String> = [
        "CO", "DE", "F", "PA", "L", "ST", "OL", "HE", "SW", "AS", "MI", "MC", "BR", "VI", "IR", "LS"
    ]

    /// En aktie på en europæisk børs, kendt på suffikset.
    public static func isForeign(_ symbol: String) -> Bool {
        guard let dot = symbol.lastIndex(of: ".") else { return false }
        return exchangeSuffixes.contains(String(symbol[symbol.index(after: dot)...]))
    }

    /// Det Yahoo vil have: amerikanske klasse-aktier med bindestreg
    /// ("BRK-B"), alt andet som det er.
    public static func yahoo(_ symbol: String) -> String {
        if symbol.hasPrefix("^") || symbol.contains("=") || isForeign(symbol) { return symbol }
        return symbol.replacingOccurrences(of: ".", with: "-")
    }

    /// Det der står på feltet: "NOVO B" frem for "NOVO-B.CO".
    public static func display(_ symbol: String) -> String {
        guard isForeign(symbol), let dot = symbol.lastIndex(of: ".") else { return symbol }
        return String(symbol[..<dot]).replacingOccurrences(of: "-", with: " ")
    }
}

/// En børs' åbningstid i dens egen tidszone. Helligdage kendes ikke — på dem
/// tror appen at børsen er åben og opdaterer lidt for tit. Det er ufarligt.
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

    /// "Åben · lukker 17.30" eller "Lukket · åbner man. 09.00", i lokal tid.
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

/// Valutaer: tegn til visning og Yahoo-symbol til omregning til dollar.
public enum Currency {
    /// Kurser der bruges indtil Yahoo har svaret. Kun til feltstørrelse, så
    /// de behøver ikke være præcise.
    private static let fallback: [String: Double] = [
        "USD": 1, "EUR": 1.10, "DKK": 0.148, "GBP": 1.30, "SEK": 0.095,
        "NOK": 0.090, "CHF": 1.15
    ]

    /// Yahoo-symbolerne for de valutaer der optræder.
    public static let yahooSymbols = ["EURUSD=X", "DKKUSD=X", "GBPUSD=X", "SEKUSD=X", "NOKUSD=X", "CHFUSD=X"]

    /// Hvor mange dollar én enhed er værd. GBp (pence) er en hundrededel pund.
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
        default: return currency ?? ""
        }
    }
}
