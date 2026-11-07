import Foundation
import StockmoteShared

/// En navngiven liste af aktier.
struct Watchlist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var symbols: [String]
}

/// Favoritter og watchlister. Gemmes som JSON i UserDefaults.
@MainActor
final class ListsStore: ObservableObject {
    static let shared = ListsStore()

    @Published private(set) var favorites: [String] = [] {
        didSet { save() }
    }
    @Published private(set) var watchlists: [Watchlist] = [] {
        didSet { save() }
    }

    private enum Keys {
        static let favorites = "favorites"
        static let watchlists = "watchlists"
    }

    private let defaults = AppDefaults.store
    private var isLoading = false

    private init() {
        isLoading = true
        if let saved = defaults.stringArray(forKey: Keys.favorites) {
            favorites = saved
        } else {
            // Første start: et par store navne, så fanen ikke står tom.
            favorites = ["AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "AVGO"]
        }
        if let data = defaults.data(forKey: Keys.watchlists),
           let saved = try? JSONDecoder().decode([Watchlist].self, from: data) {
            watchlists = saved
        } else {
            watchlists = [
                Watchlist(id: UUID(), name: "AI", symbols: ["NVDA", "AMD", "AVGO", "TSM", "MU", "PLTR", "ORCL", "MSFT"]),
                Watchlist(id: UUID(), name: "Udbytte", symbols: ["KO", "PEP", "PG", "JNJ", "XOM", "CVX", "VZ", "MO"])
            ]
        }
        isLoading = false
        save()
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(favorites, forKey: Keys.favorites)
        if let data = try? JSONEncoder().encode(watchlists) {
            defaults.set(data, forKey: Keys.watchlists)
        }
    }

    var allSymbols: Set<String> {
        Set(favorites).union(watchlists.flatMap(\.symbols))
    }

    // MARK: Favoritter

    func isFavorite(_ symbol: String) -> Bool { favorites.contains(symbol) }

    func toggleFavorite(_ symbol: String) {
        if let index = favorites.firstIndex(of: symbol) {
            favorites.remove(at: index)
        } else {
            favorites.append(symbol)
            fetchIfNeeded()
        }
    }

    func removeFavorite(_ symbol: String) {
        favorites.removeAll { $0 == symbol }
    }

    // MARK: Watchlister

    func watchlist(_ id: UUID?) -> Watchlist? {
        guard let id else { return nil }
        return watchlists.first { $0.id == id }
    }

    @discardableResult
    func createWatchlist(named name: String? = nil, with symbols: [String] = []) -> UUID {
        let base = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Watchliste"
        var candidate = base
        var n = 2
        while watchlists.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let list = Watchlist(id: UUID(), name: candidate, symbols: symbols)
        watchlists.append(list)
        if !symbols.isEmpty { fetchIfNeeded() }
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

    func contains(_ symbol: String, in id: UUID) -> Bool {
        watchlist(id)?.symbols.contains(symbol) ?? false
    }

    func toggle(_ symbol: String, in id: UUID) {
        guard let index = watchlists.firstIndex(where: { $0.id == id }) else { return }
        if let position = watchlists[index].symbols.firstIndex(of: symbol) {
            watchlists[index].symbols.remove(at: position)
        } else {
            watchlists[index].symbols.append(symbol)
            fetchIfNeeded()
        }
    }

    func remove(_ symbol: String, from id: UUID) {
        guard let index = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists[index].symbols.removeAll { $0 == symbol }
    }

    /// En ny aktie udenfor indekserne har ingen Yahoo-data for 1U … 1Å endnu.
    private func fetchIfNeeded() {
        let market = MarketStore.shared
        guard market.period != .day else { return }
        Task { await market.loadPeriod(market.period, force: false) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
