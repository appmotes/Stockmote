import Foundation
import StockmoteShared

/// Et selskab som det står i Indices.json: navn og GICS-klassifikation.
struct StockInfo: Codable, Hashable, Identifiable {
    let symbol: String
    let name: String
    let sector: String
    let industry: String
    /// Kursens valuta. "GBp" er pence.
    var currency: String? = "USD"
    /// Europæiske aktier: markedsværdi i `capCurrency` da kursen var
    /// `capPrice` (begge fra update-indices.py). Appen skalerer med den
    /// aktuelle kurs. Amerikanske aktier får markedsværdien fra Nasdaq.
    var cap: Double? = nil
    var capCurrency: String? = nil
    var capPrice: Double? = nil
    var id: String { symbol }

    var displaySymbol: String { Symbols.display(symbol) }
}

/// Et indeks og dets medlemmer.
struct MarketIndex: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// "us" eller "eu" — sidebjælkens grupper.
    var region: String? = "us"
    var flag: String? = nil
    /// Yahoo-symbolet for selve indekset, fx "^GSPC". Bruges til tallet i
    /// toppen og i menubaren.
    let benchmark: String
    var timezone: String? = nil
    var open: String? = nil
    var close: String? = nil
    let symbols: [String]

    var hours: MarketHours {
        guard let timezone, let open, let close else { return .newYork }
        return MarketHours(timezone: timezone, open: open, close: close)
    }

    var isEuropean: Bool { region == "eu" }
}

/// Indlæser indeksernes medlemmer fra Indices.json. Listen ligger i data og
/// ikke i koden, så den kan opdateres med Scripts/update-indices.sh uden at
/// røre Swift — og overstyres af brugeren uden at kompilere.
@MainActor
final class UniverseStore: ObservableObject {
    static let shared = UniverseStore()

    @Published private(set) var indices: [MarketIndex] = []
    @Published private(set) var info: [String: StockInfo] = [:]
    @Published private(set) var updated: String?
    @Published private(set) var loadError: String?
    @Published private(set) var sourceURL: URL?

    /// Alle symboler i alle indekser, uden dubletter.
    private(set) var allIndexSymbols: [String] = []

    private struct Payload: Decodable {
        let updated: String?
        let indices: [MarketIndex]
        let stocks: [StockInfo]
    }

    private init() {
        load()
    }

    func index(withID id: String) -> MarketIndex? {
        indices.first { $0.id == id }
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

    /// Brugerens override først, derefter .app-bundlen, derefter SwiftPM's
    /// ressourcebundle ved siden af binæren (så `swift run` også virker).
    static func candidateLocations() -> [URL] {
        var urls: [URL] = [userOverrideURL]
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("Indices.json"))
        }
        // SwiftPM lægger ressourcebundlen ved siden af binæren i .build/<config>/.
        let executableDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let bundle = executableDir.appendingPathComponent("Stockmote_Stockmote.bundle")
        urls.append(bundle.appendingPathComponent("Contents/Resources/Indices.json"))
        urls.append(bundle.appendingPathComponent("Indices.json"))
        return urls
    }

    /// `~/Library/Application Support/Stockmote/Indices.json`
    static var userOverrideURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Stockmote/Indices.json")
    }
}
