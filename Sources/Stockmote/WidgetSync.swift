import Combine
import Foundation
import StockmoteShared
import WidgetKit

/// Writes `Widget.json` for the widget (see WidgetShare for why it's a
/// file). The widget fetches prices itself, so the file is only written when
/// lists, colours or market caps change — and WidgetKit is only asked to
/// reload when something visible has changed.
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
        .merge(with: FundStore.shared.$holdings.map { _ in () }, FundStore.shared.$funds.map { _ in () })
        .debounce(for: .seconds(2), scheduler: RunLoop.main)
        .sink { [weak self] in self?.write() }
        .store(in: &cancellables)
    }

    private func write() {
        let market = MarketStore.shared
        let universe = UniverseStore.shared
        let lists = ListsStore.shared

        // Funds appear in the widget's index menu alongside the indices.
        let funds = FundStore.shared.indices.filter { !$0.symbols.isEmpty }
        let all = universe.indices + funds

        var symbols = Set(universe.allIndexSymbols)
        symbols.formUnion(lists.allSymbols)
        symbols.formUnion(funds.flatMap(\.symbols))
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
            indices: Dictionary(all.map { ($0.id, $0.symbols) }, uniquingKeysWith: { a, _ in a }),
            stocks: stocks,
            colorStyle: Preferences.shared.colorStyle.rawValue,
            indexList: all.map {
                WidgetShare.Index(id: $0.id, name: $0.name, flag: $0.flag ?? ($0.isFund ? "📊" : nil),
                                  benchmark: $0.benchmark, hours: $0.hours)
            },
            english: Lang.isEnglish,
            theme: Preferences.shared.theme.rawValue,
            weights: Dictionary(funds.compactMap { fund in fund.weights.map { (fund.id, $0) } },
                                uniquingKeysWith: { a, _ in a })
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
        hasher.combine(share.indexList?.map(\.id))
        let key = hasher.finalize()
        if key != lastVisibleKey {
            lastVisibleKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
