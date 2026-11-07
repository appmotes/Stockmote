import Combine
import Foundation
import StockmoteShared
import WidgetKit

/// Skriver `Widget.json` til widget'en (se WidgetShare for hvorfor det er en
/// fil). Kurserne henter widget'en selv, så filen skrives kun når lister,
/// farver eller markedsværdier ændrer sig — og WidgetKit bedes kun genindlæse
/// når noget man kan se har ændret sig.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()

    private var cancellables: Set<AnyCancellable> = []
    private var lastVisibleKey: Int?

    private init() {}

    func start() {
        let lists = ListsStore.shared
        Publishers.Merge6(
            lists.$favorites.map { _ in () },
            lists.$watchlists.map { _ in () },
            Preferences.shared.$colorStyle.map { _ in () },
            Preferences.shared.$language.map { _ in () },
            Preferences.shared.$theme.map { _ in () },
            MarketStore.shared.$quotes.map { _ in () }
        )
        .debounce(for: .seconds(2), scheduler: RunLoop.main)
        .sink { [weak self] in self?.write() }
        .store(in: &cancellables)
    }

    private func write() {
        let market = MarketStore.shared
        let universe = UniverseStore.shared
        let lists = ListsStore.shared

        var symbols = Set(universe.allIndexSymbols)
        symbols.formUnion(lists.allSymbols)
        var stocks: [String: WidgetShare.Stock] = [:]
        for symbol in symbols {
            let info = market.info(symbol)
            stocks[symbol] = WidgetShare.Stock(name: info.name, sector: info.sector,
                                               industry: info.industry, cap: market.marketCap(symbol))
        }

        let share = WidgetShare(
            updated: Date(),
            favorites: lists.favorites,
            watchlists: lists.watchlists.map { WidgetShare.List(name: $0.name, symbols: $0.symbols) },
            indices: Dictionary(universe.indices.map { ($0.id, $0.symbols) }, uniquingKeysWith: { a, _ in a }),
            stocks: stocks,
            colorStyle: Preferences.shared.colorStyle.rawValue,
            indexList: universe.indices.map {
                WidgetShare.Index(id: $0.id, name: $0.name, flag: $0.flag, benchmark: $0.benchmark, hours: $0.hours)
            },
            english: Lang.isEnglish,
            theme: Preferences.shared.theme.rawValue
        )
        do {
            try share.write()
        } catch {
            NSLog("Stockmote: kunne ikke skrive Widget.json: \(error)")
            return
        }

        var hasher = Hasher()
        hasher.combine(share.favorites)
        hasher.combine(share.watchlists.map(\.name))
        hasher.combine(share.watchlists.map(\.symbols))
        hasher.combine(share.colorStyle)
        hasher.combine(share.english)
        hasher.combine(share.theme)
        let key = hasher.finalize()
        if key != lastVisibleKey {
            lastVisibleKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
