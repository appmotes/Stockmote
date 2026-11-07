import Foundation
import StockmoteShared

/// Nordnet's public API behind nordnet.dk — the same calls the site makes
/// for visitors who aren't logged in. Needs no account or key, only the
/// header `client-id: NEXT`.
///
/// - **Search** (`/api/2/main_search`): Nordnet's own funds and the other
///   funds it sells (Nordnet Danmark Indeks, Nordnet Global Indeks …), which
///   aren't listed anywhere and which Yahoo doesn't know, and the Danish
///   investeringsforeninger listed on Nasdaq Copenhagen (Sparindex, Danske
///   Invest, Nykredit Invest, Jyske Invest, BankInvest …).
/// - **Holdings** (`/api/2/instruments/{id}/fund/info`): the fund's largest
///   holdings — at most 25 — with weights, from Morningstar's data, as Nordnet
///   instrument ids that `/api/2/instruments/{ids}` turns into ticker,
///   exchange and ISIN.
///
/// Prices: a listed fund has a Yahoo symbol ("DKIDKIX.CO"). An unlisted one only
/// has a daily NAV, which comes from Morningstar (see `FundNAV`); its symbol is
/// "NAV:<Morningstar id>:<currency>".
enum Nordnet {
    private static let base = "https://www.nordnet.dk/api/2"

    private static func get(_ path: String) async throws -> Any {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("NEXT", forHTTPHeaderField: "client-id")
        let (data, response) = try await Net.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Search

    /// Funds and Danish investeringsforeninger whose name matches.
    static func search(_ text: String) async -> [FundSearchResult] {
        guard let query = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let groups = try? await get("/main_search?query=\(query)&search_space=ALL&limit=10") as? [[String: Any]]
        else { return [] }
        var results: [FundSearchResult] = []
        for group in groups {
            let type = group["display_group_type"] as? String
            guard type == "FUND" || type == "PINV" else { continue }
            for item in group["results"] as? [[String: Any]] ?? [] {
                guard let id = item["instrument_id"] as? Int, let name = item["display_name"] as? String else { continue }
                let currency = item["currency"] as? String ?? "DKK"
                let market = item["market_info"] as? [String: Any]
                if type == "PINV" {
                    // Listed in Copenhagen: Yahoo has the price under the ticker.
                    guard let ticker = item["display_symbol"] as? String, !ticker.isEmpty else { continue }
                    let symbol = ticker.replacingOccurrences(of: " ", with: "-") + ".CO"
                    results.append(FundSearchResult(symbol: symbol, name: name, kind: "MUTUALFUND",
                                                    exchange: "Copenhagen · Nordnet",
                                                    nordnet: id))
                } else {
                    // Not listed: priced by its NAV, by Morningstar id.
                    guard let morningstar = market?["identifier"] as? String, morningstar.hasPrefix("F0") else { continue }
                    results.append(FundSearchResult(symbol: "\(FundNAV.prefix)\(morningstar):\(currency)", name: name,
                                                    kind: "MUTUALFUND", exchange: "NAV · Nordnet",
                                                    nordnet: id))
                }
            }
        }
        return results
    }

    /// Nordnet's id for a fund listed in Copenhagen ("SPIC25KL.CO"), so the
    /// holdings of a Danish fund found in Yahoo's search can come from Nordnet.
    static func instrumentID(forCopenhagen symbol: String) async -> Int? {
        guard symbol.hasSuffix(".CO") else { return nil }
        let ticker = String(symbol.dropLast(3)).replacingOccurrences(of: "-", with: " ")
        return await search(ticker).first { $0.symbol == symbol }?.nordnet
    }

    // MARK: Holdings

    /// MIC → Yahoo suffix for the exchanges Nordnet's holdings trade on.
    private static let mics: [String: String] = [
        "XCSE": "CO", "XSTO": "ST", "XHEL": "HE", "XOSL": "OL", "XNAS": "", "XNYS": "", "ARCX": "", "BATS": "",
        "XETR": "DE", "XPAR": "PA", "XAMS": "AS", "XBRU": "BR", "XMIL": "MI", "XMAD": "MC", "XLON": "L",
        "XSWX": "SW", "XVTX": "SW", "XLIS": "LS", "XDUB": "IR", "XWBO": "VI", "XTSE": "TO", "XTKS": "T", "XHKG": "HK"
    ]

    /// The fund's largest holdings, as Nordnet publishes them. `partial` when
    /// they cover less than 95 % of the fund (Nordnet shows at most 25).
    static func holdings(id: Int, name: String) async throws -> FundSources.Found? {
        guard let info = (try await get("/instruments/\(id)/fund/info") as? [[String: Any]])?.first else { return nil }
        let morningstar = info["morningstar_info"] as? [String: Any]
        let assets = info["asset_allocation"] as? [[String: Any]] ?? []
        let stockShare = assets.first { ($0["type_id"] as? String) == "1" }?["weight"] as? Double
        // Bond and money market funds: no stocks to show.
        if let stockShare, stockShare < 50 { throw FundError.notEquity(name) }
        let weights = (info["instrument_underlying_info"] as? [[String: Any]] ?? []).compactMap { item -> (Int, Double)? in
            guard let id = item["instrument_id"] as? Int, let weight = item["weight"] as? Double else { return nil }
            return (id, weight)
        }
        guard !weights.isEmpty else { return nil }
        let ids = weights.map { String($0.0) }.joined(separator: ",")
        // Ids Nordnet no longer knows (expired index futures) are left out of the answer.
        let instruments = try await get("/instruments/\(ids)") as? [[String: Any]] ?? []
        let byID = Dictionary(instruments.compactMap { item in (item["instrument_id"] as? Int).map { ($0, item) } },
                              uniquingKeysWith: { a, _ in a })
        var rows: [FundSources.Row] = []
        for (id, weight) in weights {
            // Stocks only: futures, funds and cash have another asset class.
            guard let item = byID[id], (item["asset_class"] as? String) == "EQY",
                  let ticker = item["symbol"] as? String, let name = item["name"] as? String else { continue }
            let mic = (item["tradables"] as? [[String: Any]])?.first?["mic"] as? String
            let isin = item["isin_code"] as? String
            rows.append(FundSources.Row(name: name, ticker: ticker, currency: item["currency"] as? String ?? "",
                                        weight: weight, isin: isin, listing: mic.flatMap { mics[$0] },
                                        country: isin.map { String($0.prefix(2)) }))
        }
        let covered = rows.reduce(0) { $0 + $1.weight }
        let target = stockShare ?? 100
        var asOf: Date?
        if let date = morningstar?["release_top_holding_date"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            asOf = formatter.date(from: date)
        }
        var found = FundSources.Found(rows: rows, source: "Nordnet", asOf: asOf)
        found.partial = covered < target * 0.95
        if found.partial { found.source = "Nordnet · top \(rows.count)" }
        return found
    }
}
