import Compression
import Foundation
import StockmoteShared

// MARK: - Model

/// A fund added in the sidebar: an ETF, a mutual fund or similar,
/// known by its Yahoo symbol ("SPY", "EXS1.DE",
/// "SPIC25KL.CO").
struct Fund: Codable, Hashable, Identifiable {
    let symbol: String
    var name: String
    /// Yahoo's quoteType: "ETF", "MUTUALFUND" or "EQUITY" (Danish mutual
    /// funds are often listed as stocks).
    var kind: String
    var exchange: String?
    /// Nordnet's instrument id, for funds found in Nordnet's search: their
    /// holdings come from Nordnet (see Nordnet.swift).
    var nordnet: Int? = nil

    var id: String { FundStore.id(symbol) }
    var displaySymbol: String { Symbols.display(symbol) }

    /// The name without the provider's filler words, for the sidebar: "State Street SPDR
    /// S&P 500 ETF Trust" → "SPDR S&P 500", "iShares Core MSCI World UCITS ETF
    /// USD (Acc)" → "iShares Core MSCI World".
    var shortName: String {
        var text = name.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        for prefix in ["State Street ", "The "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        for pattern in [#"\s+UCITS\b.*$"#, #"\s+ETF\b.*$"#, #"\s+Index Fund\b.*$"#, #"\s+Fund\b.*$"#,
                        #"\s+KL\b.*$"#, #"\s+Trust$"#, #"\s+(Admiral|Investor|Institutional)( Shares)?$"#] {
            let trimmed = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            if trimmed.count >= 3 { text = trimmed }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? name : text
    }

    /// "ETF" or "Fund" — for search results and tooltips.
    var kindLabel: String {
        kind == "ETF" ? "ETF" : tr("Fond", "Fund")
    }

    /// The fund's exchange, from the symbol's suffix. Used for "Open · closes …"
    /// and for how often to refresh.
    var hours: MarketHours {
        // Funds priced by NAV are Nordnet's Danish funds.
        if FundNAV.isNAV(symbol) { return MarketHours(timezone: "Europe/Copenhagen", open: "09:00", close: "17:00") }
        let suffix = symbol.split(separator: ".").last.map(String.init) ?? ""
        switch symbol.contains(".") ? suffix : "" {
        case "CO": return MarketHours(timezone: "Europe/Copenhagen", open: "09:00", close: "17:00")
        case "DE", "F", "MU", "DU", "BE", "SG", "HM", "HA": return MarketHours(timezone: "Europe/Berlin", open: "09:00", close: "17:30")
        case "L": return MarketHours(timezone: "Europe/London", open: "08:00", close: "16:30")
        case "AS": return MarketHours(timezone: "Europe/Amsterdam", open: "09:00", close: "17:30")
        case "PA": return MarketHours(timezone: "Europe/Paris", open: "09:00", close: "17:30")
        case "MI": return MarketHours(timezone: "Europe/Rome", open: "09:00", close: "17:30")
        case "ST": return MarketHours(timezone: "Europe/Stockholm", open: "09:00", close: "17:30")
        case "OL": return MarketHours(timezone: "Europe/Oslo", open: "09:00", close: "16:20")
        case "HE": return MarketHours(timezone: "Europe/Helsinki", open: "10:00", close: "18:30")
        case "SW": return MarketHours(timezone: "Europe/Zurich", open: "09:00", close: "17:30")
        default: return .newYork
        }
    }
}

/// One stock in a fund. The weight is the fund's own, in percent; nil when the holdings
/// are borrowed from one of the app's own indices, where the fields then get market cap.
struct Holding: Codable, Hashable {
    let symbol: String
    let weight: Double?
}

/// A fund's holdings as loaded. Stored on disk and loaded again after a
/// week — holdings rarely change.
struct FundHoldings: Codable {
    var symbol: String
    /// Largest first, at most `FundStore.maxHoldings`.
    var holdings: [Holding]
    /// Number of stocks in the fund before trimming.
    var total: Int
    /// Where the holdings came from: "iShares", "Vanguard", "Xtrackers", "Amundi",
    /// "SSGA", "Invesco" or "index".
    var source: String
    /// When the fund's own holdings aren't available: the ETF or index that
    /// tracks the same index ("URTH", "dax").
    var proxy: String?
    var fetched: Date
    /// The date the provider's holdings are from, when it says so. Vanguard
    /// publishes its holdings monthly, a few weeks after month end.
    var asOf: Date? = nil
    /// Name and sector for stocks the app doesn't otherwise know (Japanese,
    /// Canadian …), looked up in Yahoo's search.
    var stocks: [StockInfo]
}

/// A search result from Yahoo.
struct FundSearchResult: Identifiable, Hashable {
    let symbol: String
    let name: String
    let kind: String
    let exchange: String
    /// Nordnet's instrument id, when Nordnet's search found the fund.
    var nordnet: Int? = nil
    var id: String { symbol }

    var fund: Fund { Fund(symbol: symbol, name: name, kind: kind, exchange: exchange, nordnet: nordnet) }
}

enum FundError: LocalizedError {
    case noSource(String)
    case empty(String)
    /// A bond, money market or multi-asset fund: its holdings aren't stocks.
    case notEquity(String)
    /// A swap-based (synthetic) ETF: it holds a substitute basket, not the
    /// index, and no fund on the same index was found.
    case swap(String)

    var errorDescription: String? {
        switch self {
        case .noSource(let name):
            return tr("Kunne ikke hente beholdningen for \(name). Fulde beholdninger findes for ETF'er fra iShares, Vanguard, Xtrackers, Amundi, SPDR og Invesco og for fonde der følger et kendt indeks.",
                      "Could not load the holdings for \(name). Full holdings are available for iShares, Vanguard, Xtrackers, Amundi, SPDR and Invesco ETFs and for funds that track a well-known index.")
        case .empty(let name):
            return tr("Kunne ikke hente beholdningen for \(name).", "Could not load the holdings for \(name).")
        case .notEquity(let name):
            return tr("\(name) ejer ikke aktier (obligationer, pengemarked eller andre fonde), så den kan ikke vises som et aktiekort.",
                      "\(name) doesn't hold stocks (bonds, money market or other funds), so it can't be shown as a stock map.")
        case .swap(let name):
            return tr("\(name) er en swap-baseret ETF: den ejer en erstatningskurv i stedet for indeksets aktier, og der blev ikke fundet en fond på samme indeks.",
                      "\(name) is a swap-based ETF: it holds a substitute basket instead of the index's stocks, and no fund on the same index was found.")
        }
    }
}

// MARK: - Store

/// Funds in the sidebar and their holdings.
///
/// The list of funds is stored in UserDefaults (so snapshot mode has its
/// own). Holdings and name lookups are cached in
/// `~/Library/Application Support/Stockmote/Funds/`.
///
/// A fund is shown as an index: `index(withID:)` gives a `MarketIndex` with
/// the holdings as members and the fund's own price as benchmark, so map,
/// list, playback, full screen and widget work without special cases.
@MainActor
final class FundStore: ObservableObject {
    static let shared = FundStore()

    /// Large funds (MSCI World has ~1300 stocks) are trimmed to the largest, so
    /// the Yahoo calls stay on par with the S&P 500.
    static let maxHoldings = 500
    /// Holdings are loaded again when they are more than a week old.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 3600

    nonisolated static func id(_ symbol: String) -> String { "fund:\(symbol)" }
    nonisolated static func symbol(fromID id: String) -> String? {
        id.hasPrefix("fund:") ? String(id.dropFirst(5)) : nil
    }

    @Published private(set) var funds: [Fund] = [] {
        didSet { save() }
    }
    @Published private(set) var holdings: [String: FundHoldings] = [:]
    /// Fund → what is happening right now ("Looking up stocks 40/130").
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]

    /// Classification for stocks in the funds that aren't in Indices.json
    /// or Nasdaq's screener.
    private(set) var info: [String: StockInfo] = [:]
    /// Name from the fund → stock, looked up once and stored. An empty string
    /// means the lookup found nothing.
    private var names: [String: NameMatch] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    struct NameMatch: Codable {
        let symbol: String
        let info: StockInfo?
    }

    private let defaults = AppDefaults.store
    private var isLoading = false

    private init() {
        isLoading = true
        if let data = defaults.data(forKey: "funds"),
           let saved = try? JSONDecoder().decode([Fund].self, from: data) {
            funds = saved
        }
        isLoading = false
        names = Self.readJSON([String: NameMatch].self, from: Self.namesURL) ?? [:]
        for fund in funds {
            if let cached = Self.readJSON(FundHoldings.self, from: Self.cacheURL(fund.symbol)) {
                holdings[fund.symbol] = cached
                for stock in cached.stocks { info[stock.symbol] = stock }
            }
        }
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(funds) else { return }
        defaults.set(data, forKey: "funds")
    }

    // MARK: Lookup

    func fund(_ symbol: String) -> Fund? { funds.first { $0.symbol == symbol } }

    func contains(_ symbol: String) -> Bool { fund(symbol) != nil }

    /// The fund as an index. If it exists but its holdings aren't loaded yet,
    /// the member list is empty — the map then shows that they are loading.
    func index(withID id: String) -> MarketIndex? {
        guard let symbol = Self.symbol(fromID: id), let fund = fund(symbol) else { return nil }
        return index(for: fund)
    }

    func index(for fund: Fund) -> MarketIndex {
        let loaded = holdings[fund.symbol]
        let list = loaded?.holdings ?? []
        let weights = list.allSatisfy { $0.weight != nil } && !list.isEmpty
            ? Dictionary(list.map { ($0.symbol, $0.weight!) }, uniquingKeysWith: +)
            : nil
        let hours = fund.hours
        return MarketIndex(
            id: fund.id, name: fund.name, region: "fund", flag: nil, benchmark: fund.symbol,
            timezone: hours.timezone, open: hours.open, close: hours.close,
            symbols: list.map(\.symbol), weights: weights
        )
    }

    var indices: [MarketIndex] { funds.map(index(for:)) }

    /// All stocks in all funds.
    var allSymbols: Set<String> {
        Set(holdings.values.flatMap { $0.holdings.map(\.symbol) })
    }

    /// The stock's weight in the fund, in percent.
    func weight(of symbol: String, inIndex id: String) -> Double? {
        guard let fund = Self.symbol(fromID: id) else { return nil }
        return holdings[fund]?.holdings.first { $0.symbol == symbol }?.weight
    }

    /// "SSGA · the 500 largest of 2,874 stocks" or "Same index as 🇩🇪 DAX".
    func sourceNote(_ symbol: String) -> String? {
        holdings[symbol].map(sourceNote(for:))
    }

    func sourceNote(for loaded: FundHoldings) -> String {
        var parts: [String] = []
        if loaded.source == "index", let proxy = loaded.proxy,
           let index = UniverseStore.shared.index(withID: proxy) {
            parts.append(tr("Samme indeks som \(index.title)", "Same index as \(index.title)"))
        } else if let proxy = loaded.proxy {
            parts.append(tr("Beholdning fra \(proxy) (\(loaded.source)), der følger et tilsvarende indeks",
                            "Holdings of \(proxy) (\(loaded.source)), which tracks a similar index"))
        } else if let asOf = loaded.asOf {
            // "30. sep." / "Sep 30"; with the year when it isn't this year.
            let formatter = DateFormatter()
            formatter.locale = Lang.locale
            formatter.timeZone = TimeZone(identifier: "UTC")
            let thisYear = Calendar.current.isDate(asOf, equalTo: Date(), toGranularity: .year)
            formatter.setLocalizedDateFormatFromTemplate(thisYear ? "dMMM" : "dMMMyyyy")
            let date = formatter.string(from: asOf)
            parts.append(tr("Beholdning fra \(loaded.source) pr. \(date)", "Holdings from \(loaded.source) as of \(date)"))
        } else {
            parts.append(tr("Beholdning fra \(loaded.source)", "Holdings from \(loaded.source)"))
        }
        if loaded.total > loaded.holdings.count {
            let shown = Format.integer(loaded.holdings.count), total = Format.integer(loaded.total)
            parts.append(tr("de \(shown) største af \(total) aktier", "the \(shown) largest of \(total) stocks"))
        }
        return parts.joined(separator: " · ")
    }

    /// One line for the add-fund dialog once the holdings are loaded:
    /// "237 stocks · largest: NVDA 9.8 %".
    func preview(_ loaded: FundHoldings) -> String {
        let count = tr("\(Format.integer(loaded.total)) aktier", "\(Format.integer(loaded.total)) stocks")
        guard let top = loaded.holdings.first, let weight = top.weight else { return count }
        // Asian tickers are just numbers ("2330"); the company name says more.
        var name = Symbols.display(top.symbol)
        if name.allSatisfy(\.isNumber),
           let info = loaded.stocks.first(where: { $0.symbol == top.symbol }) ?? UniverseStore.shared.info[top.symbol] {
            name = Self.nameWords(info.name).prefix(2).map(\.capitalized).joined(separator: " ")
        }
        return "\(count) · " + tr("største: \(name) \(Format.weight(weight))", "largest: \(name) \(Format.weight(weight))")
    }

    // MARK: Add and remove

    /// Adds the fund (if it isn't there) and loads its holdings. Used
    /// by snapshot mode; the dialog uses `resolve` and `add(_:holdings:)`.
    func add(_ fund: Fund) {
        if !contains(fund.symbol) { funds.append(fund) }
        load(fund.symbol, force: false)
    }

    /// Loads the fund's holdings without adding it. The dialog shows them
    /// first, so a fund no source knows never ends up in the sidebar.
    /// `report` gets the progress ("Looking up stocks 40/130…").
    func resolve(_ fund: Fund, report: @escaping @MainActor (String) -> Void) async throws -> FundHoldings {
        try await buildHoldings(fund, report: report)
    }

    /// Adds a fund whose holdings `resolve` just loaded. They are cached
    /// right away, so the fund shows without being loaded again.
    func add(_ fund: Fund, holdings loaded: FundHoldings) {
        if !contains(fund.symbol) { funds.append(fund) }
        errors[fund.symbol] = nil
        keep(loaded)
        Task { await loadQuotes() }
    }

    func remove(_ symbol: String) {
        tasks[symbol]?.cancel()
        tasks[symbol] = nil
        funds.removeAll { $0.symbol == symbol }
        holdings[symbol] = nil
        errors[symbol] = nil
        progress[symbol] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(symbol))
        let app = AppState.shared
        if app.indexID == Self.id(symbol) { app.indexID = "sp500" }
    }

