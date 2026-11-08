import Foundation
import StockmoteShared

/// What a list item is.
enum ListItemKind: String, Codable, Hashable {
    case stock, fund, index
}

/// One security in a list: a stock, a fund or an index. No quantities or
/// weights — just the security itself.
struct ListItem: Codable, Hashable, Identifiable {
    var kind: ListItemKind
    /// A stock's or fund's Yahoo symbol ("NVDA", "VWCE.DE", or a NAV fund's
    /// "NAV:…"), or an index's id ("sp500").
    var symbol: String
    /// A fund's name, type, exchange and Nordnet id: what is needed to price
    /// it and load its holdings.
    var fund: Fund? = nil

    var id: String { key }

    /// "stock:NVDA", "fund:VWCE.DE", "index:sp500". A fund's key is also its
    /// map's id (`FundStore.id`).
    var key: String { "\(kind.rawValue):\(symbol)" }

    static func stock(_ symbol: String) -> ListItem { ListItem(kind: .stock, symbol: symbol) }
    static func fund(_ fund: Fund) -> ListItem { ListItem(kind: .fund, symbol: fund.symbol, fund: fund) }
    static func index(_ id: String) -> ListItem { ListItem(kind: .index, symbol: id) }

    /// Two items are the same security whatever the fund's stored details.
    func same(_ other: ListItem) -> Bool { kind == other.kind && symbol == other.symbol }
}

/// A named list of securities — a watchlist, or a portfolio modelled as one.
struct Watchlist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var items: [ListItem]

    init(id: UUID, name: String, items: [ListItem]) {
        self.id = id
        self.name = name
        self.items = items
    }

    /// The stocks in the list.
    var symbols: [String] { items.filter { $0.kind == .stock }.map(\.symbol) }

    func contains(_ item: ListItem) -> Bool { items.contains { $0.same(item) } }

    private enum CodingKeys: String, CodingKey { case id, name, items, symbols }

    /// Lists saved before funds and indices could be in them have only
    /// `symbols`; they become stock items, unchanged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let items = try container.decodeIfPresent([ListItem].self, forKey: .items) {
            self.items = items
        } else {
            items = (try container.decodeIfPresent([String].self, forKey: .symbols) ?? []).map(ListItem.stock)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
    }
}

/// The user's lists. Stored as JSON in UserDefaults.
///
/// A list holds any mix of stocks, funds and indices; the funds in the lists
/// are the funds the app knows (`FundStore` loads their holdings).
@MainActor
final class ListsStore: ObservableObject {
    static let shared = ListsStore()

    @Published private(set) var watchlists: [Watchlist] = [] {
        didSet {
            save()
            if !isLoading { FundStore.shared.sync() }
        }
    }

    enum Keys {
        static let watchlists = "watchlists"
        /// 2: lists hold stocks, funds and indices; favourites and added funds
        /// have been moved into a list.
        static let version = "listsVersion"
        /// Before version 2: favourite stocks and the funds added under Mine.
        static let legacyFavorites = "favorites"
        static let legacyFunds = "funds"
    }

    /// The list old favourites and funds are moved into.
    static let migratedListName = "Favoritter"

    private let defaults = AppDefaults.store
    private var isLoading = false

    private init() {
        isLoading = true
        if let data = defaults.data(forKey: Keys.watchlists),
           let saved = try? JSONDecoder().decode([Watchlist].self, from: data) {
            watchlists = saved
        } else if defaults.object(forKey: Keys.legacyFavorites) == nil {
            // First launch: two lists, so the overview isn't empty.
            watchlists = [
                Watchlist(id: UUID(), name: "AI",
                          items: ["NVDA", "AMD", "AVGO", "TSM", "MU", "PLTR", "ORCL", "MSFT"].map(ListItem.stock)),
                Watchlist(id: UUID(), name: "Udbytte",
                          items: ["KO", "PEP", "PG", "JNJ", "XOM", "CVX", "VZ", "MO"].map(ListItem.stock))
            ]
        }
        migrateLegacy()
        isLoading = false
        save()
    }

