import Compression
import Foundation
import StockmoteShared

// MARK: - Model

/// En fond man har tilføjet i sidebjælken: en ETF, en investeringsforening
/// eller lignende, kendt på sit Yahoo-symbol ("SPY", "EXS1.DE",
/// "SPIC25KL.CO").
struct Fund: Codable, Hashable, Identifiable {
    let symbol: String
    var name: String
    /// Yahoo's quoteType: "ETF", "MUTUALFUND" eller "EQUITY" (danske
    /// investeringsforeninger står ofte som aktier).
    var kind: String
    var exchange: String?

    var id: String { FundStore.id(symbol) }
    var displaySymbol: String { Symbols.display(symbol) }

    /// Navnet uden udbyderens fyldord, til sidebjælken: "State Street SPDR
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

    /// "ETF" eller "Fond" — til søgeresultater og værktøjstip.
    var kindLabel: String {
        kind == "ETF" ? "ETF" : tr("Fond", "Fund")
    }

    /// Fondens børs, ud fra symbolets suffiks. Bruges til "Åben · lukker …"
    /// og til hvor tit der opdateres.
    var hours: MarketHours {
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

/// Én aktie i en fond. Vægten er fondens egen i procent; nil når beholdningen
/// er lånt fra et af appens egne indekser, hvor felterne så får markedsværdi.
struct Holding: Codable, Hashable {
    let symbol: String
    let weight: Double?
}

/// En fonds beholdning som hentet. Gemmes på disken og hentes igen efter en
/// uge — beholdninger ændrer sig sjældent.
struct FundHoldings: Codable {
    var symbol: String
    /// Største først, højst `FundStore.maxHoldings`.
    var holdings: [Holding]
    /// Antal aktier i fonden før beskæring.
    var total: Int
    /// Hvor beholdningen kom fra: "zacks" eller "index".
    var source: String
    /// Når fondens egen beholdning ikke findes: den ETF eller det indeks der
    /// følger samme indeks ("URTH", "dax").
    var proxy: String?
    var fetched: Date
    /// Navn og sektor for aktier appen ellers ikke kender (japanske,
    /// canadiske …), slået op i Yahoo's søgning.
    var stocks: [StockInfo]
}

/// Et søgeresultat fra Yahoo.
struct FundSearchResult: Identifiable, Hashable {
    let symbol: String
    let name: String
    let kind: String
    let exchange: String
    var id: String { symbol }

    var fund: Fund { Fund(symbol: symbol, name: name, kind: kind, exchange: exchange) }
}

enum FundError: LocalizedError {
    case noSource(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .noSource(let name):
            return tr("Kunne ikke hente beholdningen for \(name). Fulde beholdninger findes for amerikanske ETF'er og for fonde der følger et kendt indeks.",
                      "Could not load the holdings for \(name). Full holdings are available for US ETFs and for funds that track a well-known index.")
        case .empty(let name):
            return tr("Kunne ikke hente beholdningen for \(name).", "Could not load the holdings for \(name).")
        }
    }
}

// MARK: - Butikken

/// Fonde i sidebjælken og deres beholdninger.
///
/// Listen over fonde gemmes i UserDefaults (så snapshot-tilstanden har sin
/// egen). Beholdninger og opslag af navne gemmes som cache i
/// `~/Library/Application Support/Stockmote/Funds/`.
///
/// En fond vises som et indeks: `index(withID:)` giver en `MarketIndex` med
/// beholdningen som medlemmer og fondens egen kurs som benchmark, så kort,
/// liste, afspilning, fuld skærm og widget virker uden særtilfælde.
@MainActor
final class FundStore: ObservableObject {
    static let shared = FundStore()

    /// Store fonde (MSCI World har ~1300 aktier) beskæres til de største, så
    /// Yahoo-kaldene holder sig på niveau med S&P 500.
    static let maxHoldings = 500
    /// Beholdningen hentes igen når den er ældre end en uge.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    nonisolated static func id(_ symbol: String) -> String { "fund:\(symbol)" }
    nonisolated static func symbol(fromID id: String) -> String? {
        id.hasPrefix("fund:") ? String(id.dropFirst(5)) : nil
    }

