import AppKit
import StockmoteShared
import Foundation

// MARK: - Kurser

/// Én aktie fra Nasdaq's screener. Kurs og ændring herfra kan være en dag
/// gamle — screeneren opdateres ikke løbende — så de bruges kun indtil Yahoo
/// har svaret.
struct Quote: Hashable {
    let symbol: String
    let name: String
    let price: Double?
    let change1D: Double?
    let marketCap: Double?
    let sector: String
    let industry: String
}

struct PeriodSnapshot {
    var changes: [String: Double]
    var fetched: Date
    var symbols: Set<String>
}

enum MarketError: LocalizedError {
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .empty: return "tomt svar"
        }
    }
}

/// Henter kurser.
///
/// To kilder, begge uden API-nøgle:
///
/// - **Yahoo's spark** giver kurs og ændring for alle tidsrum, også 1D, og
///   indeksernes egne tal. Højst 20 symboler pr. kald, så S&P 500 koster 26
///   kald. Fire ad gangen.
/// - **Nasdaq's screener** giver alle ~7000 amerikanske aktier i ét kald (2 MB)
///   med navn, sektor og markedsværdi. Den bruges til feltstørrelse og søgning,
///   og hentes kun hver halve time. Dens kurser halter: målt en fredag viste
///   den torsdagens lukning. Markedsværdien skaleres derfor med Yahoo's kurs.
@MainActor
final class MarketStore: ObservableObject {
    static let shared = MarketStore()

    @Published var period: Period {
        didSet {
            defaults.set(period.rawValue, forKey: Keys.period)
            guard period != oldValue else { return }
            Task { await loadPeriod(period, force: false) }
        }
    }

    @Published private(set) var quotes: [String: Quote] = [:]
    /// Seneste kurs fra Yahoo, uanset tidsrum.
    @Published private(set) var livePrices: [String: Double] = [:]
    @Published private(set) var snapshots: [Period: PeriodSnapshot] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadingPeriod: Period?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    /// Tælles op ved hver ændring i data, så visninger kan genberegne layout.
    @Published private(set) var version = 0

