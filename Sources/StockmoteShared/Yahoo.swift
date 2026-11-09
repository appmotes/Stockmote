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
        /// The date of the price the change is measured from, where the range
        /// alone doesn't say it: the close three years ago for 3Å, the first
        /// price for Alt.
        public let since: Date?

        public init(price: Double, change: Double, since: Date? = nil) {
            self.price = price
            self.change = change
            self.since = since
        }
    }

    private struct Payload: Decodable {
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
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let firstTradeDate: Int?
            let regularMarketTime: Int?
        }
        struct Indicators: Decodable { let quote: [Quote]? }
        struct Quote: Decodable { let close: [Double?]? }
    }

    /// True when the symbol's first price is after the range began: then
    /// Yahoo measures from the listing, which isn't the change over the range,
    /// so the symbol gets no figure for it.
    static func listedTooLate(_ firstTradeDate: Int?, _ period: Period) -> Bool {
        guard let firstTradeDate, let start = period.start() else { return false }
        return TimeInterval(firstTradeDate) > start.timeIntervalSince1970
    }

    /// For 1D: whether the day's series is from the day Yahoo says the symbol
    /// last traded. ^OMXC25 has come back with Friday's afternoon as Monday's
    /// series, and a previous close a day too old with it (+0.14 % for a day
    /// Nasdaq put at +0.81 %); such a day is not used. A series without
    /// timestamps can't be checked and is let through.
    static func current(lastTrade: Int?, timestamps: [Int]?, closes: [Double?]?) -> Bool {
        guard let lastTrade, let timestamps, let closes, !timestamps.isEmpty else { return true }
        let day = lastTrade / 86_400
        return zip(timestamps, closes).contains { $0.0 / 86_400 == day && $0.1 != nil }
    }

    /// Checks Yahoo's `chartPreviousClose` against the series it came with.
    /// For some symbols it is simply yesterday's close whatever the range
    /// (OBX.OL: −1.33 % for 1Å, 5Å and Alt alike, with a one-point series), so
    /// a range's figure is only trusted when the series starts at the range's
    /// start and its first close is near the base (within ×1.5 either way —
    /// one bar's move). For Alt the series must begin near the first trade
    /// date to be checked: Yahoo's long histories in quarters start decades
    /// after the first price (^GSPC: 1927 vs 1984), and those are left as they
    /// are. Its first bar is a month or a quarter, often just after a listing
    /// (Amazon's first month: 0.122 → 0.077), so it is allowed ×4 (OBX.OL's
    /// "first price" is ×11 off its first close).
    static func consistent(base: Double, timestamps: [Int]?, closes: [Double?]?, firstTradeDate: Int?,
                           period: Period, interval: String) -> Bool {
        guard period != .day else { return true }
        guard let timestamps, let closes, let index = closes.firstIndex(where: { $0 != nil }),
              let first = closes[index], index < timestamps.count else { return false }
        let barDays: Double = switch interval {
            case "1mo": 40
            case "3mo": 100
            case "1wk": 10
            default: 5
        }
        let begins = TimeInterval(timestamps[index])
        if let start = period.start() {
            guard begins <= start.timeIntervalSince1970 + barDays * 86_400 else { return false }
        } else if let firstTradeDate, begins - TimeInterval(firstTradeDate) > 400 * 86_400 {
            return true
        }
        let ratio = first / base
        let tolerance = period == .all ? 4.0 : 1.5
        return ratio > 1 / tolerance && ratio < tolerance
    }

    /// Price and percentage change per symbol. Four calls at a time.
    ///
    /// Every figure is read from the symbol's own prices: the change from the
    /// close before the range to the latest price. 3Å comes from the daily
    /// series (see `Period.yahooRange`); Alt from the first price Yahoo has,
    /// which is a different date for every symbol — `since` says which.
    public static func fetch(_ symbols: [String], period: Period, concurrency: Int = 4) async -> [String: Value] {
        if period.baseFromSeries {
            let series = await fetchSeries(symbols, period: period, interval: period.yahooInterval)
            return series.compactMapValues { item in
                guard let last = item.closes.last(where: { $0 != nil }) ?? nil else { return nil }
                return Value(price: last, change: (last / item.previousClose - 1) * 100, since: item.since)
            }
        }
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
        result.merge(navValues) { _, nav in nav }
        if period == .day {
            result.merge(await NasdaqNordic.values(symbols)) { _, nasdaq in nasdaq }
        }
        return result
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
                guard let response = item.response?.first, let meta = response.meta,
                      let price = meta.regularMarketPrice,
                      !listedTooLate(meta.firstTradeDate, period) else { continue }
                // With `max`, chartPreviousClose is the first price Yahoo has.
                // Should it be missing, the first close in the series is the
                // same thing, a little later.
                var base = meta.chartPreviousClose
                if base == nil, period == .all {
                    base = response.indicators?.quote?.first?.close?.first(where: { $0 != nil }) ?? nil
                }
                guard let previous = base, previous > 0,
                      period != .day || current(lastTrade: meta.regularMarketTime, timestamps: response.timestamp,
                                                closes: response.indicators?.quote?.first?.close),
                      consistent(base: previous, timestamps: response.timestamp, closes: response.indicators?.quote?.first?.close,
                                 firstTradeDate: meta.firstTradeDate, period: period, interval: period.yahooInterval) else { continue }
                let symbol = lookup[item.symbol] ?? item.symbol
                let since = period == .all ? meta.firstTradeDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
                values[symbol] = Value(price: price, change: (price / previous - 1) * 100, since: since)
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
    /// week, days up to six months, weeks for one and five years, months for
    /// Alt (Yahoo gives quarters for long histories). 3Å plays the same daily
    /// closes its figure comes from, so the curve ends on the title's figure;
    /// the replay thins every series to at most 400 frames.
    public var replayInterval: String {
        switch self {
        case .day: return "5m"
        case .week: return "30m"
        case .month, .quarter, .halfYear, .ytd, .threeYears: return "1d"
        case .year, .fiveYears: return "1wk"
        case .all: return "1mo"
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
        /// The date of `previousClose` for 3Å and Alt (see `Value.since`).
        public var since: Date? = nil
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
        struct Meta: Decodable {
            let chartPreviousClose: Double?
            let firstTradeDate: Int?
            let regularMarketTime: Int?
        }
        struct Indicators: Decodable { let quote: [Quote]? }
        struct Quote: Decodable { let close: [Double?]? }
    }

    /// Series for many symbols, 20 per call, three at a time. The interval is
    /// the replay's unless given.
    public static func fetchSeries(_ symbols: [String], period: Period, interval: String? = nil) async -> [String: Series] {
        let interval = interval ?? period.replayInterval
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
                group.addTask { await fetchSeriesChunk(chunk, period: period, interval: interval) }
            }
            while let partial = await group.next() {
                result.merge(partial) { _, new in new }
                if let chunk = iterator.next() {
                    group.addTask { await fetchSeriesChunk(chunk, period: period, interval: interval) }
                }
            }
        }
        result.merge(navSeries) { _, nav in nav }
        if period == .day {
            result.merge(await NasdaqNordic.allSeries(symbols)) { _, nasdaq in nasdaq }
        }
        return result
    }

    private static func fetchSeriesChunk(_ symbols: [String], period: Period, interval: String, attempt: Int = 0) async -> [String: Series] {
        var lookup: [String: String] = [:]
        for symbol in symbols { lookup[Symbols.yahoo(symbol)] = symbol }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._,")
        let joined = lookup.keys.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let host = attempt % 2 == 0 ? "query1" : "query2"
        guard let url = URL(string: "https://\(host).finance.yahoo.com/v7/finance/spark?symbols=\(joined)&range=\(period.yahooRange)&interval=\(interval)") else {
            return [:]
        }
        do {
            let (data, response) = try await Net.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 3 {
                try? await Task.sleep(for: .seconds(1.2 * Double(attempt + 1)))
                return await fetchSeriesChunk(symbols, period: period, interval: interval, attempt: attempt + 1)
            }
            guard status == 200 else { return [:] }
            var values: [String: Series] = [:]
            for item in try JSONDecoder().decode(SeriesPayload.self, from: data).spark?.result ?? [] {
                guard let response = item.response?.first,
                      let timestamps = response.timestamp,
                      let closes = response.indicators?.quote?.first?.close,
                      timestamps.count == closes.count else { continue }
                let symbol = lookup[item.symbol] ?? item.symbol
                if period.baseFromSeries {
                    if let series = trimmed(timestamps, closes, to: period) { values[symbol] = series }
                    continue
                }
                guard let previous = response.meta?.chartPreviousClose, previous > 0,
                      period != .day || current(lastTrade: response.meta?.regularMarketTime, timestamps: timestamps, closes: closes),
                      !listedTooLate(response.meta?.firstTradeDate, period),
                      consistent(base: previous, timestamps: timestamps, closes: closes,
                                 firstTradeDate: response.meta?.firstTradeDate, period: period, interval: interval) else { continue }
                let since = period == .all ? response.meta?.firstTradeDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
                values[symbol] = Series(timestamps: timestamps, closes: closes, previousClose: previous, since: since)
            }
            return values
        } catch {
            if attempt < 1 { return await fetchSeriesChunk(symbols, period: period, interval: interval, attempt: attempt + 1) }
            return [:]
        }
    }
}

