import Foundation

public enum Net {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            // Nasdaq's API doesn't answer an anonymous CFNetwork user agent.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }()
}

/// Yahoo Finance's spark endpoint. No key, at most 20 symbols per call.
///
/// `chartPreviousClose` is the close just before the time range, so the change is
/// `regularMarketPrice / chartPreviousClose − 1`. With `range=1d` that's
/// yesterday's close, i.e. today's change.
public enum Yahoo {
    public struct Value: Sendable {
        public let price: Double
        public let change: Double
    }

    private struct Payload: Decodable {
        let spark: Spark?
        struct Spark: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let symbol: String
            let response: [Response]?
        }
        struct Response: Decodable { let meta: Meta? }
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
        }
    }

    /// Price and percentage change per symbol. Four calls at a time.
    public static func fetch(_ symbols: [String], period: Period, concurrency: Int = 4) async -> [String: Value] {
        let navs = symbols.filter(FundNAV.isNAV)
        let symbols = symbols.filter { !FundNAV.isNAV($0) }
        let navValues = navs.isEmpty ? [:] : await FundNAV.values(navs, period: period)
        let chunks = stride(from: 0, to: symbols.count, by: 20).map {
            Array(symbols[$0..<min($0 + 20, symbols.count)])
        }
        var result: [String: Value] = [:]
        await withTaskGroup(of: [String: Value].self) { group in
            var iterator = chunks.makeIterator()
            for _ in 0..<concurrency {
                guard let chunk = iterator.next() else { break }
                group.addTask { await fetchChunk(chunk, period: period) }
            }
            while let partial = await group.next() {
                result.merge(partial) { _, new in new }
                if let chunk = iterator.next() {
                    group.addTask { await fetchChunk(chunk, period: period) }
                }
            }
        }
        return result.merging(navValues) { _, nav in nav }
    }

    private static func fetchChunk(_ symbols: [String], period: Period, attempt: Int = 0) async -> [String: Value] {
        // Yahoo writes US share classes with a hyphen ("BRK-B"); European
        // stocks ("NOVO-B.CO"), indices ("^GSPC") and currencies ("EURUSD=X")
        // stay as they are. The response is mapped back via the table.
        var lookup: [String: String] = [:]
        for symbol in symbols { lookup[Symbols.yahoo(symbol)] = symbol }
        // "^" and "=" must be encoded, or Yahoo reads them as part of the URL.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._,")
        let joined = lookup.keys.joined(separator: ",")
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let host = attempt % 2 == 0 ? "query1" : "query2"
        guard let url = URL(string: "https://\(host).finance.yahoo.com/v7/finance/spark?symbols=\(joined)&range=\(period.yahooRange)&interval=\(period.yahooInterval)") else {
            return [:]
        }
        do {
            let (data, response) = try await Net.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 3 {
                // Yahoo throws 429s in bursts. Wait a little and try the other host.
                try? await Task.sleep(for: .seconds(1.2 * Double(attempt + 1)))
                return await fetchChunk(symbols, period: period, attempt: attempt + 1)
            }
            guard status == 200 else { return [:] }
            let results = try JSONDecoder().decode(Payload.self, from: data).spark?.result ?? []
            var values: [String: Value] = [:]
            for item in results {
                guard let meta = item.response?.first?.meta,
                      let price = meta.regularMarketPrice,
                      let previous = meta.chartPreviousClose, previous > 0 else { continue }
                let symbol = lookup[item.symbol] ?? item.symbol
                values[symbol] = Value(price: price, change: (price / previous - 1) * 100)
            }
            return values
        } catch {
            if attempt < 1 {
                return await fetchChunk(symbols, period: period, attempt: attempt + 1)
            }
            return [:]
        }
    }
}

// MARK: - Price series for "Afspil dagen" (Replay the day)

extension Period {
    /// Resolution for playback: 5 minutes for a day, half an hour for a
    /// week, days for months and weeks for a year.
    public var replayInterval: String {
        switch self {
        case .day: return "5m"
        case .week: return "30m"
        case .month, .quarter, .ytd: return "1d"
        case .year: return "1wk"
        }
    }
}

extension Yahoo {
    /// A symbol's series: timestamps (Unix seconds) and closing prices, plus
    /// the price before the time range, which the change is measured from.
    public struct Series: Sendable {
        public let timestamps: [Int]
        public let closes: [Double?]
        public let previousClose: Double
    }