    /// Loads holdings that are missing or more than a week old.
    func refreshStale() {
        for fund in funds where !isFresh(fund) {
            load(fund.symbol, force: false)
        }
    }

    /// Stored holdings are fresh for a week — except holdings borrowed from
    /// a similar fund or index for a fund whose provider is now a source
    /// (iShares, Vanguard …). Those were stored before the provider became a
    /// source, and the fund's own holdings can now be loaded.
    private func isFresh(_ fund: Fund) -> Bool {
        guard let loaded = holdings[fund.symbol] else { return false }
        if loaded.proxy != nil, FundSources.hasOwnSource(fund.name),
           loaded.fetched < FundSources.issuersAdded { return false }
        return Date().timeIntervalSince(loaded.fetched) < Self.maxAge
    }

    /// Loads the holdings in the background. `force` loads even when they are fresh.
    func load(_ symbol: String, force: Bool) {
        guard tasks[symbol] == nil, let fund = fund(symbol) else { return }
        if !force, isFresh(fund) { return }
        tasks[symbol] = Task { [weak self] in
            await self?.fetch(fund)
            self?.tasks[symbol] = nil
        }
    }

    /// Waits until the holdings are loaded (for snapshot mode).
    func ensureLoaded(_ symbol: String) async {
        load(symbol, force: false)
        await tasks[symbol]?.value
    }

    private func fetch(_ fund: Fund) async {
        errors[fund.symbol] = nil
        progress[fund.symbol] = tr("Henter beholdningen…", "Loading holdings…")
        defer { progress[fund.symbol] = nil }
        do {
            let loaded = try await buildHoldings(fund) { [weak self] in self?.progress[fund.symbol] = $0 }
            guard !Task.isCancelled, contains(fund.symbol) else { return }
            keep(loaded)
            await loadQuotes()
        } catch {
            guard !Task.isCancelled else { return }
            // Old holdings are better than none; the error only shows when
            // there are none.
            if holdings[fund.symbol] == nil {
                errors[fund.symbol] = error.localizedDescription
            }
        }
    }

    private func keep(_ loaded: FundHoldings) {
        holdings[loaded.symbol] = loaded
        for stock in loaded.stocks { info[stock.symbol] = stock }
        Self.writeJSON(loaded, to: Self.cacheURL(loaded.symbol))
    }

    /// The new stocks don't have prices yet.
    private func loadQuotes() async {
        let market = MarketStore.shared
        await market.loadPeriod(.day, force: false)
        if market.period != .day { await market.loadPeriod(market.period, force: false) }
    }

    // MARK: Loading