    /// Sat af MenuBarPanel. Mens panelet er åbent og markedet er åbent,
    /// opdateres der oftere.
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            restartLoop()
        }
    }

    private enum Keys {
        static let period = "period"
    }

    private let defaults = AppDefaults.store
    private var screenerFetched: Date?
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        period = Period(rawValue: defaults.string(forKey: Keys.period) ?? "") ?? .day
    }

    // MARK: Opslag

    func quote(_ symbol: String) -> Quote? { quotes[symbol] }

    func price(_ symbol: String) -> Double? {
        livePrices[symbol] ?? quotes[symbol]?.price
    }

    /// Markedsværdi i dollar, skaleret med kursændringen siden kilden.
    ///
    /// Amerikanske aktier: Nasdaq's screener. Europæiske: tallet fra
    /// Indices.json i lokal valuta, omregnet med dagens valutakurs — så en
    /// watchliste med både Novo og Apple får rigtige størrelser.
    func marketCap(_ symbol: String) -> Double? {
        if let quote = quotes[symbol], let cap = quote.marketCap {
            if let live = livePrices[symbol], let old = quote.price, old > 0 {
                return cap * live / old
            }
            return cap
        }
        guard let info = UniverseStore.shared.info[symbol], let cap = info.cap else { return nil }
        var scaled = cap
        if let live = livePrices[symbol], let old = info.capPrice, old > 0 {
            scaled *= live / old
        }
        return scaled * Currency.toUSD(info.capCurrency ?? info.currency, rates: livePrices)
    }

    func currency(_ symbol: String) -> String {
        UniverseStore.shared.info[symbol]?.currency ?? "USD"
    }

    /// Ændringen i procent for et symbol (også "^GSPC") i et tidsrum.
    func change(_ symbol: String, _ period: Period) -> Double? {
        if let value = snapshots[period]?.changes[symbol] { return value }
        // Kun indtil Yahoo har svaret første gang: screenerens tal kan være
        // fra i går.
        if period == .day, snapshots[.day] == nil { return quotes[symbol]?.change1D }
        return nil
    }

    /// Indeksets egen ændring. Yahoo's tal hvis vi har det, ellers et vægtet
    /// gennemsnit af medlemmerne — tæt på, men ikke det officielle tal.
    func indexChange(_ index: MarketIndex, _ period: Period) -> Double? {
        if let value = snapshots[period]?.changes[index.benchmark] { return value }
        var sum = 0.0, weight = 0.0
        for symbol in index.symbols {
            guard let change = change(symbol, period), let cap = marketCap(symbol) else { continue }
            sum += change * cap
            weight += cap
        }
        return weight > 0 ? sum / weight : nil
    }

    /// Navn og klassifikation. Indices.json vinder; aktier udenfor indekserne
    /// (fx tilføjet til en watchliste) får Nasdaq's egen sektor.
    func info(_ symbol: String) -> StockInfo {
        if let info = UniverseStore.shared.info[symbol] { return info }
        if let quote = quotes[symbol] {
            return StockInfo(symbol: symbol, name: Self.cleanName(quote.name),
                             sector: quote.sector, industry: quote.industry)
        }
        return StockInfo(symbol: symbol, name: symbol, sector: tr("Øvrige", "Other"), industry: tr("Øvrige", "Other"))
    }

    /// Søgning til "Tilføj aktie": symboler der starter med teksten først,
    /// derefter navne der indeholder den.
    func search(_ text: String, limit: Int = 8) -> [StockInfo] {
        let query = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return [] }
        var exact: [StockInfo] = [], prefix: [StockInfo] = [], named: [StockInfo] = []
        func consider(_ symbol: String, _ name: String) {
            // "NOVO B" og "NOVO-B.CO" skal begge finde Novo.
            let display = Symbols.display(symbol).uppercased()
            if symbol == query || display == query {
                exact.append(info(symbol))
            } else if symbol.hasPrefix(query) || display.hasPrefix(query) {
                prefix.append(info(symbol))
            } else if name.uppercased().contains(query) {
                named.append(info(symbol))
            }
        }
        for (symbol, quote) in quotes { consider(symbol, quote.name) }
        // Europæiske aktier findes kun i Indices.json.
        for (symbol, info) in UniverseStore.shared.info where quotes[symbol] == nil {
            consider(symbol, info.name)
        }
        let byCap: (StockInfo, StockInfo) -> Bool = {
            (self.marketCap($0.symbol) ?? 0) > (self.marketCap($1.symbol) ?? 0)
        }
        return Array((exact + prefix.sorted(by: byCap) + named.sorted(by: byCap)).prefix(limit))
    }

    // MARK: Opdatering

    func start() {
        guard loop == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartLoop() }
        }
        restartLoop()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isStale(after: self.panelVisible ? 45 : 240) {
                    await self.refresh()
                }
                try? await Task.sleep(for: .seconds(self.nextInterval))
            }
        }
    }

    private func isStale(after seconds: TimeInterval) -> Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > seconds
    }

    /// Hyppigt mens markedet er åbent og panelet er fremme; sjældent ellers.
    /// Lukket marked ændrer sig ikke, så der er ingen grund til at hamre løs.
    private var nextInterval: TimeInterval {
        guard MarketClock.anyOpen() else { return 1800 }
        return panelVisible ? Double(Preferences.shared.refreshSeconds) : 300
    }

    /// Henter alt for det valgte tidsrum. Kaldes af løkken og af ⟳-knappen.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var problems: [String] = []
        let needScreener = quotes.isEmpty
            || Date().timeIntervalSince(screenerFetched ?? .distantPast) > 1800
        if needScreener {
            do {
                quotes = try await Self.fetchNasdaq()
                screenerFetched = Date()
                version += 1
            } catch {
                problems.append(tr("Nasdaq svarede ikke (\(error.localizedDescription)).",
                                   "Nasdaq did not answer (\(error.localizedDescription))."))
            }
        }

        if let problem = await loadPeriod(.day, force: true) { problems.append(problem) }
        if period != .day, let problem = await loadPeriod(period, force: true) { problems.append(problem) }
        if snapshots[.day] != nil || !quotes.isEmpty { lastUpdated = Date() }

        errorMessage = problems.isEmpty ? nil : problems.joined(separator: " ")
        version += 1
    }

    /// Henter Yahoo-data for et tidsrum, hvis de mangler eller er forældede.
    /// Returnerer en fejlbesked, eller nil.
    @discardableResult
    func loadPeriod(_ period: Period, force: Bool) async -> String? {
        let wanted = wantedSymbols(for: period)
        if !force, let snapshot = snapshots[period],
           Date().timeIntervalSince(snapshot.fetched) < 600,
           wanted.isSubset(of: snapshot.symbols) {
            return nil
        }
        loadingPeriod = period
        defer { if loadingPeriod == period { loadingPeriod = nil } }

        let result = await Yahoo.fetch(Array(wanted), period: period)
        guard !result.isEmpty else {
            version += 1
            let message = tr("Yahoo svarede ikke — \(period.longName) mangler.",
                             "Yahoo did not answer — \(period.longName) is missing.")
            if self.period == period { errorMessage = message }
            return message
        }
        var changes = snapshots[period]?.changes ?? [:]
        for (symbol, value) in result {
            changes[symbol] = value.change
            livePrices[symbol] = value.price
        }
        snapshots[period] = PeriodSnapshot(changes: changes, fetched: Date(), symbols: wanted)
        if self.period == period, errorMessage?.contains("Yahoo") == true { errorMessage = nil }
        version += 1
        return nil
    }

    /// Det valgte indeks, egne lister og indeksernes egne tal. De andre
    /// indekser hentes først når man skifter til dem.
    private func wantedSymbols(for period: Period) -> Set<String> {
        let universe = UniverseStore.shared
        var symbols = Set(universe.indices.map(\.benchmark))
        // Valutakurser til at omregne europæiske markedsværdier til dollar.
        if period == .day { symbols.formUnion(Currency.yahooSymbols) }
        if let index = universe.index(withID: AppState.shared.indexID) {
            symbols.formUnion(index.symbols)
        }
        symbols.formUnion(ListsStore.shared.allSymbols)
        // Behold det vi allerede har, så et skift frem og tilbage ikke smider
        // data væk.
        if let existing = snapshots[period]?.symbols {
            symbols.formUnion(existing)
        }
        return symbols
    }

    /// Fjerner Nasdaq's "Common Stock", "Class A Ordinary Shares" osv.
    static func cleanName(_ name: String) -> String {
        var result = name
        for suffix in [" Common Stock", " Class A", " Class B", " Class C", " Ordinary Shares",
                       " American Depositary Shares", " Common Shares", " New York Registry Shares",
                       " Subordinate Voting Shares", " Depositary Shares"] {
            if let range = result.range(of: suffix) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Netværk

    private struct NasdaqPayload: Decodable {
        let data: DataBlock?
        struct DataBlock: Decodable { let rows: [Row]? }
        struct Row: Decodable {
            let symbol: String
            let name: String?
            let lastsale: String?
            let pctchange: String?
            let marketCap: String?
            let sector: String?
            let industry: String?
        }
    }

    nonisolated static func fetchNasdaq() async throws -> [String: Quote] {
        let url = URL(string: "https://api.nasdaq.com/api/screener/stocks?tableonly=true&download=true")!
        let (data, response) = try await Net.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketError.http(status) }
        let rows = try JSONDecoder().decode(NasdaqPayload.self, from: data).data?.rows ?? []
        guard !rows.isEmpty else { throw MarketError.empty }

        var quotes: [String: Quote] = [:]
        quotes.reserveCapacity(rows.count)
        for row in rows {
            // Nasdaq skriver klasse-aktier som "BRK/B"; vi bruger "BRK.B".
            let symbol = row.symbol.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: ".")
            guard !symbol.isEmpty, !symbol.contains("^") else { continue }
            quotes[symbol] = Quote(
                symbol: symbol,
                name: row.name ?? symbol,
                price: number(row.lastsale),
                change1D: number(row.pctchange),
                marketCap: number(row.marketCap).flatMap { $0 > 0 ? $0 : nil },
                sector: nasdaqSector(row.sector),
                industry: (row.industry?.isEmpty == false ? row.industry! : "Øvrige")
            )
        }
        return quotes
    }

    /// "$1,234.56", "-3.11%", "48395907078.00", "NA" → Double?
    nonisolated private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    nonisolated private static func nasdaqSector(_ sector: String?) -> String {
        switch sector ?? "" {
        case "Technology": return "Information Technology"
        case "Telecommunications": return "Communication Services"
        case "Finance": return "Financials"
        case "Basic Materials": return "Materials"
        case "": return "Øvrige"
        default: return sector!
        }
    }

}

// MARK: - Børsernes åbningstider

/// Åbningstider for de indekser appen kender. Selve logikken bor i
/// `MarketHours` i det fælles modul, så widget'en kan bruge den.
@MainActor
enum MarketClock {
    /// Er nogen af børserne åbne? Styrer hvor tit der opdateres i baggrunden.
    static func anyOpen() -> Bool {
        let hours = Set(UniverseStore.shared.indices.map(\.hours))
        return hours.isEmpty ? MarketHours.newYork.isOpen() : hours.contains { $0.isOpen() }
    }

    /// Børsen for det indeks man kigger på.
    static var current: MarketHours {
        UniverseStore.shared.index(withID: AppState.shared.indexID)?.hours ?? .newYork
    }
}
