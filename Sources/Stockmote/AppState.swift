import SwiftUI
import StockmoteShared

/// Hvad sidebjælken har valgt: et indeks (`indexID`), favoritter, en
/// watchliste (`watchlistID`) eller indstillinger.
enum PanelTab: String, CaseIterable, Identifiable {
    case map, favorites, watchlists, settings
    var id: String { rawValue }
}

/// Hvor man er i panelet: fane, indeks, sektor/branche og zoom.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var tab: PanelTab = .map {
        didSet { if tab != oldValue { resetZoom() } }
    }
    @Published var indexID: String {
        didSet {
            AppDefaults.store.set(indexID, forKey: "indexID")
            guard indexID != oldValue else { return }
            focus = .all
            // Et nyt indeks har medlemmer vi ikke har hentet kurser for endnu.
            let market = MarketStore.shared
            Task { await market.loadPeriod(market.period, force: false) }
        }
    }
    @Published var focus: Focus = .all {
        didSet { if focus != oldValue { resetZoom() } }
    }
    /// Liste i stedet for kort.
    @Published var showList: Bool {
        didSet { AppDefaults.store.set(showList, forKey: "showList") }
    }
    @Published var watchlistID: UUID?
    /// Watchlisten hvis navn redigeres i sidebjælken lige nu.
    @Published var renamingWatchlist: UUID?
    /// Søgefeltet under "Fonde" er åbent, og hvad der står i det.
    @Published var fundSearchOpen = false
    @Published var fundQuery = ""

    @Published var zoom: CGFloat = 1
    @Published var offset: CGPoint = .zero

    private init() {
        indexID = AppDefaults.store.string(forKey: "indexID") ?? "sp500"
        showList = AppDefaults.store.bool(forKey: "showList")
    }

    /// Fanen før Indstillinger, så et klik mere fører tilbage.
    private var tabBeforeSettings: PanelTab = .map

    /// Indstillinger slår til og fra: åbner dem, eller går tilbage.
    func toggleSettings() {
        if tab == .settings {
            tab = tabBeforeSettings
        } else {
            tabBeforeSettings = tab
            tab = .settings
        }
    }

    /// Klik på et indeks i sidebjælken. Er det allerede valgt, går klikket
    /// tilbage til hele kortet og ud af zoom — ellers skiftes indeks.
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

    /// Esc: først zoom ud, så et niveau op, og først derefter lukkes panelet.
    func handleEscape() -> Bool {
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