    /// The fund's own holdings from the provider (iShares, Vanguard, Xtrackers,
    /// Amundi, SSGA, Invesco); otherwise a fund or index that tracks the same
    /// index (see `FundProxy`). A bond or multi-asset fund stops right away with
    /// a message; a swap-based ETF tries the proxy first.
    private func buildHoldings(_ fund: Fund, report: @escaping @MainActor (String) -> Void) async throws -> FundHoldings {
        var swapError: Error?
        // Danish funds and Nordnet's own: Nordnet's holdings. When they are only
        // the largest 25, a fund or index on the same index is preferred.
        var partial: FundSources.Found?
        if let id = await nordnetID(fund), let found = try await FundSources.nordnet(id, name: fund.name) {
            if !found.partial || FundProxy.match(fund.name) == nil {
                var loaded = try await fromRows(found.rows, source: found.source, fund: fund, proxy: nil, report: report)
                loaded.asOf = found.asOf
                return loaded
            }
            partial = found
        }
        do {
            if let found = try await FundSources.holdings(fund.symbol, name: fund.name) {
                var loaded = try await fromRows(found.rows, source: found.source, fund: fund, proxy: nil, report: report)
                loaded.asOf = found.asOf
                return loaded
            }
        } catch FundError.swap(let name) {
            swapError = FundError.swap(name)
        }
        switch FundProxy.match(fund.name) {
        case .index(let id)?:
            guard let index = UniverseStore.shared.index(withID: id), !index.symbols.isEmpty else { break }
            return FundHoldings(symbol: fund.symbol, holdings: index.symbols.map { Holding(symbol: $0, weight: nil) },
                                total: index.symbols.count, source: "index", proxy: id, fetched: Date(), stocks: [])
        case .etf(let etf)?:
            report(tr("Henter beholdningen fra \(etf)…", "Loading holdings from \(etf)…"))
            guard let found = try? await FundSources.holdings(etf) else { break }
            return try await fromRows(found.rows, source: found.source, fund: fund, proxy: etf, report: report)
        case nil:
            break
        }
        if let partial {
            var loaded = try await fromRows(partial.rows, source: partial.source, fund: fund, proxy: nil, report: report)
            loaded.asOf = partial.asOf
            return loaded
        }
        throw swapError ?? FundError.noSource(fund.name)
    }

    /// Nordnet's id: from Nordnet's search, or looked up for a fund listed
    /// in Copenhagen that was found in Yahoo's search.
    private func nordnetID(_ fund: Fund) async -> Int? {
        if let id = fund.nordnet { return id }
        guard fund.symbol.hasSuffix(".CO") else { return nil }
        return await Nordnet.instrumentID(forCopenhagen: fund.symbol)
    }

    private func fromRows(_ rows: [FundSources.Row], source: String, fund: Fund, proxy: String?,
                          report: @MainActor (String) -> Void) async throws -> FundHoldings {
        let market = MarketStore.shared
        let universe = UniverseStore.shared
        // Cash, futures, money market funds and the like are not stocks.
        var stocks = rows.filter { $0.weight > 0 && !FundSources.isNonEquity($0.name, ticker: $0.ticker.isEmpty ? $0.isin ?? "" : $0.ticker) }
        stocks.sort { $0.weight > $1.weight }
        let total = stocks.count
        stocks = Array(stocks.prefix(Self.maxHoldings))

        var result: [Holding] = []
        var found: [StockInfo] = []
        var unresolved: [FundSources.Row] = []
        for row in stocks {
            if row.isUS, let us = row.yahooGuess {
                // If it's in neither the screener nor the indices, it is
                // probably a fund or cash.
                if !market.quotes.isEmpty, market.quotes[us] == nil, universe.info[us] == nil { continue }
                result.append(Holding(symbol: us, weight: row.weight))
                if market.quotes[us] == nil, universe.info[us] == nil {
                    found.append(row.fallbackInfo(us) ?? StockInfo(symbol: us, name: row.name.capitalized, sector: "Øvrige", industry: "Øvrige"))
                }
            } else {
                unresolved.append(row)
            }
        }

        // Foreign stocks: first Indices.json and earlier lookups, then
        // Yahoo's search, four at a time.
        var matches: [(FundSources.Row, NameMatch)] = []
        var lookups: [FundSources.Row] = []
        for row in unresolved {
            if let local = localMatch(row) {
                matches.append((row, local))
            } else if let cached = names[Self.nameKey(row)] {
                matches.append((row, cached))
            } else {
                lookups.append(row)
            }
        }
        var done = 0
        var failed: [FundSources.Row] = []
        let count = lookups.count
        await withTaskGroup(of: (FundSources.Row, NameMatch?).self) { group in
            var iterator = lookups.makeIterator()
            for _ in 0..<4 {
                guard let row = iterator.next() else { break }
                group.addTask { (row, await Self.yahooMatch(row)) }
            }
            while let (row, match) = await group.next() {
                done += 1
                report(tr("Slår aktier op \(done)/\(count)…", "Looking up stocks \(done)/\(count)…"))
                if let match {
                    names[Self.nameKey(row)] = match
                    matches.append((row, match))
                } else {
                    failed.append(row)
                }
                if let row = iterator.next() {
                    group.addTask { (row, await Self.yahooMatch(row)) }
                }
            }
        }
        // Yahoo answers 429 when asked a lot. Lookups that failed are retried
        // once, one at a time. If they still fail, they aren't stored — so
        // they are retried next time — and until then the ticker is used as
        // is, without a sector.
        for row in failed {
            try? await Task.sleep(for: .milliseconds(400))
            if let match = await Self.yahooMatch(row) {
                names[Self.nameKey(row)] = match
                matches.append((row, match))
            } else if let guess = row.yahooGuess {
                matches.append((row, NameMatch(symbol: guess, info: row.fallbackInfo(guess))))
            }
        }
        if count > 0 { Self.writeJSON(names, to: Self.namesURL) }
        for (row, match) in matches where !match.symbol.isEmpty {
            result.append(Holding(symbol: match.symbol, weight: row.weight))
            if let info = match.info { found.append(info) }
        }

        // The same stock twice (e.g. two share classes that resolve to the same
        // symbol): add up the weights.
        var merged: [String: Double] = [:]
        var order: [String] = []
        for holding in result {
            if merged[holding.symbol] == nil { order.append(holding.symbol) }
            merged[holding.symbol, default: 0] += holding.weight ?? 0
        }
        let final = order.map { Holding(symbol: $0, weight: merged[$0]) }.sorted { ($0.weight ?? 0) > ($1.weight ?? 0) }
        guard !final.isEmpty else { throw FundError.empty(fund.name) }
        return FundHoldings(symbol: fund.symbol, holdings: final, total: total,
                            source: source, proxy: proxy, fetched: Date(), stocks: found)
    }

    /// Name and currency: the same name can be two companies on two exchanges.
    /// The ISIN when the provider writes it — it is unique.
    nonisolated private static func nameKey(_ row: FundSources.Row) -> String {
        if let isin = row.isin, !isin.isEmpty { return "ISIN|\(isin)" }
        return "\(row.name.uppercased())|\(row.currency)"
    }

    /// A European stock in one of the app's indices: same symbol as the guess,
    /// same ticker and same first word in the name, or exactly the same name.
    private func localMatch(_ row: FundSources.Row) -> NameMatch? {
        let universe = UniverseStore.shared
        if let guess = row.yahooGuess, universe.info[guess] != nil { return NameMatch(symbol: guess, info: nil) }
        let words = Self.nameWords(row.name)
        guard let first = words.first else { return nil }
        let ticker = Self.squash(row.ticker)
        for (symbol, info) in universe.info where Symbols.isForeign(symbol) {
            let theirs = Self.nameWords(info.name)
            if !ticker.isEmpty, Self.squash(Symbols.display(symbol)) == ticker, theirs.first == first {
                return NameMatch(symbol: symbol, info: nil)
            }
            if theirs == words { return NameMatch(symbol: symbol, info: nil) }
        }
        return nil
    }

    /// The name without legal form and punctuation: "ROLLS-ROYCE HOLDINGS PLC" → ["ROLLS", "ROYCE"].
    nonisolated static func nameWords(_ name: String) -> [String] {
        let stop: Set<String> = ["PLC", "AG", "SA", "SE", "NV", "ASA", "AB", "OYJ", "AS", "A", "B", "N", "LTD", "INC",
                                 "CORP", "CO", "HOLDING", "HOLDINGS", "GROUP", "THE", "REG", "CLASS", "SPA", "PUBL",
                                 "LIMITED", "CORPORATION", "COMPANY", "S", "P", "DE", "NA", "KGAA", "BV", "ADR", "OF",
                                 "SHS", "SER", "PREF", "H", "ORD", "NPV", "ABP", "NYRT", "SAB", "CV"]
        return name.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
    }