extension Yahoo {
    /// For a range Yahoo can't be asked for directly (3Å): the series from the
    /// close on or just before the range's start. Daily bars are stamped at
    /// the open, so the base is the last close before that moment — the same
    /// rule as `chartPreviousClose`. If the series doesn't reach back that far
    /// (listed later, or a gap of more than ten days), there is no figure: a
    /// shorter span would be a different number under the same label.
    static func trimmed(_ timestamps: [Int], _ closes: [Double?], to period: Period) -> Series? {
        guard let start = period.start() else { return nil }
        let cut = Int(start.timeIntervalSince1970)
        guard let base = timestamps.indices.last(where: { timestamps[$0] < cut && closes[$0] != nil }),
              cut - timestamps[base] <= 10 * 86_400,
              let previous = closes[base], previous > 0 else { return nil }
        return Series(timestamps: Array(timestamps[(base + 1)...]), closes: Array(closes[(base + 1)...]),
                      previousClose: previous, since: Date(timeIntervalSince1970: TimeInterval(timestamps[base])))
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
/// out: the app then shows an indicative value from the holdings' own prices,
/// weighted as in the fund, marked "≈ … indicative" (the customary iNAV).
public enum FundNAV {
    public static let prefix = "NAV:"

    public static func isNAV(_ symbol: String) -> Bool { symbol.hasPrefix(prefix) }

    /// Daily NAV over the period: the points in it, and the NAV just before it
    /// as the previous close — for Alt the fund's first NAV. Nothing for the
    /// day (today's NAV comes in the evening) or when the fund is younger than
    /// the range.
    public static func series(_ symbol: String, period: Period) async -> Yahoo.Series? {
        guard period != .day else { return nil }
        let start = period.start()
        let parts = symbol.dropFirst(prefix.count).split(separator: ":").map(String.init)
        guard let id = parts.first, !id.isEmpty else { return nil }
        let currency = parts.count > 1 ? parts[1] : "DKK"
        let from = start?.addingTimeInterval(-14 * 86_400) ?? Date(timeIntervalSince1970: 0)
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
        let cut = start?.timeIntervalSince1970 ?? -.infinity
        var previous: (time: Double, nav: Double)?
        var stamps: [Int] = [], closes: [Double?] = []
        for point in points where point.count >= 2 {
            let time = point[0] / 1000
            if previous == nil, period == .all { previous = (time, point[1]); continue }
            if time < cut { previous = (time, point[1]) } else { stamps.append(Int(time)); closes.append(point[1]) }
        }
        guard let previous, previous.nav > 0, !stamps.isEmpty else { return nil }
        let since = period == .all || period.baseFromSeries ? Date(timeIntervalSince1970: previous.time) : nil
        return Yahoo.Series(timestamps: stamps, closes: closes, previousClose: previous.nav, since: since)
    }

    /// Price and change over the period, from the NAV.
    static func value(_ symbol: String, period: Period) async -> Yahoo.Value? {
        guard let series = await series(symbol, period: period),
              let last = series.closes.last(where: { $0 != nil }) ?? nil else { return nil }
        return Yahoo.Value(price: last, change: (last / series.previousClose - 1) * 100, since: series.since)
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
