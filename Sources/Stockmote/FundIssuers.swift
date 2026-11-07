import Foundation
import StockmoteShared

// Fund providers whose holdings come from the JSON behind their own fund
// pages: Vanguard, Xtrackers (DWS) and Amundi. Like iShares, none of them needs an
// account or a key, and none is a documented API. Each has a product list
// (stored for a week) that turns the Yahoo symbol and name into the provider's
// own id, and one call for the holdings.

// MARK: - Shared

extension FundSources {
    /// Countries where companies are registered but rarely listed. For those, the
    /// provider's country of risk says more about where the stock trades: Linde is
    /// Irish but trades in New York, Tencent is Caymanian but trades in Hong Kong.
    static let offshore: Set<String> = ["KY", "BM", "VG", "IE", "JE", "GG", "IM", "LU", "PA", "CW", "MH", "LR",
                                        "BS", "PR", "MU", "GI", "AN", "VI"]

    /// A row from a provider that writes the ISIN and maybe a ticker, but no exchange.
    static func isinRow(name: String, ticker: String, isin: String?, weight: Double, sector: String?,
                        risk: String? = nil) -> Row {
        let isin = isin.flatMap { $0.count == 12 ? $0 : nil }
        let domicile = isin.map { String($0.prefix(2)) } ?? ""
        var country = offshore.contains(domicile) ? (risk ?? domicile) : domicile
        if country.isEmpty { country = risk ?? "" }
        return Row(name: name, ticker: ticker, currency: country == "US" ? "USD" : "", weight: weight,
                   sector: sector, isin: isin, country: country.isEmpty ? nil : country)
    }

    /// Calls a JSON endpoint. 404 and 204 are "doesn't know the fund" (nil).
    static func json(_ url: URL, post body: Any? = nil, headers: [String: String] = [:]) async throws -> Any? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Net.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 204 || data.isEmpty { return nil }
        guard status == 200 else { throw MarketError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func date(_ text: String?, format: String) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.date(from: String(text.prefix(format.count)))
    }

    /// "8.39%", "1,234.5" or a number.
    static func percent(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        guard let text = value as? String else { return nil }
        return Double(text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces))
    }
}

/// A provider's product list, stored on disk for a week. Loaded once at a
/// time, even when two funds ask at the same time; if the provider doesn't
/// answer, an old list is better than none.
actor ProductList<Product: Codable & Sendable> {
    private struct Stored: Codable {
        var products: [Product]
        var fetched: Date
    }

    private let file: String
    private let download: @Sendable () async -> [Product]?
    private var cached: Stored?
    private var running: Task<[Product]?, Never>?

    init(file: String, download: @escaping @Sendable () async -> [Product]?) {
        self.file = file
        self.download = download
    }

    func products() async -> [Product]? {
        let url = FundStore.folder.appendingPathComponent(file)
        if cached == nil { cached = FundStore.readJSON(Stored.self, from: url) }
        if let cached, Date().timeIntervalSince(cached.fetched) < FundStore.maxAge { return cached.products }
        let task = running ?? Task { await download() }
        running = task
        let fresh = await task.value
        running = nil
        if let fresh, !fresh.isEmpty {
            let stored = Stored(products: fresh, fetched: Date())
            cached = stored
            FundStore.writeJSON(stored, to: url)
            return fresh
        }
        return cached?.products
    }
}

/// The name as words without the provider and share class, for matching a Yahoo
/// name with a provider's: "Vanguard FTSE All-World UCITS ETF USD Accumulation" and
/// "Vanguard FTSE All-World UCITS ETF (USD) Accumulating" are the same fund.
private func fundWords(_ name: String, dropping: Set<String>) -> [String] {
    IShares.nameWords(name).filter { !dropping.contains($0) && $0 != "AND" }
}

// MARK: - Vanguard

/// Vanguard: US funds (VOO, VTI, VT …) from the JSON behind investor.vanguard.com's
/// fund pages, European UCITS ETFs (VWRL, VWCE, VUSA …) from the GraphQL service
/// behind vanguard.co.uk's. Vanguard publishes holdings once a month, a few weeks
/// after month end — the date is shown.
enum Vanguard {
    static func isVanguard(_ name: String) -> Bool {
        name.uppercased().contains("VANGUARD")
    }