    nonisolated private static func squash(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Looks up a company in Yahoo's search to get sector and industry — and
    /// the symbol, when it can't be guessed from ticker and currency (euro stocks).
    /// Prefers the guess, otherwise the primary listing (SAN.PA over BNP.F or
    /// an OTC ADR) and a ticker that matches the one the fund itself writes.
    nonisolated private static func yahooMatch(_ row: FundSources.Row) async -> NameMatch? {
        // First the guessed symbol ("RY.TO") — then Yahoo answers with exactly that
        // stock. Otherwise the name, and finally the first two words: the search
        // finds nothing for "ROYAL BANK CANADA", but something for "ROYAL BANK".
        // An ISIN finds exactly the company, and Yahoo answers with its primary
        // listing first (Vanguard, Xtrackers and Amundi write ISINs).
        let words = nameWords(row.name)
        var queries: [String] = []
        for query in [row.isin ?? "", row.yahooGuess ?? "", words.prefix(4).joined(separator: " "), words.prefix(2).joined(separator: " ")] {
            if !query.isEmpty, !queries.contains(query) { queries.append(query) }
        }
        var answered = false
        var guessKnown = false
        for query in queries {
            guard let quotes = await YahooSearch.quotes(query, count: 8) else { continue }
            answered = true
            if quotes.contains(where: { $0.symbol == row.yahooGuess }) { guessKnown = true }
            // If Yahoo doesn't know the guessed symbol, its other answers are
            // other companies with a similar ticker — look up the name instead.
            if query == row.yahooGuess, !guessKnown { continue }
            // The ISIN's answers are all the same company.
            if query == row.isin, !quotes.contains(where: { $0.quoteType == "EQUITY" }) { continue }
            if let match = pick(quotes, for: row, guessKnown: guessKnown) { return match }
        }
        // If Yahoo didn't answer at all, try again later (nil). If it answered
        // without knowing the stock: the ticker as is, without a sector.
        return answered ? NameMatch(symbol: row.yahooGuess ?? "", info: row.yahooGuess.flatMap(row.fallbackInfo)) : nil
    }

    nonisolated private static func pick(_ quotes: [YahooSearch.Quote], for row: FundSources.Row, guessKnown: Bool) -> NameMatch? {
        let equities = quotes.filter { $0.quoteType == "EQUITY" }
        let ticker = squash(row.ticker)
        let guess = row.yahooGuess
        let euro = row.currency == "EUR"
        func score(_ quote: YahooSearch.Quote) -> Int {
            let parts = quote.symbol.split(separator: ".")
            let base = squash(String(parts.first ?? ""))
            let suffix = parts.count > 1 ? String(parts.last!) : ""
            var points = 0
            if quote.symbol == guess { points += 100 }
            if euro, !YahooSearch.euroSuffixes.contains(suffix) { points -= 5 }
            if !ticker.isEmpty, base == ticker || base.hasPrefix(ticker) { points += 10 }
            if quote.exchange == "PNK" || YahooSearch.secondarySuffixes.contains(suffix) { points -= 20 }
            if suffix.isEmpty { points += 2 } else if YahooSearch.primarySuffixes.contains(suffix) { points += 4 }
            // The exchange the provider's data points to: a US ISIN is the New York
            // listing, not a Canadian depositary receipt (GOOG.TO).
            if let expected = row.suffix, suffix == expected { points += 8 }
            return points
        }
        guard let best = equities.enumerated().max(by: { a, b in
            // Tied score: Yahoo's own order.
            (score(a.element), -a.offset) < (score(b.element), -b.offset)
        })?.element, score(best) > -10 else { return nil }
        // A guess from ticker and exchange wins over the search's symbol — it
        // is the provider's own information, and the search only adds the
        // sector. Except when Yahoo doesn't know the guess but found the
        // company on the same exchange under another ticker: iShares writes
        // Roche as "ROP", Yahoo has "ROG.SW".
        // US class shares are written with a dot internally ("BRK.B").
        func suffix(_ symbol: String) -> String { symbol.contains(".") ? String(symbol.split(separator: ".").last!) : "" }
        // A guess from the ISIN's country is only a guess: Linde has an Irish ISIN
        // but trades in New York.
        let replaceGuess = guess.map { !guessKnown && (row.softGuess || suffix($0) == suffix(best.symbol)) } ?? true
        let symbol = guess.flatMap { replaceGuess ? nil : $0 } ?? (best.symbol.contains(".") && Symbols.isForeign(best.symbol)
            ? best.symbol
            : best.symbol.replacingOccurrences(of: "-", with: "."))
        // If Yahoo doesn't know the sector, use the fund's own (iShares writes it).
        let sector = YahooSearch.gicsSector(best.sector)
        let info = StockInfo(
            symbol: symbol, name: best.name,
            sector: sector == "Øvrige" ? (row.gicsSector ?? sector) : sector,
            industry: (best.industry ?? "Øvrige").replacingOccurrences(of: "—", with: " – "),
            currency: YahooSearch.currency(for: symbol)
        )
        return NameMatch(symbol: symbol, info: info)
    }

    // MARK: Search

    /// ETFs and funds that match the text: Yahoo's search, and Nordnet's for
    /// the Danish funds Yahoo doesn't know. A fund both know is shown once, with
    /// Yahoo's symbol and Nordnet's id (for the holdings).
    nonisolated static func search(_ text: String) async -> [FundSearchResult] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        async let yahoo = yahooSearch(query)
        async let nordnet = Nordnet.search(query)
        var results = await yahoo
        let fromNordnet = await nordnet
        // The same fund: the same symbol, or the same name (Yahoo knows some of
        // Nordnet's funds by Morningstar id, "0P000134KA.CO").
        func same(_ a: FundSearchResult, _ b: FundSearchResult) -> Bool {
            a.symbol == b.symbol || a.name.lowercased() == b.name.lowercased()
        }
        for (i, result) in results.enumerated() {
            if let match = fromNordnet.first(where: { same($0, result) }) { results[i].nordnet = match.nordnet }
        }
        let extra = fromNordnet.filter { found in !results.contains { same($0, found) } }
        // Room for Nordnet's results among the eight the dialog shows.
        return Array(results.prefix(extra.isEmpty ? 15 : max(3, 8 - extra.count))) + extra
    }

    nonisolated private static func yahooSearch(_ query: String) async -> [FundSearchResult] {
        guard let quotes = await YahooSearch.quotes(query, count: 15) else { return [] }
        return quotes.compactMap { quote in
            let isFund = quote.quoteType == "ETF" || quote.quoteType == "MUTUALFUND"
                || (quote.quoteType == "EQUITY" && looksLikeFund(quote.name))
            guard isFund else { return nil }
            return FundSearchResult(symbol: quote.symbol, name: quote.name, kind: quote.quoteType ?? "",
                                    exchange: quote.exchangeName ?? quote.exchange ?? "")
        }
    }

    /// Danish mutual funds are often listed as stocks on Yahoo
    /// ("Sparindex INDEX OMX C25 KL").
    nonisolated private static func looksLikeFund(_ name: String) -> Bool {
        let words = Set(name.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !words.isDisjoint(with: ["ETF", "UCITS", "INDEX", "INDEKS", "KL", "FUND", "FOND", "SPARINDEX"])
    }

    // MARK: Files

    /// `~/Library/Application Support/Stockmote/Funds/` — in snapshot mode
    /// `…/Stockmote/Snapshot/Funds/`, so test runs don't touch the app's own cache.
    nonisolated static var folder: URL {
        let base = UniverseStore.userOverrideURL.deletingLastPathComponent()
        return (AppDefaults.isSnapshot ? base.appendingPathComponent("Snapshot") : base).appendingPathComponent("Funds")
    }

    nonisolated private static func cacheURL(_ symbol: String) -> URL {
        let safe = symbol.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent("\(safe).json")
    }

    private static var namesURL: URL { folder.appendingPathComponent("Names.json") }

    nonisolated static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    nonisolated static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Sources

/// Sources for full holdings. None of them needs an account or key, and
/// none is a documented API — they are the files the providers themselves offer
/// for download on the funds' pages.
///
/// - **iShares (BlackRock)**: a CSV with the full holdings on each fund's page,
///   for both US ETFs (SOXX, IVV …) and European UCITS ETFs
///   (SEC0, EUNL, CSPX …). See `IShares`.
/// - **State Street (SSGA)**: a spreadsheet with the full holdings for all
///   SPDR ETFs (SPY, XLK, SPGM …), updated daily.
/// - **Invesco**: JSON with the full holdings (QQQ, RSP …).
///
/// - **Vanguard**, **Xtrackers (DWS)** and **Amundi**: JSON behind the funds'
///   pages, see FundIssuers.swift.
///
/// Zacks and stockanalysis.com reject anything but browsers — those aren't used.
enum FundSources {
    struct Row: Sendable {
        let name: String
        /// The ticker as the provider writes it: "AAPL", "BRK.B", "7203", "NOVN".
        let ticker: String
        /// Trading currency. Without an exchange it decides the exchange: USD is a US
        /// stock, JPY Tokyo.
        let currency: String
        /// Percent of the fund.
        let weight: Double
        /// The exchange as the provider writes it ("Euronext Amsterdam", "Xetra").
        /// Only iShares has it; it decides the exchange for euro stocks, which
        /// the currency can't.
        var exchange: String? = nil
        /// The GICS sector as the provider writes it, for stocks Yahoo doesn't know.
        var sector: String? = nil
        /// The ISIN, when the provider writes it. Stocks are then looked up by ISIN.
        var isin: String? = nil
        /// The Yahoo suffix when the provider says exactly where the stock trades
        /// (Amundi writes Bloomberg tickers: "ASML NA" → "AS").
        var listing: String? = nil
        /// The country the stock trades in, as ISO code, when the provider
        /// writes neither exchange nor a currency with one exchange. Usually the
        /// ISIN's country; for companies registered in Ireland, the Cayman
        /// Islands and the like, the provider's country of risk.
        var country: String? = nil

        /// The Yahoo suffix for the stock's exchange, "" for the US: from the exchange when
        /// the provider writes it, otherwise from the currency when it has only one
        /// exchange, otherwise from the country. nil when it can't be determined
        /// (euro without exchange, Thailand …) — then the stock is looked up by name.
        var suffix: String? {
            if let listing { return listing }
            if let exchange, let known = FundSources.suffix(exchange: exchange) { return known }
            if let known = FundSources.suffix(currency: currency) { return known }
            return country.flatMap { FundSources.suffix(country: $0, ticker: ticker) }
        }

        /// The exchange is only guessed from the country: if Yahoo doesn't know the
        /// guess, its search decides.
        var softGuess: Bool {
            listing == nil && (exchange.flatMap(FundSources.suffix(exchange:))) == nil
                && FundSources.suffix(currency: currency) == nil && country != nil
        }

        var isUS: Bool { suffix == "" && !softGuess }

        /// The Yahoo symbol from ticker and exchange. Each exchange writes tickers
        /// its own way on Yahoo: class shares with a dot in the US and
        /// a hyphen in Stockholm, Hong Kong with four digits …
        var yahooGuess: String? {
            let t = ticker.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let suffix else { return nil }
            switch suffix {
            case "": return t.replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: " ", with: ".")
            case "HK": return "\(String(repeating: "0", count: max(0, 4 - t.count)))\(t).HK"
            case "TO": return "\(t.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: " ", with: "-")).TO"
            case "L":
                // Dollar listings in London (GDRs) are named differently on Yahoo.
                guard ["GBP", "GBp", "GBX"].contains(currency) else { return nil }
                let base = t.hasSuffix(".") ? String(t.dropLast()) : t
                return "\(base.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")).L"
            case "TA": return "\(t.replacingOccurrences(of: ".", with: "")).TA"
            case "KS", "KQ": return "\(t.hasPrefix("A") ? String(t.dropFirst()) : t).\(suffix)"
            default: return "\(t.replacingOccurrences(of: " ", with: "-")).\(suffix)"
            }
        }

