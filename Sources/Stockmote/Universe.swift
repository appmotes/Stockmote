import Foundation
import StockmoteShared

/// A company as it appears in Indices.json: name and GICS classification.
struct StockInfo: Codable, Hashable, Identifiable {
    let symbol: String
    let name: String
    let sector: String
    let industry: String
    /// The price's currency. "GBp" is pence.
    var currency: String? = "USD"
    /// European stocks: market cap in `capCurrency` when the price was
    /// `capPrice` (both from update-indices.py). The app scales it by the
    /// current price. US stocks get their market cap from Nasdaq.
    var cap: Double? = nil
    var capCurrency: String? = nil
    var capPrice: Double? = nil
    var id: String { symbol }

    var displaySymbol: String { Symbols.display(symbol) }
}

/// An index and its members.
struct MarketIndex: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// "us" or "eu" — the sidebar's groups.
    var region: String? = "us"
    var flag: String? = nil
    /// The Yahoo symbol for the index itself, e.g. "^GSPC". Used for the number at
    /// the top and in the menu bar.
    let benchmark: String
    var timezone: String? = nil
    var open: String? = nil
    var close: String? = nil
    let symbols: [String]
    /// Funds only: each stock's weight in the fund in percent. The tiles' size
    /// follows it instead of market cap.
    var weights: [String: Double]? = nil

    /// "🇩🇰 C25", or just the name for a fund.
    var title: String { flag.map { "\($0) \(name)" } ?? name }

    var isFund: Bool { region == "fund" }

    var hours: MarketHours {
        guard let timezone, let open, let close else { return .newYork }
        return MarketHours(timezone: timezone, open: open, close: close)
    }

    var isEuropean: Bool { region == "eu" }

    /// The stocks' weights: the fund's own if it has them, otherwise market cap.
    @MainActor
    func weight(_ symbol: String) -> Double? {
        if let weights { return weights[symbol] }
        return MarketStore.shared.marketCap(symbol)
    }
}

/// Loads the indices' members from Indices.json. The list lives in data and
/// not in the code, so it can be updated with Scripts/update-indices.sh without
/// touching Swift — and overridden by the user without compiling.
@MainActor
final class UniverseStore: ObservableObject {
    static let shared = UniverseStore()

    @Published private(set) var indices: [MarketIndex] = []
    @Published private(set) var info: [String: StockInfo] = [:]
    @Published private(set) var updated: String?
    @Published private(set) var loadError: String?
    @Published private(set) var sourceURL: URL?

    /// All symbols in all indices, without duplicates.
    private(set) var allIndexSymbols: [String] = []

    private struct Payload: Decodable {
        let updated: String?
        let indices: [MarketIndex]
        let stocks: [StockInfo]
    }

    private init() {
        load()
    }

    /// An index — or a fund from the sidebar ("fund:SPY").
    func index(withID id: String) -> MarketIndex? {
        if FundStore.symbol(fromID: id) != nil { return FundStore.shared.index(withID: id) }
        return indices.first { $0.id == id }
    }

    func load() {
        guard let url = Self.candidateLocations().first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            fail("Indices.json blev ikke fundet.")
            return
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
            guard !payload.indices.isEmpty else {
                fail("Indices.json indeholder ingen indekser.")
                return
            }
            indices = payload.indices
            info = Dictionary(payload.stocks.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
            updated = payload.updated
            sourceURL = url
            loadError = nil
            var seen = Set<String>()
            allIndexSymbols = payload.indices.flatMap(\.symbols).filter { seen.insert($0).inserted }
        } catch {
            fail("Indices.json kunne ikke læses: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        indices = []
        info = [:]
        allIndexSymbols = []
        sourceURL = nil
        loadError = message
    }

    /// The user's override first, then the .app bundle, then SwiftPM's
    /// resource bundle next to the binary (so `swift run` works too).
    static func candidateLocations() -> [URL] {
        var urls: [URL] = [userOverrideURL]
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("Indices.json"))
        }
        // SwiftPM puts the resource bundle next to the binary in .build/<config>/.
        let executableDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let bundle = executableDir.appendingPathComponent("Stockmote_Stockmote.bundle")
        urls.append(bundle.appendingPathComponent("Contents/Resources/Indices.json"))
        urls.append(bundle.appendingPathComponent("Indices.json"))
        return urls
    }

    /// `~/Library/Application Support/Stockmote/Indices.json`
    nonisolated static var userOverrideURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Stockmote/Indices.json")
    }
}
