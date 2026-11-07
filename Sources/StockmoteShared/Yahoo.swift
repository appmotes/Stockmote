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
        return result
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