        /// The sector as a GICS name, or nil if the provider doesn't write one
        /// the app knows (iShares' German files write "IT", "Gesundheitswesen" …).
        var gicsSector: String? {
            guard let sector else { return nil }
            let name = sector == "Communication" ? "Communication Services" : sector
            return FundSources.gicsSectors.contains(name) ? name : nil
        }

        /// Name and sector from the fund itself, when Yahoo doesn't know the stock.
        func fallbackInfo(_ symbol: String) -> StockInfo? {
            guard let gicsSector else { return nil }
            return StockInfo(symbol: symbol, name: name.capitalized, sector: gicsSector, industry: "Øvrige",
                             currency: YahooSearch.currency(for: symbol))
        }
    }

    static let gicsSectors: Set<String> = [
        "Information Technology", "Health Care", "Financials", "Consumer Discretionary", "Consumer Staples",
        "Industrials", "Energy", "Utilities", "Materials", "Real Estate", "Communication Services"
    ]

    /// Currencies with only one exchange, as Yahoo suffix.
    static func suffix(currency: String) -> String? {
        switch currency {
        case "USD": return ""
        case "JPY": return "T"
        case "HKD": return "HK"
        case "CAD": return "TO"
        case "AUD": return "AX"
        case "GBP", "GBp", "GBX": return "L"
        case "CHF": return "SW"
        case "SEK": return "ST"
        case "NOK": return "OL"
        case "DKK": return "CO"
        case "SGD": return "SI"
        case "ILS", "ILA": return "TA"
        case "KRW": return "KS"
        case "TWD": return "TW"
        case "NZD": return "NZ"
        case "INR": return "NS"
        case "BRL": return "SA"
        case "ZAR": return "JO"
        case "PLN": return "WA"
        default: return nil
        }
    }

    /// Countries with one main exchange, as Yahoo suffix. China has two: Shanghai
    /// tickers start with 6, Shenzhen tickers with 0 or 3, and short tickers are
    /// H shares in Hong Kong.
    static func suffix(country: String, ticker: String) -> String? {
        let numeric = !ticker.isEmpty && ticker.allSatisfy(\.isNumber)
        switch country {
        case "US": return ""
        case "CN":
            guard ticker.count == 6 else { return "HK" }
            return ticker.hasPrefix("6") ? "SS" : "SZ"
        case "HK", "MO": return "HK"
        case "JP": return "T"
        case "GB", "IM", "GG", "JE": return numeric ? nil : "L"
        case "CA": return "TO"
        case "AU": return "AX"
        case "NZ": return "NZ"
        case "CH": return "SW"
        case "DE": return "DE"
        case "FR": return "PA"
        case "NL": return "AS"
        case "BE": return "BR"
        case "IT": return "MI"
        case "ES": return "MC"
        case "PT": return "LS"
        case "AT": return "VI"
        case "FI": return "HE"
        case "IE": return "IR"
        case "DK": return "CO"
        case "SE": return "ST"
        case "NO": return "OL"
        case "PL": return "WA"
        case "GR": return "AT"
        case "TR": return "IS"
        case "IL": return "TA"
        case "ZA": return "JO"
        case "KR": return "KS"
        case "TW": return "TW"
        case "IN": return "NS"
        case "SG": return "SI"
        case "BR": return "SA"
        case "MX": return "MX"
        case "TH": return "BK"
        case "ID": return "JK"
        case "MY": return "KL"
        case "SA": return "SR"
        case "QA": return "QA"
        case "CL": return "SN"
        // Companies registered in tax havens: numbers are Hong Kong, letters
        // usually New York.
        case "KY", "BM", "VG": return numeric ? "HK" : ""
        default: return nil
        }
    }

    /// Bloomberg's exchange codes ("AAPL UW", "ASML NA") as Yahoo suffix.
    static func suffix(bloomberg code: String) -> String? {
        switch code {
        case "US", "UN", "UW", "UQ", "UR", "UA", "UF", "UP", "UV": return ""
        case "LN": return "L"
        case "FP": return "PA"
        case "NA": return "AS"
        case "BB": return "BR"
        case "GY", "GR", "GF": return "DE"
        case "IM": return "MI"
        case "SM", "SQ": return "MC"
        case "PL": return "LS"
        case "ID": return "IR"
        case "AV": return "VI"
        case "FH": return "HE"
        case "DC": return "CO"
        case "SS": return "ST"
        case "NO": return "OL"
        case "SE", "VX", "SW": return "SW"
        case "JT", "JP": return "T"
        case "HK": return "HK"
        case "CT", "CN": return "TO"
        case "AT", "AU": return "AX"
        case "NZ": return "NZ"
        case "SP": return "SI"
        case "IT": return "TA"
        case "KS": return "KS"
        case "KQ": return "KQ"
        case "TT": return "TW"
        case "IS", "IN": return "NS"
        case "IB": return "BO"
        case "C1", "CG": return "SS"
        case "C2", "CS": return "SZ"
        case "BZ": return "SA"
        case "SJ": return "JO"
        case "MM": return "MX"
        case "PW": return "WA"
        case "TI": return "IS"
        case "GA": return "AT"
        case "TB": return "BK"
        case "IJ": return "JK"
        case "MK": return "KL"
        case "AB": return "SR"
        case "CI": return "SN"
        default: return nil
        }
    }

    /// Exchanges as iShares writes them, as Yahoo suffix. The first match
    /// wins, so "Nasdaq Omx Helsinki" comes before "Nasdaq", and "Nyse Euronext
    /// - Euronext Paris" before "Nyse". Exchanges not listed here (Thailand,
    /// Saudi Arabia …) — or "Nasdaq Omx Nordic", which covers four countries —
    /// are left to the currency and otherwise to the name lookup.
    private static let exchanges: [(String, String?)] = [
        ("amsterdam", "AS"), ("paris", "PA"), ("brussels", "BR"), ("lisbon", "LS"), ("irish", "IR"), ("dublin", "IR"),
        ("xetra", "DE"), ("deutsche b", "DE"), ("borsa italiana", "MI"), ("madrid", "MC"), ("wiener", "VI"),
        ("athens", "AT"), ("helsinki", "HE"), ("copenhagen", "CO"), ("oslo", "OL"), ("stockholm", "ST"),
        ("nasdaq omx", nil), ("swiss", "SW"), ("london", "L"), ("warsaw", "WA"), ("istanbul", "IS"),
        ("tel aviv", "TA"), ("johannesburg", "JO"), ("tokyo", "T"), ("hong kong", "HK"), ("kosdaq", "KQ"),
        ("korea exchange", "KS"), ("gretai", "TWO"), ("taipei exchange", "TWO"), ("taiwan stock exchange", "TW"),
        ("shanghai", "SS"), ("shenzhen", "SZ"), ("national stock exchange of india", "NS"), ("singapore", "SI"),
        ("asx", "AX"), ("new zealand", "NZ"), ("toronto", "TO"), ("xbsp", "SA"),
        ("nasdaq", ""), ("nyse", ""), ("new york stock exchange", ""), ("cboe", ""), ("arca", "")
    ]

    static func suffix(exchange: String) -> String? {
        let name = exchange.lowercased()
        return exchanges.first { name.contains($0.0) }?.1
    }

    /// Cash, futures, swaps and money market funds.
    static func isNonEquity(_ name: String, ticker: String) -> Bool {
        let upper = " \(name.uppercased()) "
        if ticker.isEmpty || ticker == "-" || ticker == "N/A" { return true }
        return ["CASH", "COLLATERAL", "FUTURE", "TREASURY", "T-BILL", "MONEY MARKET", "SWAP", "CURRENCY",
                "MARGIN", "DERIVATIVE", " FND ", " FUND ", "U.S. DOLLAR", "US DOLLAR", "FX CONTRACT", " MMF "]
            .contains { upper.contains($0) }
    }

    /// What a provider found: the stocks, its name, and the date they're from.
    struct Found {
        var rows: [Row]
        var source: String
        var asOf: Date? = nil
        /// Only the largest holdings (Nordnet publishes 25).
        var partial = false
    }

    /// When the funds of Vanguard, Xtrackers and Amundi became sources: their
    /// holdings stored earlier were borrowed from a similar fund and are loaded again.
    static let issuersAdded = Date(timeIntervalSince1970: 1_794_096_000) // 2026-11-08

    /// The fund's provider is one of the sources that are found by name.
    static func hasOwnSource(_ name: String) -> Bool {
        IShares.isIShares(name) || Vanguard.isVanguard(name) || Xtrackers.isXtrackers(name) || Amundi.isAmundi(name)
    }

    /// Tries the providers in turn. nil: none of them knows the fund.
    ///
    /// iShares, Vanguard, Xtrackers and Amundi are found by the fund's name, and
    /// are skipped without a single call when the name isn't theirs. They also know
    /// European funds. SSGA and Invesco only know US tickers.
    ///
    /// Network errors make a provider count as not knowing the fund; a bond fund
    /// (`FundError.notEquity`) or a swap ETF (`FundError.swap`) is thrown on.
    /// Nordnet's holdings (see Nordnet.swift). Network errors count as not knowing the fund.
    static func nordnet(_ id: Int, name: String) async throws -> Found? {
        do {
            guard let found = try await Nordnet.holdings(id: id, name: name), !found.rows.isEmpty else { return nil }
            return found
        } catch let error as FundError {
            throw error
        } catch {
            return nil
        }
    }

    static func holdings(_ symbol: String, name: String? = nil) async throws -> Found? {
        func attempt(_ load: () async throws -> Found?) async throws -> Found? {
            do {
                guard let found = try await load(), !found.rows.isEmpty else { return nil }
                return found
            } catch let error as FundError {
                throw error
            } catch {
                return nil
            }
        }
        if let name {
            if IShares.isIShares(name),
               let found = try await attempt({ Found(rows: try await IShares.holdings(symbol: symbol, name: name), source: "iShares") }) {
                return found
            }
            if Vanguard.isVanguard(name),
               let found = try await attempt({ try await Vanguard.holdings(symbol: symbol, name: name) }) {
                return found
            }
            if Xtrackers.isXtrackers(name),
               let found = try await attempt({ try await Xtrackers.holdings(symbol: symbol, name: name) }) {
                return found
            }
            if Amundi.isAmundi(name),
               let found = try await attempt({ try await Amundi.holdings(symbol: symbol, name: name) }) {
                return found
            }
        }
        guard !symbol.contains(".") else { return nil }
        if let found = try await attempt({ Found(rows: try await ssga(symbol), source: "SSGA") }) { return found }
        if let found = try await attempt({ Found(rows: try await invesco(symbol), source: "Invesco") }) { return found }
        return nil
    }

    /// The SPDR funds' daily spreadsheet. 404 for all other funds.
    static func ssga(_ symbol: String) async throws -> [Row] {
        let ticker = symbol.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "https://www.ssga.com/us/en/intermediary/library-content/products/fund-data/etfs/us/holdings-daily-us-en-\(ticker).xlsx") else { return [] }
        let (data, response) = try await Net.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketError.http(status) }
        let rows = try XLSX.rows(data)
        // At the top are the fund's name and date; the table starts at "Name".
        guard let header = rows.firstIndex(where: { $0.first == "Name" }) else { return [] }
        let columns = rows[header]
        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }
        guard let nameColumn = column("Name"), let tickerColumn = column("Ticker"),
              let weightColumn = column("Weight") else { return [] }
        let currencyColumn = column("Local Currency")
        return rows[(header + 1)...].compactMap { row in
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard let weight = Double(cell(weightColumn)), !cell(nameColumn).isEmpty else { return nil }
            let currency = cell(currencyColumn)
            return Row(name: cell(nameColumn), ticker: cell(tickerColumn),
                       currency: currency.isEmpty ? "USD" : currency, weight: weight)
        }
    }

    private struct InvescoPayload: Decodable {
        let holdings: [Holding]?
        struct Holding: Decodable {
            let ticker: String?
            let issuerName: String?
            let percentageOfTotalNetAssets: Double?
            let securityTypeName: String?
            let currency: String?
        }
    }

    /// Invesco's ETFs (QQQ, RSP, SPHD …).
    static func invesco(_ symbol: String) async throws -> [Row] {
        let ticker = symbol.uppercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "https://dng-api.invesco.com/cache/v1/accounts/en_US/shareclasses/\(ticker)/holdings/fund?idType=ticker&productType=ETF") else { return [] }
        let (data, response) = try await Net.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketError.http(status) }
        let holdings = try JSONDecoder().decode(InvescoPayload.self, from: data).holdings ?? []
        return holdings.compactMap { holding in
            guard let weight = holding.percentageOfTotalNetAssets, let name = holding.issuerName,
                  holding.securityTypeName.map({ $0.localizedCaseInsensitiveContains("stock") || $0.localizedCaseInsensitiveContains("share") || $0.localizedCaseInsensitiveContains("REIT") }) ?? true
            else { return nil }
            return Row(name: name, ticker: holding.ticker ?? "", currency: holding.currency ?? "USD", weight: weight)
        }
    }
}