    static func holdings(symbol: String, name: String) async throws -> FundSources.Found? {
        symbol.contains(".") ? try await ucits(symbol: symbol, name: name) : try await us(symbol, name: name)
    }

    // MARK: US

    /// The same file the fund page's "Holding details" loads.
    private static func us(_ symbol: String, name: String) async throws -> FundSources.Found? {
        let ticker = symbol.uppercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "https://investor.vanguard.com/irr/funds/profile/\(ticker)-AdditionalFundData"),
              let root = try await FundSources.json(url) as? [String: Any],
              let details = root["holdingDetails"] as? [String: Any] else { return nil }
        let equities = details["equityHoldings"] as? [[String: Any]] ?? []
        if equities.isEmpty {
            // A bond fund has fixedIncomeHoldings instead.
            let other = details.values.contains { ($0 as? [Any])?.isEmpty == false }
            if other { throw FundError.notEquity(name) }
            return nil
        }
        let rows = equities.compactMap { item -> FundSources.Row? in
            guard let weight = FundSources.percent(item["marketValuePercentage"]),
                  let name = item["securityLongDescription"] as? String ?? item["securityShortDescription"] as? String,
                  (item["securityType"] as? String).map(isEquity) ?? true else { return nil }
            return FundSources.isinRow(name: name, ticker: item["ticker"] as? String ?? "",
                                       isin: item["isin"] as? String, weight: weight, sector: nil)
        }
        return FundSources.Found(rows: rows, source: "Vanguard",
                                 asOf: FundSources.date(details["asOfDate"] as? String, format: "MM/dd/yyyy"))
    }

    /// "EQ.STOCK", "EQ.REIT", "EQ.PREF", "EQ.DRCPT" — not rights and warrants.
    private static func isEquity(_ type: String) -> Bool {
        type.hasPrefix("EQ.") && !["EQ.RIGHT", "EQ.WRT"].contains(type)
    }

    // MARK: Europe

    struct Product: Codable, Sendable {
        let portID: String
        let name: String
        let isin: String
        /// All listings' tickers: VWRL, VWRD, VGWL …
        let tickers: [String]
        /// "Equity", "Bond", "Multi-Asset", "Money Market".
        let assetClass: String
    }

    private static let graphQL = URL(string: "https://www.vanguard.co.uk/gpx/graphql")!
    private static let headers = ["x-consumer-id": "uk0"]

    private static let catalog = ProductList<Product>(file: "Vanguard.json") { await downloadCatalog() }

    private static func ucits(symbol: String, name: String) async throws -> FundSources.Found? {
        guard let products = await catalog.products(), let product = match(symbol: symbol, name: name, in: products)
        else { return nil }
        guard product.assetClass == "Equity" else { throw FundError.notEquity(product.name) }
        let query = """
        query H($portIds: [String!], $lastItemKey: String) { borHoldings(portIds: $portIds) {
          holdings(limit: 1500, lastItemKey: $lastItemKey) { lastItemKey items {
            issuerName securityLongDescription gicsSectorDescription marketValuePercentage
            ticker isin securityType effectiveDate bloombergIsoCountry } } } }
        """
        var items: [[String: Any]] = []
        var key: String?
        // 1500 per page; FTSE All-World has ~4200 lines.
        for _ in 0..<8 {
            var variables: [String: Any] = ["portIds": [product.portID]]
            if let key { variables["lastItemKey"] = key }
            guard let root = try await FundSources.json(graphQL, post: ["query": query, "variables": variables], headers: headers) as? [String: Any],
                  let data = root["data"] as? [String: Any],
                  let holdings = ((data["borHoldings"] as? [[String: Any]])?.first)?["holdings"] as? [String: Any]
            else { break }
            items += holdings["items"] as? [[String: Any]] ?? []
            key = holdings["lastItemKey"] as? String
            if key == nil || key?.isEmpty == true { break }
        }
        let rows = items.compactMap { item -> FundSources.Row? in
            guard let type = item["securityType"] as? String, isEquity(type),
                  let weight = FundSources.percent(item["marketValuePercentage"]),
                  let name = item["issuerName"] as? String ?? item["securityLongDescription"] as? String else { return nil }
            return FundSources.isinRow(name: name, ticker: item["ticker"] as? String ?? "", isin: item["isin"] as? String,
                                       weight: weight, sector: item["gicsSectorDescription"] as? String,
                                       risk: item["bloombergIsoCountry"] as? String)
        }
        if rows.isEmpty, !items.isEmpty { throw FundError.notEquity(product.name) }
        let asOf = items.lazy.compactMap { FundSources.date($0["effectiveDate"] as? String, format: "yyyy-MM-dd") }.first
        return FundSources.Found(rows: rows, source: "Vanguard", asOf: asOf)
    }

    /// The ticker without exchange among all listings' tickers, then the name.
    static func match(symbol: String, name: String, in products: [Product]) -> Product? {
        let ticker = String(symbol.split(separator: ".").first ?? "").uppercased()
        if let found = products.first(where: { $0.tickers.contains(ticker) }) { return found }
        let words = fundWords(name, dropping: [])
        return words.isEmpty ? nil : products.first { fundWords($0.name, dropping: []) == words }
    }

    /// The fund ids from the product list page's model (the list Vanguard's own
    /// product page shows), then name, ISIN, tickers and asset class for them all.
    private static func downloadCatalog() async -> [Product]? {
        guard let page = URL(string: "https://www.vanguard.co.uk/professional/product.model.json"),
              let (data, response) = try? await Net.session.data(from: page),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #""portIds"\s*:\s*"([^"]*)""#, options: .regularExpression) else { return nil }
        let ids = text[range].split(separator: ":", maxSplits: 1).last.map {
            $0.replacingOccurrences(of: "\"", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }?.filter { !$0.isEmpty } ?? []
        guard !ids.isEmpty else { return nil }
        let query = """
        query F($portIds: [String!]!) { funds(portIds: $portIds) { profile { portId fundFullName assetClassificationLevel1
          identifiers(altIds: ["ISIN"]) { altIdValue }
          listings { identifiers(altIds: ["TIDM", "Deutsche Boerse Ticker", "NYSE Euronext Exchange Ticker",
            "Borsa Italiana Ticker", "SIX Swiss Exchange Ticker", "Bolsa Ticker"]) { altIdValue } } } } }
        """
        guard let root = try? await FundSources.json(graphQL, post: ["query": query, "variables": ["portIds": ids]], headers: headers) as? [String: Any],
              let funds = (root["data"] as? [String: Any])?["funds"] as? [[String: Any]] else { return nil }
        return funds.compactMap { fund in
            guard let profile = fund["profile"] as? [String: Any], let id = profile["portId"] as? String,
                  let name = profile["fundFullName"] as? String else { return nil }
            func values(_ list: Any?) -> [String] {
                (list as? [[String: Any]] ?? []).compactMap { ($0["altIdValue"] as? String)?.uppercased() }
            }
            let tickers = (profile["listings"] as? [[String: Any]] ?? []).flatMap { values($0["identifiers"]) }
            return Product(portID: id, name: name, isin: values(profile["identifiers"]).first ?? "",
                           tickers: Array(Set(tickers)).sorted(),
                           assetClass: profile["assetClassificationLevel1"] as? String ?? "")
        }
    }
}