    /// Once: favourites and the funds added under Mine (before lists could
    /// hold funds) go into a list named "Favoritter" — an existing list of
    /// that name is reused — and the old storage is removed. Nothing is
    /// added twice, so running it again changes nothing.
    func migrateLegacy() {
        guard defaults.integer(forKey: Keys.version) < 2 else { return }
        let favorites = defaults.stringArray(forKey: Keys.legacyFavorites) ?? []
        let funds = defaults.data(forKey: Keys.legacyFunds)
            .flatMap { try? JSONDecoder().decode([Fund].self, from: $0) } ?? []
        let moved = favorites.map(ListItem.stock) + funds.map(ListItem.fund)
        if !moved.isEmpty {
            var lists = watchlists
            let position: Int
            if let existing = lists.firstIndex(where: { $0.name == Self.migratedListName }) {
                position = existing
            } else {
                // First, where the Favourites card used to be.
                lists.insert(Watchlist(id: UUID(), name: Self.migratedListName, items: []), at: 0)
                position = 0
            }
            for item in moved where !lists[position].contains(item) {
                lists[position].items.append(item)
            }
            watchlists = lists
        }
        defaults.removeObject(forKey: Keys.legacyFavorites)
        defaults.removeObject(forKey: Keys.legacyFunds)
        defaults.set(2, forKey: Keys.version)
    }

    private func save() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(watchlists) {
            defaults.set(data, forKey: Keys.watchlists)
        }
    }

    /// Every stock in every list.
    var allSymbols: Set<String> { Set(watchlists.flatMap(\.symbols)) }

    /// Every fund in every list, once each.
    var allFunds: [Fund] {
        var seen = Set<String>()
        return watchlists.flatMap(\.items).compactMap { item in
            guard item.kind == .fund, let fund = item.fund, seen.insert(fund.symbol).inserted else { return nil }
            return fund
        }
    }

    // MARK: Lists

    func watchlist(_ id: UUID?) -> Watchlist? {
        guard let id else { return nil }
        return watchlists.first { $0.id == id }
    }

    @discardableResult
    func createWatchlist(named name: String? = nil, with items: [ListItem] = []) -> UUID {
        let base = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Watchliste"
        var candidate = base
        var n = 2
        while watchlists.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let list = Watchlist(id: UUID(), name: candidate, items: items)
        watchlists.append(list)
        if !items.isEmpty { fetchIfNeeded() }
        return list.id
    }

    func rename(_ id: UUID, to name: String) {
        guard let trimmed = name.trimmingCharacters(in: .whitespaces).nilIfEmpty,
              let index = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists[index].name = trimmed
    }

    func delete(_ id: UUID) {
        watchlists.removeAll { $0.id == id }
    }

    /// Undo of `delete`: the list back where it was.
    func restore(_ list: Watchlist, at position: Int) {
        guard !watchlists.contains(where: { $0.id == list.id }) else { return }
        watchlists.insert(list, at: min(max(position, 0), watchlists.count))
        fetchIfNeeded()
    }

    /// Replaces a list's items (snapshot mode builds its demo list with it).
    func setItems(_ items: [ListItem], in id: UUID) {
        guard let index = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists[index].items = items
        fetchIfNeeded()
    }

    // MARK: Items

    func contains(_ item: ListItem, in id: UUID) -> Bool {
        watchlist(id)?.contains(item) ?? false
    }

    func contains(_ symbol: String, in id: UUID) -> Bool {
        contains(.stock(symbol), in: id)
    }

    func add(_ item: ListItem, to id: UUID) {
        guard let index = watchlists.firstIndex(where: { $0.id == id }), !watchlists[index].contains(item) else { return }
        watchlists[index].items.append(item)
        fetchIfNeeded()
    }

    func remove(_ item: ListItem, from id: UUID) {
        guard let index = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists[index].items.removeAll { $0.same(item) }
    }

    func toggle(_ item: ListItem, in id: UUID) {
        if contains(item, in: id) { remove(item, from: id) } else { add(item, to: id) }
    }

    func toggle(_ symbol: String, in id: UUID) { toggle(.stock(symbol), in: id) }

    /// The lists that hold the item.
    func lists(containing item: ListItem) -> [Watchlist] {
        watchlists.filter { $0.contains(item) }
    }

    /// Notes on every copy of the fund that it can't be drawn as a stock map
    /// (a bond fund, a swap-based ETF), so its holdings aren't looked for again.
    func markMapless(_ symbol: String, _ reason: FundMapless) {
        var lists = watchlists
        var changed = false
        for l in lists.indices {
            for i in lists[l].items.indices where lists[l].items[i].kind == .fund && lists[l].items[i].symbol == symbol {
                if lists[l].items[i].fund?.mapless != reason {
                    lists[l].items[i].fund?.mapless = reason
                    changed = true
                }
            }
        }
        if changed { watchlists = lists }
    }

    /// A new item has no Yahoo data for the chosen range yet.
    private func fetchIfNeeded() {
        // Also its figures under the other ranges, when a list is on screen.
        MarketStore.shared.viewChanged()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
