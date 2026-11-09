import Foundation

/// Nasdaq Nordic, the exchange behind the Copenhagen indices, for the indices
/// whose day Yahoo doesn't have right: their 1D price, change and minute
/// series come from the exchange's own chart (`api.nasdaq.com/api/nordic`).
/// If Nasdaq doesn't answer, Yahoo's figure is used as long as it passes
/// `Yahoo.current`.
public enum NasdaqNordic {
    /// Yahoo symbol → Nasdaq Nordic orderbook id.
    static let orderbooks = [
        "^OMXC25": "IX14474"    // OMX Copenhagen 25 Index
    ]

    private struct Payload: Decodable {
        let data: DataBlock?
        struct DataBlock: Decodable {
            let chartData: ChartData?
            let CP: [Point]?
        }
        struct ChartData: Decodable {
            let lastSalePrice: String?
            let previousClose: String?
        }
        struct Point: Decodable {
            let x: Int
            let y: Double?
        }
    }

    /// "2,025.15" → 2025.15.
    private static func number(_ text: String?) -> Double? {
        text.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    /// The day: the price, the previous close and the minute closes.
    private static func day(_ symbol: String) async -> (price: Double, previous: Double, series: Yahoo.Series)? {
        guard let id = orderbooks[symbol],
              let url = URL(string: "https://api.nasdaq.com/api/nordic/instruments/\(id)/chart?assetClass=INDEXES&lang=en"),
              let (data, response) = try? await Net.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let block = (try? JSONDecoder().decode(Payload.self, from: data))?.data,
              let points = block.CP, !points.isEmpty,
              let previous = number(block.chartData?.previousClose), previous > 0 else { return nil }
        // Yahoo's day is in 5-minute bars, each stamped at its start with the
        // close at its end (09:00 holds 09:05's price). The minutes are put in
        // the same bars, so this index lines up with the others in a chart.
        var stamps: [Int] = [], closes: [Double?] = []
        for point in points {
            guard let close = point.y else { continue }
            let bar = (point.x - 60) / 300 * 300
            if bar == stamps.last { closes[closes.count - 1] = close } else { stamps.append(bar); closes.append(close) }
        }
        guard let price = number(block.chartData?.lastSalePrice) ?? (closes.last ?? nil), price > 0, !stamps.isEmpty else { return nil }
        return (price, previous, Yahoo.Series(timestamps: stamps, closes: closes, previousClose: previous))
    }

    static func values(_ symbols: [String]) async -> [String: Yahoo.Value] {
        await withTaskGroup(of: (String, Yahoo.Value?).self) { group in
            for symbol in symbols where orderbooks[symbol] != nil {
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
            for symbol in symbols where orderbooks[symbol] != nil {
                group.addTask { (symbol, await day(symbol)?.series) }
            }
            var result: [String: Yahoo.Series] = [:]
            for await (symbol, series) in group { if let series { result[symbol] = series } }
            return result
        }
    }
}