// MARK: - Xtrackers

/// Xtrackers (DWS): the holdings JSON behind the fund pages on etf.dws.com.
/// The funds are found in the site's sitemaps, which list every fund page as
/// "/en-gb/IE00BJ0KDQ92-msci-world-ucits-etf-1c/" — ISIN and name. (The
/// spreadsheet download under /etfdata/ is disallowed for robots, and the fund
/// finder needs the entry page's terms accepted, so neither is used.) DWS
/// writes no tickers, so the stocks are looked up by ISIN.
enum Xtrackers {
    static func isXtrackers(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("XTRACKERS") || upper.hasPrefix("XTR") || upper.contains("X-TRACKERS")
    }

    struct Product: Codable, Sendable {
        let isin: String
        /// The name from the page's address: "MSCI WORLD UCITS ETF 1C".
        let name: String
    }

    private static let host = "https://etf.deutsche-am.com"
    private static let catalog = ProductList<Product>(file: "Xtrackers.json") { await downloadCatalog() }
    private static let noise: Set<String> = ["XTRACKERS", "XTR", "IE", "DB", "X", "TRACKERS"]

    static func holdings(symbol: String, name: String) async throws -> FundSources.Found? {
        guard let products = await catalog.products(), let product = match(name: name, in: products),
              let url = URL(string: "\(host)/api/pdp/en-gb/etf/\(product.isin)/holdings"),
              let root = try await FundSources.json(url) as? [String: Any] else { return nil }
        // The table with an ISIN and a weight column: "Securities held".
        let tables = root["tables"] as? [[String: Any]] ?? []
        var rows: [FundSources.Row] = []
        var lines = 0
        for table in tables {
            let columns = table["columns"] as? [[String: Any]] ?? []
            func key(_ title: String) -> String? {
                columns.first { ($0["value"] as? String)?.localizedCaseInsensitiveContains(title) == true }?["key"] as? String
            }
            guard let isinKey = key("ISIN"), let nameKey = key("Name"), let weightKey = key("Weight") else { continue }
            let assetKey = key("Asset class"), sectorKey = key("Industry")
            for value in table["values"] as? [[String: Any]] ?? [] {
                lines += 1
                func cell(_ key: String?) -> [String: Any]? { key.flatMap { value[$0] as? [String: Any] } }
                let asset = cell(assetKey)?["value"] as? String
                guard asset == nil || asset == "Equities",
                      let weight = FundSources.percent(cell(weightKey)?["sortValue"] ?? cell(weightKey)?["value"]),
                      let name = cell(nameKey)?["value"] as? String else { continue }
                rows.append(FundSources.isinRow(name: name, ticker: "", isin: cell(isinKey)?["value"] as? String,
                                                weight: weight, sector: cell(sectorKey)?["value"] as? String))
            }
            break
        }
        if rows.isEmpty, lines > 0 { throw FundError.notEquity(name) }
        return FundSources.Found(rows: rows, source: "Xtrackers")
    }

