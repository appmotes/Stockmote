import AppKit
import StockmoteShared
import Foundation

// MARK: - Quotes

/// One stock from Nasdaq's screener. Its price and change can be a day old —
/// the screener isn't updated continuously — so they're only used until Yahoo
/// has answered.
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

/// Fetches quotes.
///
/// Two sources, neither needs an API key:
///
/// - **Yahoo's spark** gives price and change for every time range, 1D included,
///   plus the indices' own figures. At most 20 symbols per call, so the S&P 500
///   costs 26 calls. Four at a time.
/// - **Nasdaq's screener** gives all ~7000 US stocks in one call (2 MB) with
///   name, sector and market cap. It's used for tile size and search, and is
///   only fetched every half hour. Its prices lag: checked on a Friday, it
///   showed Thursday's close. So the market cap is scaled by Yahoo's price.
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
    /// Latest price from Yahoo, whatever the time range.
    @Published private(set) var livePrices: [String: Double] = [:]
    @Published private(set) var snapshots: [Period: PeriodSnapshot] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadingPeriod: Period?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    /// Bumped on every data change, so views can recompute their layout.
    @Published private(set) var version = 0

    /// Set by LiveRefresh. While the map is on screen and the market is open,
    /// we refresh more often.
    var mapVisible = false {
        didSet {
            guard mapVisible != oldValue else { return }
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

    // MARK: Lookup

    func quote(_ symbol: String) -> Quote? { quotes[symbol] }

    func price(_ symbol: String) -> Double? {
        livePrices[symbol] ?? quotes[symbol]?.price
    }

    /// Market cap in dollars, scaled by the price change since the source.
    ///
    /// US stocks: Nasdaq's screener. European ones: the figure from
    /// Indices.json in local currency, converted at today's exchange rate — so a
    /// watchlist with both Novo and Apple gets the right sizes.
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
        UniverseStore.shared.info[symbol]?.currency ?? FundStore.shared.info[symbol]?.currency ?? "USD"
    }

    /// The percentage change for a symbol (also "^GSPC") over a time range.
    func change(_ symbol: String, _ period: Period) -> Double? {
        if let value = snapshots[period]?.changes[symbol] { return value }
        // Only until Yahoo has answered the first time: the screener's figures may
        // be from yesterday.
        if period == .day, snapshots[.day] == nil { return quotes[symbol]?.change1D }
        return nil
    }

    /// The index's own change. Yahoo's figure if we have it, otherwise a weighted
    /// average of the members — close, but not the official figure. For a fund
    /// it's the fund's own price.
    func indexChange(_ index: MarketIndex, _ period: Period) -> Double? {
        if let value = snapshots[period]?.changes[index.benchmark] { return value }
        var sum = 0.0, weight = 0.0
        for symbol in index.symbols {
            guard let change = change(symbol, period), let cap = index.weight(symbol) else { continue }
            sum += change * cap
            weight += cap
        }
        return weight > 0 ? sum / weight : nil
    }

    /// Name and classification. Indices.json wins; stocks outside the indices
    /// (e.g. added to a watchlist) get Nasdaq's own sector, and foreign stocks
    /// in a fund the one Yahoo's search returned.
    func info(_ symbol: String) -> StockInfo {
        if let info = UniverseStore.shared.info[symbol] { return info }
        if let quote = quotes[symbol] {
            return StockInfo(symbol: symbol, name: Self.cleanName(quote.name),
                             sector: quote.sector, industry: quote.industry)
        }
        if let info = FundStore.shared.info[symbol] { return info }
        return StockInfo(symbol: symbol, name: symbol, sector: tr("Øvrige", "Other"), industry: tr("Øvrige", "Other"))
    }

    /// Search for adding a stock: symbols starting with the text first, then
    /// names containing it.
    func search(_ text: String, limit: Int = 8) -> [StockInfo] {
        let query = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return [] }
        var exact: [StockInfo] = [], prefix: [StockInfo] = [], named: [StockInfo] = []
        func consider(_ symbol: String, _ name: String) {
            // "NOVO B" and "NOVO-B.CO" should both find Novo.
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
        // European stocks only exist in Indices.json.
        for (symbol, info) in UniverseStore.shared.info where quotes[symbol] == nil {
            consider(symbol, info.name)
        }
        let byCap: (StockInfo, StockInfo) -> Bool = {
            (self.marketCap($0.symbol) ?? 0) > (self.marketCap($1.symbol) ?? 0)
        }
        return Array((exact + prefix.sorted(by: byCap) + named.sorted(by: byCap)).prefix(limit))
    }

    // MARK: Refresh

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
                if self.isStale(after: self.mapVisible ? 45 : 240) {
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

    /// Often while the market is open and the map is showing; rarely otherwise.
    /// A closed market doesn't change, so there's no reason to hammer away.
    private var nextInterval: TimeInterval {
        guard MarketClock.anyOpen() else { return 1800 }
        return mapVisible ? Double(Preferences.shared.refreshSeconds) : 300
    }

    /// Fetches everything for the chosen time range. Called by the loop and the ⟳ button.
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

    /// Fetches Yahoo data for a time range if it's missing or stale.
    /// Returns an error message, or nil.
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

    /// The chosen index, our own lists and the indices' own figures. The other
    /// indices are only fetched when you switch to them.
    private func wantedSymbols(for period: Period) -> Set<String> {
        let universe = UniverseStore.shared
        var symbols = Set(universe.indices.map(\.benchmark))
        // The funds' own prices, for the figure in the sidebar.
        symbols.formUnion(FundStore.shared.funds.map(\.symbol))
        // Exchange rates for converting European market caps to dollars.
        if period == .day { symbols.formUnion(Currency.yahooSymbols) }
        if let index = universe.index(withID: AppState.shared.indexID) {
            symbols.formUnion(index.symbols)
        }
        symbols.formUnion(ListsStore.shared.allSymbols)
        // Keep what we already have, so switching back and forth doesn't throw
        // data away.
        if let existing = snapshots[period]?.symbols {
            symbols.formUnion(existing)
        }
        return symbols
    }

    /// Strips Nasdaq's "Common Stock", "Class A Ordinary Shares" etc.
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

    // MARK: Network

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
            // Nasdaq writes share classes as "BRK/B"; we use "BRK.B".
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

// MARK: - Exchange opening hours

/// Opening hours for the indices the app knows. The logic itself lives in
/// `MarketHours` in the shared module, so the widget can use it.
@MainActor
enum MarketClock {
    /// Is any of the exchanges open? Controls how often we refresh in the background.
    static func anyOpen() -> Bool {
        let hours = Set(UniverseStore.shared.indices.map(\.hours))
        return hours.isEmpty ? MarketHours.newYork.isOpen() : hours.contains { $0.isOpen() }
    }

    /// The exchange for the index you're looking at.
    static var current: MarketHours {
        UniverseStore.shared.index(withID: AppState.shared.indexID)?.hours ?? .newYork
    }
}
