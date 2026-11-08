import SwiftUI
import StockmoteShared

/// The dialogs centred over the window.
enum PanelDialog: Equatable {
    /// The one search (⌘K): indices, stocks and funds. Adding funds and
    /// stocks to lists happens here.
    case search
    /// A new list, optionally with something in it already (from the map's
    /// context menu or the stock page).
    case newWatchlist(items: [ListItem])
    case renameWatchlist(UUID)
}

/// What the map shows: an index or fund (`indexID`) or a list
/// (`watchlistID`).
enum PanelTab: String, CaseIterable, Identifiable {
    case map, watchlists
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
    /// The list a fund's or index's map was opened from: the breadcrumb and
    /// Esc lead back up through it. Nil when it was opened from the overview
    /// or the search.
    @Published var parentListID: UUID?
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

    /// An index's or fund's map, from the top. `list`: the list it was
    /// opened from, which the way back then goes through.
    func openIndex(_ id: String, from list: UUID? = nil) {
        parentListID = list
        indexID = id
        tab = .map
        focus = .all
        screen = .map
    }

    func openWatchlist(_ id: UUID) {
        parentListID = nil
        watchlistID = id
        tab = .watchlists
        focus = .all
        screen = .map
    }

    /// The list the map on screen belongs to, if it was opened from one.
    var parentList: Watchlist? {
        guard tab == .map else { return nil }
        return ListsStore.shared.watchlist(parentListID)
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

    /// A click on a tile or a row: a stock opens its page; a list's fund or
    /// index opens its own map, with the list as the way back.
    func open(_ item: HeatItem) {
        if let ref = item.ref { openRef(ref) } else { openStock(item.symbol) }
    }

    /// "fund:VWCE.DE" or "index:sp500", from the list on screen. A fund that
    /// holds no stocks has no map: a short message says so instead.
    func openRef(_ ref: String) {
        let list = tab == .watchlists && screen == .map ? watchlistID : parentListID
        if let symbol = FundStore.symbol(fromID: ref) {
            let funds = FundStore.shared
            guard let fund = funds.fund(symbol) else { return }
            if let mapless = fund.mapless {
                show(mapless.message(fund.displaySymbol), long: true)
                return
            }
            openIndex(fund.id, from: list)
        } else if ref.hasPrefix("index:") {
            openIndex(String(ref.dropFirst(6)), from: list)
        }
    }

    /// The back chevron and Esc: stock → its map, industry → sector →
    /// the whole map → the list it was opened from → overview.
    func goBack() {
        switch screen {
        case .stock:
            focus = stockReturn.focus
            screen = stockReturn.screen
        case .map:
            if let parent = focus.parent {
                focus = parent
            } else if let list = parentList {
                openWatchlist(list.id)
            } else {
                showOverview()
            }
        case .overview:
            break
        }
    }

    /// Funds taken out of their last list: their map can't be shown any more.
    func fundsChanged(removed: Set<String>) {
        guard let symbol = FundStore.symbol(fromID: indexID), removed.contains(symbol) else { return }
        if screen != .overview, tab == .map {
            if let list = parentList { openWatchlist(list.id) } else { showOverview() }
        }
        indexID = "sp500"
    }

    func resetZoom() {
        zoom = 1
        offset = .zero
    }

    /// `long`: a message to read (why a fund can't be opened) stays longer.
    func show(_ text: String, long: Bool = false, undo: (() -> Void)? = nil) {
        let toast = Toast(text: text, undo: undo)
        self.toast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(undo != nil || long ? 6 : 3))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    // MARK: Removing

    /// Takes an item out of a list, with Undo.
    func remove(_ item: ListItem, from id: UUID) {
        let lists = ListsStore.shared
        guard let list = lists.watchlist(id),
              let position = list.items.firstIndex(where: { $0.same(item) }) else { return }
        let removed = list.items[position]
        lists.remove(item, from: id)
        let name = Self.label(removed)
        show(tr("\(name) er fjernet fra \(list.name)", "\(name) was removed from \(list.name)")) {
            guard var items = lists.watchlist(id)?.items, !items.contains(where: { $0.same(removed) }) else { return }
            items.insert(removed, at: min(position, items.count))
            lists.setItems(items, in: id)
        }
    }

    /// How an item is named in messages and chips: "NVDA", "VWCE", "S&P 500".
    static func label(_ item: ListItem) -> String {
        switch item.kind {
        case .stock: return Symbols.display(item.symbol)
        case .fund: return item.fund?.displaySymbol ?? Symbols.display(item.symbol)
        case .index: return UniverseStore.shared.index(withID: item.symbol)?.name ?? item.symbol
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
            if focus.parent != nil || toOverview || parentList != nil {
                goBack()
                return true
            }
            return false
        case .overview:
            return false
        }
    }
}
