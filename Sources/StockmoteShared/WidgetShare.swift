import Foundation

/// What the app shares with the widget.
///
/// The widget runs in a sandbox and can't read the app's UserDefaults. An app
/// group would be the usual route, but it requires an Apple developer team;
/// Stockmote is ad hoc signed. So the app writes a small file to
/// `~/Library/Application Support/Stockmote/`, and the widget has a
/// read-only exception for exactly that folder in its entitlements.
///
/// The file holds favourites, watchlists, classification and market cap —
/// but not prices. The widget fetches those itself from Yahoo, so it's fresh
/// even when the app hasn't been opened.
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

    /// An index as the widget's menu shows it.
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
    /// index ID → symbols
    public var indices: [String: [String]]
    public var stocks: [String: Stock]
    public var colorStyle: String
    /// Optional, so a file from an older version can still be read.
    public var indexList: [Index]?
    public var english: Bool?
    /// The app's theme: "system", "light" or "dark" (ThemeMode.rawValue).
    public var theme: String?
    /// Funds: fund ID → symbol → weight in percent. Tiles get the fund's weight
    /// instead of the market cap.
    public var weights: [String: [String: Double]]?

    public init(updated: Date, favorites: [String], watchlists: [List],
                indices: [String: [String]], stocks: [String: Stock], colorStyle: String,
                indexList: [Index], english: Bool, theme: String, weights: [String: [String: Double]]? = nil) {
        self.updated = updated
        self.favorites = favorites
        self.watchlists = watchlists
        self.indices = indices
        self.stocks = stocks
        self.colorStyle = colorStyle
        self.indexList = indexList
        self.english = english
        self.theme = theme
        self.weights = weights
    }

    /// The real home folder — also inside the sandbox, where
    /// `NSHomeDirectory()` points to the container.
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
