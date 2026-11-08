import SwiftUI
import StockmoteShared

/// The "new" and "rename" actions of the sidebar, each shown as a dialog
/// centred over the window instead of a field squeezed into the sidebar.
enum PanelDialog: Equatable {
    case addFund
    /// A new watchlist, optionally with stocks in it already (from the map's
    /// context menu).
    case newWatchlist(symbols: [String])
    case renameWatchlist(UUID)
}

/// What the sidebar has selected: an index (`indexID`), favorites or a
/// watchlist (`watchlistID`). Settings have their own window.
enum PanelTab: String, CaseIterable, Identifiable {
    case map, favorites, watchlists
    var id: String { rawValue }
}

/// Where you are in the window: tab, index, sector/industry and zoom.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

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

    @Published var zoom: CGFloat = 1
    @Published var offset: CGPoint = .zero

    private init() {
        indexID = AppDefaults.store.string(forKey: "indexID") ?? "sp500"
        showList = AppDefaults.store.bool(forKey: "showList")
    }

    /// Click on an index in the sidebar. If it is already selected, the click goes
    /// back to the whole map and out of zoom — otherwise the index changes.
    func selectIndex(_ id: String) {
        if tab == .map, indexID == id {
            focus = .all
            resetZoom()
        } else {
            indexID = id
            tab = .map
        }
    }

    func resetZoom() {
        zoom = 1
        offset = .zero
    }

    /// Esc: first close a dialog, then zoom out, then stop a replay, then go
    /// up a level. False when there was nothing left to undo.
    func handleEscape() -> Bool {
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
        if tab == .map, let parent = focus.parent {
            focus = parent
            return true
        }
        return false
    }
}