// MARK: - iShares

/// BlackRock's iShares: the full holdings as CSV on each fund's page
/// (`<page>/latest-holdings.csv`, the same file as "Download" under Holdings),
/// for US ETFs and European UCITS ETFs.
///
/// The fund's page is found in iShares' own product lists — the lists
/// the product search on ishares.com itself loads — by ticker or name. There
/// are three: US, UK (English, with the London tickers: SEMI, CSPX,
/// SWDA) and Germany (the Xetra tickers: SEC0, EUNL, SXR8, and German funds like
/// iShares Core DAX). The lists are stored for a week, like the holdings.
enum IShares {
    struct Product: Codable, Sendable {
        /// The fund's tickers in the lists, e.g. ["SEMI", "SEC0"].
        var tickers: [String]
        let isin: String
        /// The fund's name and the share class, when it is special ("Hedged EUR").
        let name: String
        /// The fund's page: "https://www.ishares.com/uk/individual/en/products/319084/…".
        let url: String
        /// US fund (ishares.com/us) or European.
        let us: Bool
    }

    struct Catalog: Codable {
        var products: [Product]
        var fetched: Date
    }

    /// The English list first: when a fund is in both European lists, its
    /// English page is used, and the CSV is then in English.
    private static let lists: [(url: String, us: Bool)] = [
        ("https://www.ishares.com/us/product-screener/product-screener-v3.1.jsn?dcrPath=/templatedata/config/product-screener-v3/data/en/us-ishares/ishares-product-screener-backend-config&siteEntryPassthrough=true", true),
        ("https://www.ishares.com/varnish-api/blk-product-screener-server/api/v1/product-screener/product-data?country=gb&language=en&siteName=ishares-uk&userType=individual", false),
        ("https://www.ishares.com/varnish-api/blk-product-screener-server/api/v1/product-screener/product-data?country=de&language=de&siteName=de-ishares-v2&userType=individual", false)
    ]

    private static var cacheURL: URL { FundStore.folder.appendingPathComponent("iShares.json") }

    /// The holdings for the fund with this Yahoo symbol and name. Empty when it
    /// isn't an iShares fund or isn't in the lists.
    static func holdings(symbol: String, name: String) async throws -> [FundSources.Row] {
        guard isIShares(name), let products = await catalog.products(),
              let product = match(symbol: symbol, name: name, in: products),
              let url = URL(string: product.url + "/latest-holdings.csv") else { return [] }
        let (data, response) = try await Net.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketError.http(status) }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Yahoo writes the name in full ("iShares Core MSCI World UCITS ETF") or
    /// abbreviated from the German exchanges ("iShsIII-Core MSCI World U.ETF").
    static func isIShares(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("ISHARES") || upper.hasPrefix("ISH")
    }

    // MARK: Find the fund