    private struct SeriesPayload: Decodable {
        let spark: Spark?
        struct Spark: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let symbol: String
            let response: [Response]?
        }
        struct Response: Decodable {
            let meta: Meta?
            let timestamp: [Int]?
            let indicators: Indicators?
        }
        struct Meta: Decodable { let chartPreviousClose: Double? }
        struct Indicators: Decodable { let quote: [Quote]? }
        struct Quote: Decodable { let close: [Double?]? }
    }

    /// Series for many symbols, 20 per call, three at a time.
    public static func fetchSeries(_ symbols: [String], period: Period) async -> [String: Series] {
        let navs = symbols.filter(FundNAV.isNAV)
        let symbols = symbols.filter { !FundNAV.isNAV($0) }
        let navSeries = navs.isEmpty ? [:] : await FundNAV.allSeries(navs, period: period)
        let chunks = stride(from: 0, to: symbols.count, by: 20).map {
            Array(symbols[$0..<min($0 + 20, symbols.count)])
        }
        var result: [String: Series] = [:]
        await withTaskGroup(of: [String: Series].self) { group in
            var iterator = chunks.makeIterator()
            for _ in 0..<3 {
                guard let chunk = iterator.next() else { break }
                group.addTask { await fetchSeriesChunk(chunk, period: period) }
            }
            while let partial = await group.next() {
                result.merge(partial) { _, new in new }
                if let chunk = iterator.next() {
                    group.addTask { await fetchSeriesChunk(chunk, period: period) }
                }
            }
        }
        return result.merging(navSeries) { _, nav in nav }
    }

    private static func fetchSeriesChunk(_ symbols: [String], period: Period, attempt: Int = 0) async -> [String: Series] {
        var lookup: [String: String] = [:]
        for symbol in symbols { lookup[Symbols.yahoo(symbol)] = symbol }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._,")
        let joined = lookup.keys.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let host = attempt % 2 == 0 ? "query1" : "query2"
        guard let url = URL(string: "https://\(host).finance.yahoo.com/v7/finance/spark?symbols=\(joined)&range=\(period.yahooRange)&interval=\(period.replayInterval)") else {
            return [:]
        }
        do {
            let (data, response) = try await Net.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 3 {
                try? await Task.sleep(for: .seconds(1.2 * Double(attempt + 1)))
                return await fetchSeriesChunk(symbols, period: period, attempt: attempt + 1)
            }
            guard status == 200 else { return [:] }
            var values: [String: Series] = [:]
            for item in try JSONDecoder().decode(SeriesPayload.self, from: data).spark?.result ?? [] {
                guard let response = item.response?.first,
                      let previous = response.meta?.chartPreviousClose, previous > 0,
                      let timestamps = response.timestamp,
                      let closes = response.indicators?.quote?.first?.close,
                      timestamps.count == closes.count else { continue }
                values[lookup[item.symbol] ?? item.symbol] = Series(timestamps: timestamps, closes: closes, previousClose: previous)
            }
            return values
        } catch {
            if attempt < 1 { return await fetchSeriesChunk(symbols, period: period, attempt: attempt + 1) }
            return [:]
        }
    }
}

// MARK: - Daily NAV for funds Yahoo doesn't know

/// Funds sold through Nordnet that aren't listed anywhere (Nordnet Danmark
/// Indeks, Nordnet Global Indeks …) have no Yahoo quote — only a daily NAV.
/// Their symbol is "NAV:<Morningstar id>:<currency>" ("NAV:F00000TH8X:DKK"),
/// and `Yahoo.fetch` and `Yahoo.fetchSeries` take the NAV from Morningstar's
/// public time series (the one behind the funds' pages) instead of asking Yahoo.
///
/// There is no NAV for today until the evening, so the day's change is left
/// out: the app then derives it from the holdings' own prices, weighted.
public enum FundNAV {
    public static let prefix = "NAV:"

    public static func isNAV(_ symbol: String) -> Bool { symbol.hasPrefix(prefix) }

    /// The start of the period; nil for the day.
    static func start(of period: Period, now: Date = Date()) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        switch period {
        case .day: return nil
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .ytd: return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        }
    }

    /// Daily NAV over the period: the points in it, and the NAV just before it
    /// as the previous close.
    public static func series(_ symbol: String, period: Period) async -> Yahoo.Series? {
        guard let start = start(of: period) else { return nil }
        let parts = symbol.dropFirst(prefix.count).split(separator: ":").map(String.init)
        guard let id = parts.first, !id.isEmpty else { return nil }
        let currency = parts.count > 1 ? parts[1] : "DKK"
        let from = start.addingTimeInterval(-14 * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let query = "id=\(id)%5D2%5D0%5DFOESP%24%24ALL&idtype=Morningstar&currencyId=\(currency)&frequency=daily"
            + "&startDate=\(formatter.string(from: from))&outputType=COMPACTJSON"
        guard let url = URL(string: "https://lt.morningstar.com/api/rest.svc/timeseries_price/t92wz0sj7c?\(query)"),
              let (data, response) = try? await Net.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let points = try? JSONDecoder().decode([[Double]].self, from: data) else { return nil }
        let cut = start.timeIntervalSince1970
        var previous: Double?
        var stamps: [Int] = [], closes: [Double?] = []
        for point in points where point.count >= 2 {
            let time = point[0] / 1000
            if time < cut { previous = point[1] } else { stamps.append(Int(time)); closes.append(point[1]) }
        }
        guard let previous, previous > 0, !stamps.isEmpty else { return nil }
        return Yahoo.Series(timestamps: stamps, closes: closes, previousClose: previous)
    }

    /// Price and change over the period, from the NAV.
    static func value(_ symbol: String, period: Period) async -> Yahoo.Value? {
        guard let series = await series(symbol, period: period),
              let last = series.closes.last(where: { $0 != nil }) ?? nil else { return nil }
        return Yahoo.Value(price: last, change: (last / series.previousClose - 1) * 100)
    }

    /// NAV symbols in the list, fetched in parallel.
    static func values(_ symbols: [String], period: Period) async -> [String: Yahoo.Value] {
        await withTaskGroup(of: (String, Yahoo.Value?).self) { group in
            for symbol in symbols { group.addTask { (symbol, await value(symbol, period: period)) } }
            var result: [String: Yahoo.Value] = [:]
            for await (symbol, value) in group { if let value { result[symbol] = value } }
            return result
        }
    }

    static func allSeries(_ symbols: [String], period: Period) async -> [String: Yahoo.Series] {
        await withTaskGroup(of: (String, Yahoo.Series?).self) { group in
            for symbol in symbols { group.addTask { (symbol, await series(symbol, period: period)) } }
            var result: [String: Yahoo.Series] = [:]
            for await (symbol, series) in group { if let series { result[symbol] = series } }
            return result
        }
    }
}