    @Published private(set) var funds: [Fund] = [] {
        didSet { save() }
    }
    @Published private(set) var holdings: [String: FundHoldings] = [:]
    /// Fond → hvad der sker lige nu ("Slår aktier op 40/130").
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]

    /// Klassifikation for aktier i fondene som ikke findes i Indices.json
    /// eller Nasdaq's screener.
    private(set) var info: [String: StockInfo] = [:]
    /// Navn fra fonden → aktie, slået op én gang og gemt. En tom streng
    /// betyder at opslaget ikke fandt noget.
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

    // MARK: Opslag

    func fund(_ symbol: String) -> Fund? { funds.first { $0.symbol == symbol } }

    func contains(_ symbol: String) -> Bool { fund(symbol) != nil }

    /// Fonden som indeks. Findes den, men er beholdningen ikke hentet endnu,
    /// er medlemslisten tom — kortet viser så at den hentes.
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

    /// Alle aktier i alle fonde.
    var allSymbols: Set<String> {
        Set(holdings.values.flatMap { $0.holdings.map(\.symbol) })
    }

    /// Aktiens vægt i fonden, i procent.
    func weight(of symbol: String, inIndex id: String) -> Double? {
        guard let fund = Self.symbol(fromID: id) else { return nil }
        return holdings[fund]?.holdings.first { $0.symbol == symbol }?.weight
    }