    /// The Yahoo name ("Xtrackers MSCI World UCITS ETF 1C") against the pages' names,
    /// first exactly, then without the share class ("1C", "2D").
    static func match(name: String, in products: [Product]) -> Product? {
        let words = fundWords(name, dropping: noise)
        guard !words.isEmpty else { return nil }
        if let found = products.first(where: { fundWords($0.name, dropping: noise) == words }) { return found }
        func base(_ words: [String]) -> [String] {
            words.filter { $0.range(of: #"^\d[CD]$"#, options: .regularExpression) == nil }
        }
        return products.first { base(fundWords($0.name, dropping: noise)) == base(words) }
    }

    private static func downloadCatalog() async -> [Product]? {
        var byISIN: [String: Product] = [:]
        for culture in ["en-gb", "de-de"] {
            guard let url = URL(string: "\(host)/\(culture)/sitemap.xml"),
                  let (data, response) = try? await Net.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let regex = try? NSRegularExpression(pattern: "/\(culture)/([A-Z]{2}[A-Z0-9]{9}[0-9])-([a-z0-9-]+)/<")
            for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let isinRange = Range(match.range(at: 1), in: text),
                      let slugRange = Range(match.range(at: 2), in: text) else { continue }
                let isin = String(text[isinRange])
                if byISIN[isin] == nil {
                    byISIN[isin] = Product(isin: isin, name: text[slugRange].replacingOccurrences(of: "-", with: " ").uppercased())
                }
            }
        }
        return byISIN.isEmpty ? nil : byISIN.values.sorted { $0.isin < $1.isin }
    }
}

// MARK: - Amundi

/// Amundi (and the former Lyxor funds): the product API behind amundietf.com's
/// fund pages, which also lists all funds with ticker, ISIN, replication and
/// asset class. The holdings carry Bloomberg tickers ("ASML NA"), so the exchange
/// is known exactly. Swap-based funds hold a substitute basket instead of the
/// index; for those a fund on the same index is used (`FundProxy`).
enum Amundi {
    static func isAmundi(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("AMUNDI") || upper.contains("LYXOR")
    }

    struct Product: Codable, Sendable {
        let isin: String
        let ticker: String
        let name: String
        let swap: Bool
        /// "Equity", "Fixed Income", "Multi Asset" …
        let assetClass: String
    }

    private static let api = URL(string: "https://www.amundietf.co.uk/mapi/ProductAPI/getProductsData")!
    private static let context: [String: Any] = ["countryCode": "GBR", "languageCode": "en", "userProfileName": "INSTIT"]
    private static let catalog = ProductList<Product>(file: "Amundi.json") { await downloadCatalog() }

