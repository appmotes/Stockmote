import Foundation

/// The day's figures straight from the exchange, for the indices whose
/// exchange shows them openly: Nasdaq Nordic for the Copenhagen, Stockholm
/// and Helsinki indices, Nasdaq for the Nasdaq-100. Their 1D price, previous
/// close and minute prices come from the exchange's own chart (both behind
/// `api.nasdaq.com`); every other range, and every other index, is Yahoo's.
/// If the exchange doesn't answer, Yahoo's figure is used as long as it
/// passes `Yahoo.current`.
///
/// The other indices' owners (S&P Dow Jones Indices, Deutsche Börse and
/// STOXX, FTSE Russell, Euronext, SIX) sell their data; there is nothing
/// open to read it from.
public enum ExchangeData {
    enum Feed {
        /// A Nasdaq Nordic orderbook id.
        case nordic(String)
        /// A Nasdaq (US) index symbol.
        case nasdaq(String)

        var source: DataSource { if case .nordic = self { return .nasdaqNordic } else { return .nasdaq } }
    }

    /// Yahoo symbol → the exchange's own feed.
    static let feeds: [String: Feed] = [
        "^OMXC25": .nordic("IX14474"),  // OMX Copenhagen 25 Index
        "^OMX": .nordic("IX447"),       // OMX Stockholm 30 Index
        "^OMXH25": .nordic("IX2165"),   // OMX Helsinki 25
        "^NDX": .nasdaq("NDX")          // Nasdaq-100
    ]

    private struct NordicPayload: Decodable {
        let data: DataBlock?
        struct DataBlock: Decodable {
            let chartData: ChartData?
            let CP: [Point]?
        }
        struct ChartData: Decodable {
            let lastSalePrice: String?
            let previousClose: String?
        }
    }

    private struct NasdaqPayload: Decodable {
        let data: DataBlock?
        struct DataBlock: Decodable {
            let lastSalePrice: String?
            let previousClose: String?
            let chart: [Point]?
        }
    }

    private struct Point: Decodable {
        let x: Int
        let y: Double?
    }

    /// "2,025.15" → 2025.15.
    private static func number(_ text: String?) -> Double? {
        text.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    /// The day: the price, the previous close and the closes in 5-minute bars.
    private static func day(_ symbol: String) async -> (price: Double, previous: Double, series: Yahoo.Series)? {
        guard let feed = feeds[symbol] else { return nil }
        let address: String
        switch feed {
        case .nordic(let id): address = "https://api.nasdaq.com/api/nordic/instruments/\(id)/chart?assetClass=INDEXES&lang=en"
        case .nasdaq(let id): address = "https://api.nasdaq.com/api/quote/\(id)/chart?assetclass=index"
        }
        guard let url = URL(string: address),
              let (data, response) = try? await Net.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        var points: [(time: Int, close: Double?)] = []
        var last: String?, before: String?
        switch feed {
        case .nordic:
            guard let block = (try? JSONDecoder().decode(NordicPayload.self, from: data))?.data else { return nil }
            // Unix seconds.
            points = (block.CP ?? []).map { ($0.x, $0.y) }
            last = block.chartData?.lastSalePrice
            before = block.chartData?.previousClose
        case .nasdaq:
            guard let block = (try? JSONDecoder().decode(NasdaqPayload.self, from: data))?.data else { return nil }
            // Milliseconds of New York's wall clock written as if it were
            // UTC ("9:30 AM ET" is 9:30 UTC): turned into real time.
            let newYork = TimeZone(identifier: "America/New_York") ?? .current
            points = (block.chart ?? []).map { point in
                let wall = point.x / 1000
                let offset = newYork.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall)))
                return (wall - offset, point.y)
            }
            last = block.lastSalePrice
            before = block.previousClose
        }
        guard let previous = number(before), previous > 0 else { return nil }

        // Yahoo's day is in 5-minute bars, each stamped at its start. The
        // minutes are put in the same bars (a bar holds its last minute), so
        // the exchange's line lines up with Yahoo's in a chart.
        var stamps: [Int] = [], closes: [Double?] = []
        for point in points {
            guard let close = point.close else { continue }
            let bar = point.time / 300 * 300
            if bar == stamps.last { closes[closes.count - 1] = close } else { stamps.append(bar); closes.append(close) }
        }
        guard let price = number(last) ?? (closes.last ?? nil), price > 0, !stamps.isEmpty else { return nil }
        // The line ends on the exchange's latest price, the figure's own.
        closes[closes.count - 1] = price
        return (price, previous, Yahoo.Series(timestamps: stamps, closes: closes, previousClose: previous))
    }

    static func values(_ symbols: [String]) async -> [String: Yahoo.Value] {
        await withTaskGroup(of: (String, Yahoo.Value?).self) { group in
            for symbol in symbols where feeds[symbol] != nil {
                group.addTask {
                    (symbol, await day(symbol).map { Yahoo.Value(price: $0.price, change: ($0.price / $0.previous - 1) * 100) })
                }
            }
            var result: [String: Yahoo.Value] = [:]
            for await (symbol, value) in group { if let value { result[symbol] = value } }
            return result
        }
    }

    static func allSeries(_ symbols: [String]) async -> [String: Yahoo.Series] {
        await withTaskGroup(of: (String, Yahoo.Series?).self) { group in
            for symbol in symbols where feeds[symbol] != nil {
                group.addTask { (symbol, await day(symbol)?.series) }
            }
            var result: [String: Yahoo.Series] = [:]
            for await (symbol, series) in group { if let series { result[symbol] = series } }
            return result
        }
    }
}

/// Where a figure came from, shown with it ("Kilde: Nasdaq Nordic").
public enum DataSource: String, Sendable {
    case yahoo, nasdaqNordic, nasdaq, morningstar

    public var name: String {
        switch self {
        case .yahoo: return "Yahoo Finance"
        case .nasdaqNordic: return "Nasdaq Nordic"
        case .nasdaq: return "Nasdaq"
        case .morningstar: return "Morningstar"
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [String: DataSource] = [:]

    /// The source of the latest figure fetched for a symbol and range.
    public static func of(_ symbol: String, _ period: Period) -> DataSource? {
        lock.lock(); defer { lock.unlock() }
        return sources["\(period.rawValue)|\(symbol)"]
    }

    static func record(_ symbols: some Sequence<String>, _ period: Period, _ source: DataSource) {
        lock.lock(); defer { lock.unlock() }
        for symbol in symbols { sources["\(period.rawValue)|\(symbol)"] = source }
    }
}