    /// First the ticker without exchange ("SEC0.DE" → "SEC0") among the funds from the same
    /// country, then the name. The name is needed because the lists only have one ticker
    /// per country: IWDA (Amsterdam) isn't listed anywhere, but "iShares Core MSCI
    /// World UCITS ETF USD (Acc)" is the same fund as SWDA and EUNL.
    static func match(symbol: String, name: String, in products: [Product]) -> Product? {
        let us = !symbol.contains(".")
        let ticker = String(symbol.split(separator: ".").first ?? "").uppercased()
        let candidates = products.filter { $0.us == us }
        if let found = candidates.first(where: { $0.tickers.contains(ticker) }) { return found }
        let words = nameWords(name)
        guard !words.isEmpty else { return nil }
        return candidates.first { nameWords($0.name) == words }
    }

    /// The name without share class and currency: "iShares Core S&P 500 UCITS ETF
    /// USD (Acc)" and "iShares Core S&P 500 UCITS ETF" are the same fund — all
    /// share classes have the same holdings. "Hedged" stays.
    static func nameWords(_ name: String) -> [String] {
        let noise: Set<String> = ["USD", "EUR", "GBP", "CHF", "JPY", "ACC", "DIST", "INC", "ACCUMULATING",
                                  "DISTRIBUTING", "ACCUMULATION", "DISTRIBUTION", "CLASS", "SHARE", "SHARES"]
        return name.uppercased()
            .replacingOccurrences(of: "&", with: " AND ")
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !noise.contains($0) }
    }

    // MARK: Product lists

    private static let catalog = CatalogLoader()

    /// Loads the lists one at a time, even when two funds ask at the same time.
    private actor CatalogLoader {
        private var cached: Catalog?
        private var running: Task<Catalog?, Never>?

        func products() async -> [Product]? {
            if cached == nil { cached = FundStore.readJSON(Catalog.self, from: IShares.cacheURL) }
            if let cached, Date().timeIntervalSince(cached.fetched) < FundStore.maxAge { return cached.products }
            let task = running ?? Task { await IShares.download() }
            running = task
            let fresh = await task.value
            running = nil
            if let fresh {
                cached = fresh
                return fresh.products
            }
            // If iShares doesn't answer, an old list is better than none.
            return cached?.products
        }
    }

    /// All three lists. If one of them fails, the rest are used, but the result isn't
    /// stored — so it is tried again next time.
    private static func download() async -> Catalog? {
        var byID: [String: Product] = [:]
        var order: [String] = []
        var complete = true
        for list in lists {
            guard let url = URL(string: list.url),
                  let (data, response) = try? await Net.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                complete = false
                continue
            }
            for (id, value) in root {
                guard let fields = value as? [String: Any], let product = product(fields, us: list.us) else { continue }
                // Same fund in the English and the German list: same id,
                // and the German ticker is added.
                let key = "\(list.us ? "us" : "eu"):\(id)"
                if var known = byID[key] {
                    for ticker in product.tickers where !known.tickers.contains(ticker) { known.tickers.append(ticker) }
                    byID[key] = known
                } else {
                    byID[key] = product
                    order.append(key)
                }
            }
        }
        guard !byID.isEmpty else { return nil }
        let catalog = Catalog(products: order.sorted().compactMap { byID[$0] }, fetched: Date())
        if complete { FundStore.writeJSON(catalog, to: cacheURL) }
        return catalog
    }

    /// Only ETFs: the index funds (without a ticker) have no holdings as CSV.
    private static func product(_ fields: [String: Any], us: Bool) -> Product? {
        guard let page = fields["productPageUrl"] as? String, page.hasPrefix("/"),
              let name = fields["fundName"] as? String else { return nil }
        let views = fields["productView"] as? [String] ?? []
        guard views.contains("etf") else { return nil }
        let ticker = (fields["localExchangeTicker"] as? String ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let shareClass = (fields["investorClassName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Product(
            tickers: ticker.isEmpty || ticker == "-" ? [] : [ticker],
            isin: fields["isin"] as? String ?? "",
            name: shareClass.isEmpty || shareClass == "-" ? name : "\(name) \(shareClass)",
            url: "https://www.ishares.com\(page)",
            us: us
        )
    }

    // MARK: The CSV

    /// At the top are the fund's name and date; the table starts at "Ticker" — in
    /// German "Emittententicker", with numbers like "1.234,56". Only stocks are included,
    /// not cash, futures and currency forwards.
    static func parse(_ text: String) -> [FundSources.Row] {
        let lines = text.components(separatedBy: .newlines)
        guard let header = lines.firstIndex(where: { $0.hasPrefix("Ticker,") || $0.hasPrefix("Emittententicker,") })
        else { return [] }
        let columns = CSV.fields(lines[header])
        let german = lines[header].hasPrefix("Emittententicker")
        func column(_ names: String...) -> Int? { names.lazy.compactMap { columns.firstIndex(of: $0) }.first }
        // The US files write the weight as "Weight (%)" or "Market Weight".
        guard let tickerColumn = column("Ticker", "Emittententicker"), let nameColumn = column("Name"),
              let weightColumn = column("Weight (%)", "Market Weight", "Gewichtung (%)") else { return [] }
        let assetColumn = column("Asset Class", "Anlageklasse")
        let sectorColumn = column("Sector", "Sektor")
        let exchangeColumn = column("Exchange", "Börse")
        let currencyColumn = column("Market Currency", "Marktwährung", "Currency", "Währung")

        return lines[(header + 1)...].compactMap { line in
            let row = CSV.fields(line)
            // The lines below the table (disclaimers, blank lines) have fewer fields.
            guard row.count > max(tickerColumn, nameColumn, weightColumn) else { return nil }
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard ["Equity", "Aktien"].contains(cell(assetColumn)) || assetColumn == nil,
                  let weight = number(cell(weightColumn), german: german), !cell(nameColumn).isEmpty
            else { return nil }
            let exchange = cell(exchangeColumn), currency = cell(currencyColumn)
            return FundSources.Row(
                name: cell(nameColumn), ticker: cell(tickerColumn),
                currency: currency.isEmpty ? "USD" : currency, weight: weight,
                exchange: exchange.isEmpty || exchange == "-" ? nil : exchange,
                sector: cell(sectorColumn).isEmpty ? nil : cell(sectorColumn)
            )
        }
    }

    private static func number(_ text: String, german: Bool) -> Double? {
        let plain = german
            ? text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            : text.replacingOccurrences(of: ",", with: "")
        return Double(plain.trimmingCharacters(in: .whitespaces))
    }
}

/// One line in a CSV: fields separated by commas, with quotes around fields
/// that contain a comma themselves ("1,234.56") and "" for a quote.
enum CSV {
    static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        var pending = iterator.next()
        while let char = pending {
            pending = iterator.next()
            if quoted {
                if char == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                quoted = true
            } else if char == "," {
                fields.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else {
                field.append(char)
            }
        }
        fields.append(field.trimmingCharacters(in: .whitespaces))
        return fields
    }
}

// MARK: - Spreadsheet

/// The minimum needed to read the first sheet of an .xlsx: a zip with
/// XML inside. Only what SSGA's files use — shared strings and numbers.
enum XLSX {
    enum Failure: Error { case notZip, missing(String), inflate }

    static func rows(_ data: Data) throws -> [[String]] {
        let files = try unzip(data, wanted: ["xl/sharedStrings.xml", "xl/worksheets/sheet1.xml"])
        guard let sheet = files["xl/worksheets/sheet1.xml"] else { throw Failure.missing("sheet1.xml") }
        let shared = files["xl/sharedStrings.xml"].map(sharedStrings) ?? []
        let xml = String(decoding: sheet, as: UTF8.self)
        var result: [[String]] = []
        for row in matches(#"<row[^>]*>(.*?)</row>"#, in: xml) {
            var cells: [String] = []
            for cell in allGroups(#"<c ([^>]*?)(?:/>|>(.*?)</c>)"#, in: row) {
                let attributes = cell[0], body = cell[1]
                // The column is in r="C12"; empty cells are missing entirely.
                if let ref = first(#"r="([A-Z]+)\d+""#, in: attributes) {
                    let column = ref.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
                    while cells.count < column { cells.append("") }
                }
                var value = first(#"<v>(.*?)</v>"#, in: body) ?? first(#"<t[^>]*>(.*?)</t>"#, in: body) ?? ""
                if attributes.contains(#"t="s""#), let i = Int(value), i < shared.count { value = shared[i] }
                cells.append(unescape(value).trimmingCharacters(in: .whitespaces))
            }
            result.append(cells)
        }
        return result
    }

    private static func sharedStrings(_ data: Data) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        return matches(#"<si>(.*?)</si>"#, in: xml).map { item in
            // A string can be split into several <t> pieces, each with its own formatting.
            matches(#"<t[^>]*>(.*?)</t>"#, in: item).joined()
        }
    }

    /// Unpacks the requested files: the central directory at the end of the zip points to
    /// each file, and deflate data is unpacked with the Compression framework.
    static func unzip(_ data: Data, wanted: Set<String>) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count > 22 else { throw Failure.notZip }
        var end = bytes.count - 22
        while end >= 0, u32(end) != 0x06054b50 { end -= 1 }
        guard end >= 0 else { throw Failure.notZip }
        let count = u16(end + 10)
        var pointer = u32(end + 16)
        var files: [String: Data] = [:]
        for _ in 0..<count {
            guard pointer + 46 <= bytes.count, u32(pointer) == 0x02014b50 else { throw Failure.notZip }
            let method = u16(pointer + 10)
            let compressed = u32(pointer + 20), size = u32(pointer + 24)
            let nameLength = u16(pointer + 28), extra = u16(pointer + 30), comment = u16(pointer + 32)
            let local = u32(pointer + 42)
            let name = String(decoding: bytes[(pointer + 46)..<(pointer + 46 + nameLength)], as: UTF8.self)
            pointer += 46 + nameLength + extra + comment
            guard wanted.contains(name), local + 30 <= bytes.count else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { throw Failure.notZip }
            let source = Array(bytes[start..<(start + compressed)])
            if method == 0 {
                files[name] = Data(source)
            } else if method == 8 {
                var output = [UInt8](repeating: 0, count: max(size, 1))
                let written = compression_decode_buffer(&output, output.count, source, source.count, nil, COMPRESSION_ZLIB)
                guard written == size else { throw Failure.inflate }
                files[name] = Data(output.prefix(written))
            }
        }
        return files
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        allGroups(pattern, in: text).map { $0[0] }
    }

    private static func allGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        allGroups(pattern, in: text).first?.first
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Funds whose own holdings can't be loaded (European UCITS ETFs,
/// Danish mutual funds, US mutual funds), but
/// which track a known index. The name decides it: "iShares Core DAX" tracks
/// DAX, "Sparindex INDEX OMX C25 KL" C25, and "iShares Core MSCI World UCITS"
/// the same index as URTH.
enum FundProxy: Equatable {
    /// One of the app's own indices.
    case index(String)
    /// A US ETF on the same or a similar index.
    case etf(String)

    /// Funds with a twist — sector, style, factor, leverage, sustainability —
    /// don't track the broad index, even if the name mentions it.
    private static let twists = [
        "INFORMATION TECHNOLOGY", "HEALTH", "FINANCIAL", "ENERGY", "UTILITIES", "INDUSTRIALS", "MATERIALS",
        "CONSUMER", "REAL ESTATE", "COMMUNICATION", "TEKNOLOGI", "SMALL", "MID CAP", "MIDCAP", "VALUE", "GROWTH",
        "MOMENTUM", "QUALITY", "MIN VOL", "MINIMUM", "ESG", "SRI", "ISLAMIC", "EQUAL", "DIVIDEND", "UDBYTTE",
        "LAV RISIKO", " EX ", "EX-", "SUSTAINAB", "BÆREDYGTIG", "LEVERAGED", "2X", "3X", "SHORT", "INVERSE",
        "COVERED", "CLIMATE", "PARIS", "SCREENED", "ENHANCED", "HEDGED", "BUFFER", "BOND", "OBLIGATION"
    ]

    private static let rules: [([String], FundProxy)] = [
        (["OMX C25", "OMXC25", "C25"], .index("c25")),
        (["EURO STOXX 50", "EUROSTOXX 50", "STOXX 50"], .index("sx5e")),
        (["DAX"], .index("dax")),
        (["FTSE 100"], .index("ftse")),
        (["CAC 40", "CAC40"], .index("cac")),
        (["OMXS30", "OMX STOCKHOLM 30"], .index("omxs30")),
        (["OMXH25", "HELSINKI 25"], .index("omxh25")),
        (["OBX"], .index("obx")),
        (["SMI"], .index("smi")),
        (["AEX"], .index("aex")),
        (["DOW JONES INDUSTRIAL", "DJIA", "DOW 30"], .index("dji")),
        (["NASDAQ 100", "NASDAQ-100", "NASDAQ100"], .index("ndx")),
        (["S&P 500", "S&P500", "500 INDEX", "US 500", "USA 500"], .index("sp500")),
        // World index: SPDR Portfolio MSCI Global Stock Market (MSCI ACWI
        // IMI) is the closest fund whose holdings can be loaded. MSCI World
        // doesn't include emerging markets, but the largest stocks are the same.
        (["FTSE ALL-WORLD", "FTSE ALL WORLD", "ALL-WORLD", "TOTAL WORLD", "MSCI ACWI", "ACWI", "ALL COUNTRY WORLD",
          "MSCI WORLD", "GLOBALE AKTIER", "GLOBAL INDEKS", "GLOBAL INDEX", "DEVELOPED WORLD", "CORE WORLD"], .etf("SPGM")),
        (["EMERGING"], .etf("SPEM")),
        (["STOXX EUROPE 600", "STOXX 600", "MSCI EUROPE", "DEVELOPED EUROPE", "EUROPA", "EUROPE"], .etf("SPEU")),
        (["TOTAL STOCK MARKET", "TOTAL MARKET", "CRSP US TOTAL"], .etf("SPTM"))
    ]

    static func match(_ name: String) -> FundProxy? {
        let upper = " \(name.uppercased()) "
        if twists.contains(where: { upper.contains($0) }) { return nil }
        for (patterns, proxy) in rules {
            for pattern in patterns where containsWord(upper, pattern) { return proxy }
        }
        return nil
    }

    /// The pattern as whole words, so "DAX" isn't found in "MIDAXX".
    private static func containsWord(_ text: String, _ pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern.trimmingCharacters(in: .whitespaces))
        return text.range(of: "(^|[^A-Z0-9])\(escaped)([^A-Z0-9]|$)", options: .regularExpression) != nil
    }
}

/// Yahoo's search. Needs neither a cookie nor a key.
enum YahooSearch {
    struct Quote: Decodable, Sendable {
        let symbol: String
        let quoteType: String?
        let exchange: String?
        let exchDisp: String?
        let longname: String?
        let shortname: String?
        let sector: String?
        let industry: String?

        var name: String { longname ?? shortname ?? symbol }
        var exchangeName: String? { exchDisp }
    }

    private struct Payload: Decodable { let quotes: [Quote]? }

    /// German regional exchanges, Xetra copies and the like — never the primary listing
    /// the fund holds.
    static let euroSuffixes: Set<String> = ["DE", "PA", "AS", "MI", "MC", "BR", "HE", "IR", "LS", "VI"]
    static let secondarySuffixes: Set<String> = ["F", "MU", "DU", "BE", "SG", "HM", "HA", "XC", "XD", "AQ", "IL", "NE", "BD", "VI", "MX", "BA", "SN"]
    static let primarySuffixes: Set<String> = [
        "T", "TO", "V", "AX", "HK", "KS", "KQ", "TW", "TWO", "SI", "NZ", "SA", "JO", "TA", "SS", "SZ", "NS", "BO",
        "L", "CO", "ST", "OL", "HE", "SW", "DE", "PA", "AS", "MI", "MC", "BR", "IR", "LS", "WA", "IS", "PR", "AT"
    ]

    static func quotes(_ query: String, count: Int, attempt: Int = 0) async -> [Quote]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let host = attempt % 2 == 0 ? "query2" : "query1"
        guard let url = URL(string: "https://\(host).finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=\(count)&newsCount=0&listsCount=0") else { return nil }
        do {
            let (data, response) = try await Net.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 3 {
                // Same wait as the spark calls in Yahoo.swift.
                try? await Task.sleep(for: .seconds(1.2 * Double(attempt + 1)))
                return await quotes(query, count: count, attempt: attempt + 1)
            }
            guard status == 200 else { return nil }
            return try JSONDecoder().decode(Payload.self, from: data).quotes ?? []
        } catch {
            if attempt < 1 { return await quotes(query, count: count, attempt: attempt + 1) }
            return nil
        }
    }

    /// Yahoo's sector names translated to GICS, as in Scripts/update-indices.py.
    static func gicsSector(_ sector: String?) -> String {
        switch sector ?? "" {
        case "Technology": return "Information Technology"
        case "Healthcare": return "Health Care"
        case "Financial Services": return "Financials"
        case "Consumer Cyclical": return "Consumer Discretionary"
        case "Consumer Defensive": return "Consumer Staples"
        case "Basic Materials": return "Materials"
        case "": return "Øvrige"
        default: return sector!
        }
    }

    /// The quote currency from the exchange.
    static func currency(for symbol: String) -> String {
        guard Symbols.isForeign(symbol), let suffix = symbol.split(separator: ".").last else { return "USD" }
        switch suffix {
        case "T": return "JPY"
        case "TO", "V": return "CAD"
        case "AX": return "AUD"
        case "HK": return "HKD"
        case "KS", "KQ": return "KRW"
        case "TW", "TWO": return "TWD"
        case "SI": return "SGD"
        case "NZ": return "NZD"
        case "SA": return "BRL"
        case "JO": return "ZAc"
        case "TA": return "ILA"
        case "SS", "SZ": return "CNY"
        case "NS", "BO": return "INR"
        case "L": return "GBp"
        case "CO": return "DKK"
        case "ST": return "SEK"
        case "OL": return "NOK"
        case "SW": return "CHF"
        case "WA": return "PLN"
        case "IS": return "TRY"
        default: return "EUR"
        }
    }
}