    static func holdings(symbol: String, name: String) async throws -> FundSources.Found? {
        guard let products = await catalog.products(), let product = match(symbol: symbol, name: name, in: products)
        else { return nil }
        guard product.assetClass == "Equity" else { throw FundError.notEquity(product.name) }
        if product.swap { throw FundError.swap(product.name) }
        let body: [String: Any] = [
            "context": context, "productIds": [product.isin], "productType": "PRODUCT",
            "composition": ["compositionFields": ["date", "type", "bbg", "isin", "name", "weight", "currency", "sector"]]
        ]
        guard let root = try await FundSources.json(api, post: body) as? [String: Any],
              let composition = ((root["products"] as? [[String: Any]])?.first)?["composition"] as? [String: Any]
        else { return nil }
        let lines = (composition["compositionData"] as? [[String: Any]] ?? []).compactMap { $0["compositionCharacteristics"] as? [String: Any] }
        let rows = lines.compactMap { line -> FundSources.Row? in
            guard let type = line["type"] as? String, ["EQUITY_ORDINARY", "PREFERENCE_SHARES", "DEPOSITORY_RECEIPT"].contains(type),
                  let weight = FundSources.percent(line["weight"]), let name = line["name"] as? String else { return nil }
            // "AAPL UW", "BRK/B UN", "7203 JT".
            let bloomberg = (line["bbg"] as? String ?? "").split(separator: " ").map(String.init)
            let listing = bloomberg.count == 2 ? FundSources.suffix(bloomberg: bloomberg[1]) : nil
            return FundSources.Row(name: name, ticker: bloomberg.first ?? "", currency: line["currency"] as? String ?? "",
                                   weight: weight * 100, sector: line["sector"] as? String,
                                   isin: line["isin"] as? String, listing: listing)
        }
        if rows.isEmpty, !lines.isEmpty { throw FundError.notEquity(product.name) }
        let asOf = lines.lazy.compactMap { FundSources.date($0["date"] as? String, format: "yyyy-MM-dd") }.first
        return FundSources.Found(rows: rows, source: "Amundi", asOf: asOf)
    }

    /// The ticker without exchange, then the name without "Amundi Index Solutions -".
    static func match(symbol: String, name: String, in products: [Product]) -> Product? {
        let ticker = String(symbol.split(separator: ".").first ?? "").uppercased()
        if let found = products.first(where: { $0.ticker == ticker }) { return found }
        func words(_ name: String) -> [String] {
            var words = fundWords(name, dropping: [])
            if let last = words.lastIndex(where: { $0 == "AMUNDI" || $0 == "LYXOR" }) { words.removeFirst(last + 1) }
            return words
        }
        let wanted = words(name)
        return wanted.isEmpty ? nil : products.first { words($0.name) == wanted }
    }

    /// All funds from the UK and the French site (some are only sold in France).
    private static func downloadCatalog() async -> [Product]? {
        var byISIN: [String: Product] = [:]
        for (country, language) in [("GBR", "en"), ("FRA", "fr")] {
            let body: [String: Any] = [
                "context": ["countryCode": country, "languageCode": language, "userProfileName": "INSTIT"],
                "productType": "PRODUCT",
                "characteristics": ["SHARE_MARKETING_NAME", "FUND_REPLICATION_METHODOLOGY", "ISIN", "ASSET_CLASS", "MNEMO"]
            ]
            guard let root = try? await FundSources.json(api, post: body) as? [String: Any] else { continue }
            for item in root["products"] as? [[String: Any]] ?? [] {
                guard let fields = item["characteristics"] as? [String: Any], let isin = fields["ISIN"] as? String,
                      byISIN[isin] == nil, let name = fields["SHARE_MARKETING_NAME"] as? String else { continue }
                byISIN[isin] = Product(
                    isin: isin, ticker: (fields["MNEMO"] as? String ?? "").uppercased(), name: name,
                    swap: (fields["FUND_REPLICATION_METHODOLOGY"] as? String ?? "").localizedCaseInsensitiveContains("swap"),
                    assetClass: fields["ASSET_CLASS"] as? String ?? ""
                )
            }
        }
        return byISIN.isEmpty ? nil : byISIN.values.sorted { $0.isin < $1.isin }
    }
}
