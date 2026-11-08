import SwiftUI
import StockmoteShared

/// The dialogs centred over the window.
enum PanelDialog: Equatable {
    /// The one search (⌘K): indices, stocks and funds. Adding funds and
    /// stocks to lists happens here.
    case search
    /// A new watchlist, optionally with stocks in it already (from the map's
    /// context menu or the stock page).
    case newWatchlist(symbols: [String])
    case renameWatchlist(UUID)
}

/// What the map shows: an index or fund (`indexID`), favorites or a
/// watchlist (`watchlistID`).
enum PanelTab: String, CaseIterable, Identifiable {
    case map, favorites, watchlists
    var id: String { rawValue }
}

/// The three levels of the window: the overview of every market and list,
/// one map, and one stock.
enum Screen: Equatable {
    case overview
    case map
    case stock(String)
}

/// A short message at the bottom of the window, optionally with Undo.
struct Toast: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)? = nil
}

/// Where you are in the window: screen, source, sector/industry and zoom.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var screen: Screen = .overview {
        didSet {
            guard screen != oldValue else { return }
            resetZoom()
            if case .stock = screen { ReplayStore.shared.stop() }
            if screen == .overview { ReplayStore.shared.stop() }
            MarketStore.shared.viewChanged()
        }
    }
    @Published var tab: PanelTab = .map {
        didSet {
            guard tab != oldValue else { return }
            resetZoom()
            MarketStore.shared.viewChanged()
        }
    }
    @Published var indexID: String {
        didSet {
            AppDefaults.store.set(indexID, forKey: "indexID")
            guard indexID != oldValue else { return }
            focus = .all
            // A new index has members we have not fetched prices for yet.
            MarketStore.shared.viewChanged()
        }
    }
    @Published var focus: Focus = .all {
        didSet { if focus != oldValue { resetZoom() } }
    }
    /// List instead of map.
    @Published var showList: Bool {
        didSet { AppDefaults.store.set(showList, forKey: "showList") }
    }
    @Published var watchlistID: UUID? {
        didSet { if watchlistID != oldValue, tab == .watchlists { MarketStore.shared.viewChanged() } }
    }
    /// The dialog centred over the window, if one is open.
    @Published var dialog: PanelDialog?
    @Published var toast: Toast?

    @Published var zoom: CGFloat = 1
    @Published var offset: CGPoint = .zero

    /// The map level a stock page was opened from, to go back to.
    private(set) var stockReturn: (screen: Screen, focus: Focus) = (.overview, .all)

    private init() {
        indexID = AppDefaults.store.string(forKey: "indexID") ?? "sp500"
        showList = AppDefaults.store.bool(forKey: "showList")
    }

    // MARK: Navigation

    var isMap: Bool { screen == .map }

    var stockSymbol: String? {
        if case .stock(let symbol) = screen { return symbol }
        return nil
    }

    func showOverview() {
        focus = .all
        screen = .overview
    }

    /// An index's or fund's map, from the top.
    func openIndex(_ id: String) {
        indexID = id
        tab = .map
        focus = .all
        screen = .map
    }

    func openFavorites() {
        tab = .favorites
        focus = .all
        screen = .map
    }

    func openWatchlist(_ id: UUID) {
        watchlistID = id
        tab = .watchlists
        focus = .all
        screen = .map
    }

    /// ⌘1 … ⌘9. On the index already shown, it goes back to the top of its map.
    func selectIndex(_ id: String) {
        if screen == .map, tab == .map, indexID == id {
            focus = .all
            resetZoom()
        } else {
            openIndex(id)
        }
    }

    /// The stock page. Back returns to where it was opened from.
    func openStock(_ symbol: String) {
        if stockSymbol == nil { stockReturn = (screen, focus) }
        screen = .stock(symbol)
    }

    /// The back chevron and Esc: stock → its map, industry → sector →
    /// the whole map → overview.
    func goBack() {
        switch screen {
        case .stock:
            focus = stockReturn.focus
            screen = stockReturn.screen
        case .map:
            if let parent = focus.parent { focus = parent } else { showOverview() }
        case .overview:
            break
        }
    }

    func resetZoom() {
        zoom = 1
        offset = .zero
    }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        let toast = Toast(text: text, undo: undo)
        self.toast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(undo == nil ? 3 : 6))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    // MARK: Removing from the overview

    /// Removes a fund, with Undo that puts it back with the holdings it had.
    func removeFund(_ symbol: String) {
        let funds = FundStore.shared
        guard let fund = funds.fund(symbol) else { return }
        let holdings = funds.holdings[symbol]
        funds.remove(symbol)
        if screen == .map, tab == .map, indexID == fund.id { showOverview() }
        show(tr("\(fund.displaySymbol) er fjernet", "\(fund.displaySymbol) was removed")) {
            if let holdings { funds.add(fund, holdings: holdings) } else { funds.add(fund) }
        }
    }

    /// Deletes a watchlist, with Undo.
    func removeWatchlist(_ id: UUID) {
        let lists = ListsStore.shared
        guard let position = lists.watchlists.firstIndex(where: { $0.id == id }) else { return }
        let list = lists.watchlists[position]
        lists.delete(id)
        if watchlistID == id {
            watchlistID = lists.watchlists.first?.id
            if screen == .map, tab == .watchlists { showOverview() }
        }
        show(tr("\(list.name) er slettet", "\(list.name) was deleted")) {
            lists.restore(list, at: position)
        }
    }

    /// Esc: first close a dialog, then zoom out, then close the
    /// seismograph, then go up a level. `toOverview`: whether the top of a
    /// map goes on to the overview (not in Map Only). False when there was
    /// nothing left to undo.
    func handleEscape(toOverview: Bool = true) -> Bool {
        if dialog != nil {
            dialog = nil
            return true
        }
        if zoom > 1.01 {
            resetZoom()
            return true
        }
        if ReplayStore.shared.isActive {
            ReplayStore.shared.stop()
            return true
        }
        switch screen {
        case .stock:
            goBack()
            return true
        case .map:
            if focus.parent != nil || toOverview {
                goBack()
                return true
            }
            return false
        case .overview:
            return false
        }
    }
}