    /// "SSGA · de 500 største af 2.874 aktier" eller "Samme indeks som 🇩🇪 DAX".
    func sourceNote(_ symbol: String) -> String? {
        guard let loaded = holdings[symbol] else { return nil }
        var parts: [String] = []
        if loaded.source == "index", let proxy = loaded.proxy,
           let index = UniverseStore.shared.index(withID: proxy) {
            parts.append(tr("Samme indeks som \(index.title)", "Same index as \(index.title)"))
        } else if let proxy = loaded.proxy {
            parts.append(tr("Beholdning fra \(proxy) (\(loaded.source)), der følger et tilsvarende indeks",
                            "Holdings of \(proxy) (\(loaded.source)), which tracks a similar index"))
        } else {
            parts.append(tr("Beholdning fra \(loaded.source)", "Holdings from \(loaded.source)"))
        }
        if loaded.total > loaded.holdings.count {
            let shown = Format.integer(loaded.holdings.count), total = Format.integer(loaded.total)
            parts.append(tr("de \(shown) største af \(total) aktier", "the \(shown) largest of \(total) stocks"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Tilføj og fjern

    /// Tilføjer fonden (hvis den ikke er der) og henter beholdningen.
    func add(_ fund: Fund) {
        if !contains(fund.symbol) { funds.append(fund) }
        load(fund.symbol, force: false)
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

    /// Henter beholdninger der mangler eller er mere end en uge gamle.
    func refreshStale() {
        for fund in funds {
            let age = holdings[fund.symbol].map { Date().timeIntervalSince($0.fetched) } ?? .infinity
            if age > Self.maxAge { load(fund.symbol, force: false) }
        }
    }

    /// Henter beholdningen i baggrunden. `force` henter selv om den er frisk.
    func load(_ symbol: String, force: Bool) {
        guard tasks[symbol] == nil, let fund = fund(symbol) else { return }
        if !force, let loaded = holdings[symbol], Date().timeIntervalSince(loaded.fetched) < Self.maxAge { return }
        tasks[symbol] = Task { [weak self] in
            await self?.fetch(fund)
            self?.tasks[symbol] = nil
        }
    }

    /// Venter til beholdningen er hentet (til snapshot-tilstanden).
    func ensureLoaded(_ symbol: String) async {
        load(symbol, force: false)
        await tasks[symbol]?.value
    }

    private func fetch(_ fund: Fund) async {
        errors[fund.symbol] = nil
        progress[fund.symbol] = tr("Henter beholdningen…", "Loading holdings…")
        defer { progress[fund.symbol] = nil }
        do {
            let loaded = try await buildHoldings(fund)
            guard !Task.isCancelled, contains(fund.symbol) else { return }
            holdings[fund.symbol] = loaded
            for stock in loaded.stocks { info[stock.symbol] = stock }
            Self.writeJSON(loaded, to: Self.cacheURL(fund.symbol))
            // De nye aktier har ingen kurser endnu.
            let market = MarketStore.shared
            await market.loadPeriod(.day, force: false)
            if market.period != .day { await market.loadPeriod(market.period, force: false) }
        } catch {
            guard !Task.isCancelled else { return }
            // En gammel beholdning er bedre end ingen; fejlen vises kun når
            // der intet er.
            if holdings[fund.symbol] == nil {
                errors[fund.symbol] = error.localizedDescription
            }
        }
    }

    // MARK: Hentning

    /// Fondens egen beholdning hos udbyderen hvis den er amerikansk; ellers en
    /// fond eller et indeks der følger samme indeks (se `FundProxy`).
    private func buildHoldings(_ fund: Fund) async throws -> FundHoldings {
        if !fund.symbol.contains("."), let found = await FundSources.holdings(fund.symbol) {
            return try await fromRows(found.rows, source: found.source, fund: fund, proxy: nil)
        }
        switch FundProxy.match(fund.name) {
        case .index(let id)?:
            guard let index = UniverseStore.shared.index(withID: id), !index.symbols.isEmpty else { break }
            return FundHoldings(symbol: fund.symbol, holdings: index.symbols.map { Holding(symbol: $0, weight: nil) },
                                total: index.symbols.count, source: "index", proxy: id, fetched: Date(), stocks: [])
        case .etf(let etf)?:
            progress[fund.symbol] = tr("Henter beholdningen fra \(etf)…", "Loading holdings from \(etf)…")
            guard let found = await FundSources.holdings(etf) else { break }
            return try await fromRows(found.rows, source: found.source, fund: fund, proxy: etf)
        case nil:
            break
        }
        throw FundError.noSource(fund.name)
    }

    private func fromRows(_ rows: [FundSources.Row], source: String, fund: Fund, proxy: String?) async throws -> FundHoldings {
        let market = MarketStore.shared
        let universe = UniverseStore.shared
        // Kontanter, futures, pengemarkedsfonde og lignende er ikke aktier.
        var stocks = rows.filter { $0.weight > 0 && !FundSources.isNonEquity($0.name, ticker: $0.ticker) }
        stocks.sort { $0.weight > $1.weight }
        let total = stocks.count
        stocks = Array(stocks.prefix(Self.maxHoldings))

        var result: [Holding] = []
        var found: [StockInfo] = []
        var unresolved: [FundSources.Row] = []
        for row in stocks {
            if row.isUS, let us = row.yahooGuess {
                // Står den hverken i screeneren eller i indekserne, er det
                // nok en fond eller kontanter.
                if !market.quotes.isEmpty, market.quotes[us] == nil, universe.info[us] == nil { continue }
                result.append(Holding(symbol: us, weight: row.weight))
                if market.quotes[us] == nil, universe.info[us] == nil {
                    found.append(StockInfo(symbol: us, name: row.name.capitalized, sector: "Øvrige", industry: "Øvrige"))
                }
            } else {
                unresolved.append(row)
            }
        }

        // Udenlandske aktier: først Indices.json og tidligere opslag, så
        // Yahoo's søgning, fire ad gangen.
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
                progress[fund.symbol] = tr("Slår aktier op \(done)/\(count)…", "Looking up stocks \(done)/\(count)…")
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
        // Yahoo svarer 429 når der spørges meget. De opslag der fejlede prøves
        // én gang til, ét ad gangen. Fejler de stadig, gemmes de ikke — så
        // prøves de igen næste gang — og indtil da bruges tickeren som den
        // er, uden sektor.
        for row in failed {
            try? await Task.sleep(for: .milliseconds(400))
            if let match = await Self.yahooMatch(row) {
                names[Self.nameKey(row)] = match
                matches.append((row, match))
            } else if let guess = row.yahooGuess {
                matches.append((row, NameMatch(symbol: guess, info: nil)))
            }
        }
        if count > 0 { Self.writeJSON(names, to: Self.namesURL) }
        for (row, match) in matches where !match.symbol.isEmpty {
            result.append(Holding(symbol: match.symbol, weight: row.weight))
            if let info = match.info { found.append(info) }
        }

        // Samme aktie to gange (fx to aktieklasser der slås op til samme
        // symbol): læg vægten sammen.
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

    /// Navn og valuta: samme navn kan være to selskaber på to børser.
    nonisolated private static func nameKey(_ row: FundSources.Row) -> String {
        "\(row.name.uppercased())|\(row.currency)"
    }

    /// En europæisk aktie i et af appens indekser: samme symbol som gættet,
    /// samme ticker og samme første ord i navnet, eller helt samme navn.
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

    /// Navnet uden selskabsform og tegn: "ROLLS-ROYCE HOLDINGS PLC" → ["ROLLS", "ROYCE"].
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

    /// Slår et selskab op i Yahoo's søgning for at få sektor og branche — og
    /// symbolet, når det ikke kan gættes ud fra ticker og valuta (euro-aktier).
    /// Foretrækker gættet, ellers hovednoteringen (SAN.PA frem for BNP.F eller
    /// en OTC-ADR) og en ticker der passer med den fonden selv skriver.
    nonisolated private static func yahooMatch(_ row: FundSources.Row) async -> NameMatch? {
        // Først det gættede symbol ("RY.TO") — så svarer Yahoo med netop den
        // aktie. Ellers navnet, og til sidst de to første ord: søgningen
        // finder intet på "ROYAL BANK CANADA", men noget på "ROYAL BANK".
        let words = nameWords(row.name)
        var queries: [String] = []
        for query in [row.yahooGuess ?? "", words.prefix(4).joined(separator: " "), words.prefix(2).joined(separator: " ")] {
            if !query.isEmpty, !queries.contains(query) { queries.append(query) }
        }
        var answered = false
        for query in queries {
            guard let quotes = await YahooSearch.quotes(query, count: 8) else { continue }
            answered = true
            if let match = pick(quotes, for: row) { return match }
        }
        // Svarede Yahoo slet ikke, prøves det igen senere (nil). Svarede den
        // uden at kende aktien: tickeren som den er, uden sektor.
        return answered ? NameMatch(symbol: row.yahooGuess ?? "", info: nil) : nil
    }

    nonisolated private static func pick(_ quotes: [YahooSearch.Quote], for row: FundSources.Row) -> NameMatch? {
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
            return points
        }
        guard let best = equities.enumerated().max(by: { a, b in
            // Lige point: Yahoo's egen rækkefølge.
            (score(a.element), -a.offset) < (score(b.element), -b.offset)
        })?.element, score(best) > -10 else { return nil }
        // Et gæt ud fra ticker og valuta vinder over søgningens symbol — det
        // er udbyderens egen oplysning. Søgningen giver så kun sektoren.
        // Amerikanske klasse-aktier skrives med punktum internt ("BRK.B").
        let symbol = guess ?? (best.symbol.contains(".") && Symbols.isForeign(best.symbol)
            ? best.symbol
            : best.symbol.replacingOccurrences(of: "-", with: "."))
        let info = StockInfo(
            symbol: symbol, name: best.name,
            sector: YahooSearch.gicsSector(best.sector),
            industry: (best.industry ?? "Øvrige").replacingOccurrences(of: "—", with: " – "),
            currency: YahooSearch.currency(for: symbol)
        )
        return NameMatch(symbol: symbol, info: info)
    }

    // MARK: Søgning

    /// ETF'er og fonde der matcher teksten.
    nonisolated static func search(_ text: String) async -> [FundSearchResult] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, let quotes = await YahooSearch.quotes(query, count: 15) else { return [] }
        return quotes.compactMap { quote in
            let isFund = quote.quoteType == "ETF" || quote.quoteType == "MUTUALFUND"
                || (quote.quoteType == "EQUITY" && looksLikeFund(quote.name))
            guard isFund else { return nil }
            return FundSearchResult(symbol: quote.symbol, name: quote.name, kind: quote.quoteType ?? "",
                                    exchange: quote.exchangeName ?? quote.exchange ?? "")
        }
    }

    /// Danske investeringsforeninger står ofte som aktier hos Yahoo
    /// ("Sparindex INDEX OMX C25 KL").
    nonisolated private static func looksLikeFund(_ name: String) -> Bool {
        let words = Set(name.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !words.isDisjoint(with: ["ETF", "UCITS", "INDEX", "INDEKS", "KL", "FUND", "FOND", "SPARINDEX"])
    }

    // MARK: Filer

    private static var folder: URL {
        UniverseStore.userOverrideURL.deletingLastPathComponent().appendingPathComponent("Funds")
    }

    private static func cacheURL(_ symbol: String) -> URL {
        let safe = symbol.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent("\(safe).json")
    }

    private static var namesURL: URL { folder.appendingPathComponent("Names.json") }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Kilder

/// Kilder til fulde beholdninger. Ingen af dem kræver konto eller nøgle, og
/// ingen er et dokumenteret API — det er de filer udbyderne selv lægger frem
/// til download på fondenes sider.
///
/// - **State Street (SSGA)**: et regneark med hele beholdningen for alle
///   SPDR-ETF'er (SPY, XLK, SPGM …), opdateret dagligt.
/// - **Invesco**: JSON med hele beholdningen (QQQ, RSP …).
///
/// iShares og Vanguard kræver nu login eller svarer ikke uden en browser, og
/// Zacks og stockanalysis.com afviser andet end browsere — dem bruges ikke.
enum FundSources {
    struct Row: Sendable {
        let name: String
        /// Tickeren som udbyderen skriver den: "AAPL", "BRK.B", "7203", "NOVN".
        let ticker: String
        /// Handelsvaluta. Den afgør børsen: USD er en amerikansk aktie, JPY Tokyo.
        let currency: String
        /// Procent af fonden.
        let weight: Double

        var isUS: Bool { currency == "USD" }

        /// Yahoo-symbolet ud fra ticker og valuta, når valutaen kun har én
        /// børs. Euro-aktier (Paris, Frankfurt, Milano …) kan ikke gættes og
        /// slås op på navnet.
        var yahooGuess: String? {
            let t = ticker.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            switch currency {
            case "USD": return t.replacingOccurrences(of: "/", with: ".")
            case "JPY": return "\(t).T"
            case "HKD": return "\(String(repeating: "0", count: max(0, 4 - t.count)))\(t).HK"
            case "CAD": return "\(t.replacingOccurrences(of: ".", with: "-")).TO"
            case "AUD": return "\(t).AX"
            case "GBP", "GBp", "GBX":
                let base = t.hasSuffix(".") ? String(t.dropLast()) : t
                return "\(base.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-")).L"
            case "CHF": return "\(t).SW"
            case "SEK": return "\(t.replacingOccurrences(of: " ", with: "-")).ST"
            case "NOK": return "\(t).OL"
            case "DKK": return "\(t.replacingOccurrences(of: " ", with: "-")).CO"
            case "SGD": return "\(t).SI"
            case "ILS", "ILA": return "\(t.replacingOccurrences(of: ".", with: "")).TA"
            case "KRW": return "\(t.hasPrefix("A") ? String(t.dropFirst()) : t).KS"
            case "TWD": return "\(t).TW"
            case "NZD": return "\(t).NZ"
            case "INR": return "\(t).NS"
            case "BRL": return "\(t).SA"
            case "ZAR": return "\(t).JO"
            case "PLN": return "\(t).WA"
            default: return nil
            }
        }
    }

    /// Kontanter, futures, swaps og pengemarkedsfonde.
    static func isNonEquity(_ name: String, ticker: String) -> Bool {
        let upper = " \(name.uppercased()) "
        if ticker.isEmpty || ticker == "-" || ticker == "N/A" { return true }
        return ["CASH", "COLLATERAL", "FUTURE", "TREASURY", "T-BILL", "MONEY MARKET", "SWAP", "CURRENCY",
                "MARGIN", "DERIVATIVE", " FND ", " FUND ", "U.S. DOLLAR", "US DOLLAR", "FX CONTRACT", " MMF "]
            .contains { upper.contains($0) }
    }

    /// Prøver udbyderne efter tur. nil: ingen af dem kender fonden.
    static func holdings(_ symbol: String) async -> (rows: [Row], source: String)? {
        if let rows = try? await ssga(symbol), !rows.isEmpty { return (rows, "SSGA") }
        if let rows = try? await invesco(symbol), !rows.isEmpty { return (rows, "Invesco") }
        return nil
    }

    /// SPDR-fondenes daglige regneark. 404 for alle andre fonde.
    static func ssga(_ symbol: String) async throws -> [Row] {
        let ticker = symbol.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "https://www.ssga.com/us/en/intermediary/library-content/products/fund-data/etfs/us/holdings-daily-us-en-\(ticker).xlsx") else { return [] }
        let (data, response) = try await Net.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketError.http(status) }
        let rows = try XLSX.rows(data)
        // Øverst står fondens navn og dato; tabellen starter ved "Name".
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

    /// Invesco's ETF'er (QQQ, RSP, SPHD …).
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

// MARK: - Regneark

/// Det mindste der skal til for at læse første ark i en .xlsx: en zip med
/// XML indeni. Kun det SSGA's filer bruger — delte strenge og tal.
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
                // Kolonnen står i r="C12"; tomme celler mangler helt.
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
            // En streng kan være delt i flere <t>-stykker med hver sin formatering.
            matches(#"<t[^>]*>(.*?)</t>"#, in: item).joined()
        }
    }

    /// Pakker de ønskede filer ud: central-kataloget bagerst i zip'en peger på
    /// hver fil, og deflate-data pakkes ud med Compression-frameworket.
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

/// Fonde hvis egen beholdning ikke kan hentes (europæiske UCITS-ETF'er,
/// danske investeringsforeninger, amerikanske investeringsforeninger), men
/// som følger et kendt indeks. Navnet afgør det: "iShares Core DAX" følger
/// DAX, "Sparindex INDEX OMX C25 KL" C25 og "iShares Core MSCI World UCITS"
/// samme indeks som URTH.
enum FundProxy: Equatable {
    /// Et af appens egne indekser.
    case index(String)
    /// En amerikansk ETF på samme eller et tilsvarende indeks.
    case etf(String)

    /// Fonde med en drejning — sektor, stil, faktor, gearing, bæredygtighed —
    /// følger ikke det brede indeks, selv om navnet nævner det.
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
        // Verdensindeks: SPDR Portfolio MSCI Global Stock Market (MSCI ACWI
        // IMI) er den nærmeste fond hvis beholdning kan hentes. MSCI World
        // har ikke emerging markets med, men de største aktier er de samme.
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

    /// Mønsteret som hele ord, så "DAX" ikke findes i "MIDAXX".
    private static func containsWord(_ text: String, _ pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern.trimmingCharacters(in: .whitespaces))
        return text.range(of: "(^|[^A-Z0-9])\(escaped)([^A-Z0-9]|$)", options: .regularExpression) != nil
    }
}

/// Yahoo's søgning. Kræver hverken cookie eller nøgle.
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

    /// Tyske regionalbørser, Xetra-kopier o.l. — aldrig den hovednotering
    /// fonden ejer.
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
                // Samme ventetid som spark-kaldene i Yahoo.swift.
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

    /// Yahoo's sektornavne oversat til GICS, som i Scripts/update-indices.py.
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

    /// Kursvalutaen ud fra børsen.
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
