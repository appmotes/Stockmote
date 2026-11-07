import Foundation

/// Det appen deler med widget'en.
///
/// Widget'en kører i en sandbox og kan ikke læse appens UserDefaults. En app
/// group ville være den normale vej, men den kræver et Apple-udviklerhold;
/// Stockmote er ad hoc-signeret. Derfor skriver appen en lille fil i
/// `~/Library/Application Support/Stockmote/`, og widget'en har en
/// read-only-undtagelse til netop den mappe i sine entitlements.
///
/// Filen indeholder favoritter, watchlister, klassifikation og markedsværdi —
/// men ikke kurser. Dem henter widget'en selv fra Yahoo, så den er frisk selv
/// når appen ikke har været åbnet.
public struct WidgetShare: Codable {
    public struct Stock: Codable {
        public let name: String
        public let sector: String
        public let industry: String
        public let cap: Double?

        public init(name: String, sector: String, industry: String, cap: Double?) {
            self.name = name
            self.sector = sector
            self.industry = industry
            self.cap = cap
        }
    }

    public struct List: Codable {
        public let name: String
        public let symbols: [String]

        public init(name: String, symbols: [String]) {
            self.name = name
            self.symbols = symbols
        }
    }

    /// Et indeks som widget'ens menu viser det.
    public struct Index: Codable {
        public let id: String
        public let name: String
        public let flag: String?
        public let benchmark: String
        public let hours: MarketHours

        public init(id: String, name: String, flag: String?, benchmark: String, hours: MarketHours) {
            self.id = id
            self.name = name
            self.flag = flag
            self.benchmark = benchmark
            self.hours = hours
        }
    }

    public var updated: Date
    public var favorites: [String]
    public var watchlists: [List]
    /// indeks-id → symboler
    public var indices: [String: [String]]
    public var stocks: [String: Stock]
    public var colorStyle: String
    /// Valgfrie, så en fil fra en ældre version stadig kan læses.
    public var indexList: [Index]?
    public var english: Bool?
    /// Appens tema: "system", "light" eller "dark" (ThemeMode.rawValue).
    public var theme: String?

    public init(updated: Date, favorites: [String], watchlists: [List],
                indices: [String: [String]], stocks: [String: Stock], colorStyle: String,
                indexList: [Index], english: Bool, theme: String) {
        self.updated = updated
        self.favorites = favorites
        self.watchlists = watchlists
        self.indices = indices
        self.stocks = stocks
        self.colorStyle = colorStyle
        self.indexList = indexList
        self.english = english
        self.theme = theme
    }

    /// Den rigtige hjemmemappe — også inde i sandboxen, hvor
    /// `NSHomeDirectory()` peger på containeren.
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    public static var fileURL: URL {
        realHome.appendingPathComponent("Library/Application Support/Stockmote/Widget.json")
    }

    public static func read() -> WidgetShare? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetShare.self, from: data)
    }

    public func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}
