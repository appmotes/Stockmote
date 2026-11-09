import AppKit
import Combine
import StockmoteShared
import SwiftUI

@main
enum StockmoteMain {
    /// A plain AppKit app rather than a SwiftUI `App`: the main menu is built
    /// by hand so its titles follow the in-app language (SwiftUI names the
    /// standard menus in the system's language), and with no SwiftUI scenes
    /// there is no stray, empty Settings window that SwiftUI can show by
    /// itself. The windows are MainWindow and SettingsWindow.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Builds the menu bar icon, the main menu and — unless the app was opened at
/// login — the main window, and applies the Dock / menu bar setting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarItem?
    /// A click on the widget can launch the app; then the URL arrives before the menu bar
    /// is built.
    private var pendingURL: URL?
    /// Opened as a login item: then the app starts quietly, without the window.
    private var launchedAtLogin = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event says whether this is a login item
        // ('oapp' with keyAEPropData = keyAELaunchedAsLogInItem, 'lgit').
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == 0x6F61_7070,                                                    // 'oapp'
           event.paramDescriptor(forKeyword: 0x7072_6474)?.enumCodeValue == 0x6C67_6974 {   // 'prdt' = 'lgit'
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            // No Dock icon for the moment a snapshot takes.
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await snapshot.run() }
            return
        }

        // AppKit would otherwise add its own "Enter Full Screen" (in the
        // system's language) and tab items to the menus.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSWindow.allowsAutomaticWindowTabbing = false

        MainActor.assumeIsolated {
            MainMenu.shared.install()
            menuBar = MenuBarItem()
            applyPresence()
            Preferences.shared.$presence
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyPresence() }
                .store(in: &cancellables)

            MarketStore.shared.start()
            // The funds' holdings are fetched again when they are a week old.
            FundStore.shared.refreshStale()
            WidgetSync.shared.start()
            if let pendingURL {
                self.pendingURL = nil
                handle(pendingURL)
            } else if Preferences.shared.openWindowAtLaunch, !launchedAtLogin {
                MainWindow.shared.show()
            }
        }
    }

    /// Dock icon or not, menu bar icon or not — never neither (see AppPresence).
    @MainActor
    private func applyPresence() {
        let presence = Preferences.shared.presence
        menuBar?.setVisible(presence.showsStatusItem)
        let policy: NSApplication.ActivationPolicy = presence.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let front = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        // Changing the policy deactivates the app; bring back the window the
        // setting was changed in.
        if let front {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                front.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The Dock icon clicked: bring the window back if it is closed or minimised.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !MainWindow.shared.isOnScreen { MainWindow.shared.show() }
        }
        return true
    }

    /// Closing the window keeps the app (and the menu bar icon) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// `stockmote://open?tab=favorites&index=ndx` — from the widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "stockmote" }) else { return }
        MainActor.assumeIsolated {
            if menuBar == nil {
                pendingURL = url
            } else {
                handle(url)
            }
        }
    }

    /// Opens the main window on the view the widget showed.
    @MainActor
    private func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = AppState.shared
        if let index = items.first(where: { $0.name == "index" })?.value,
           UniverseStore.shared.index(withID: index) != nil {
            app.indexID = index
        }
        let tab = items.first(where: { $0.name == "tab" })?.value
        if let tab = tab.flatMap(PanelTab.init(rawValue:)) {
            app.parentListID = nil
            app.tab = tab
        }
        // A list widget names its list. An old favourites widget opens the
        // list the favourites were moved into.
        let name = tab == "favorites" ? ListsStore.migratedListName : items.first(where: { $0.name == "list" })?.value
        if let name, let list = ListsStore.shared.watchlists.first(where: { $0.name == name }) {
            app.openWatchlist(list.id)
        }
        app.focus = .all
        app.screen = .map
        if FullscreenController.shared.isShowing { FullscreenController.shared.close() }
        MainWindow.shared.show()
    }
}

/// `Stockmote --snapshot out.png [--screen overview|map] [--tab map|watchlists] [--watchlist "AI"]
/// [--add-list "Min portefølje" --items "NVDA,fund:IWDA.AS,index:c25"] [--open fund:IWDA.AS]
/// [--index sp500|ndx|dji] [--period 1D|1U|1M|3M|6M|ÅTD|1Å|3Å|5Å|Alt] [--sector "…"]
/// [--industry "…"] [--stock NVDA] [--size small|medium|large|huge] [--list] [--zoom 2.5]
/// [--theme light|dark] [--lang da|en] [--fullscreen [--notch 32]]
/// [--seismograph 0.4] [--fund SPY] [--search "MSCI World" [--fund-pick URTH] [--fund-add]]
/// [--dialog new-list|rename-list] [--window 1200x780] [--settings]
/// [--trading-hours] [--overview table|relative] [--benchmark c25] [--figures] [--legacy-favorites "AAPL,NVDA"] [--legacy-funds "SPY"] [--legacy-list "Tech:AAPL"] [--legacy-repeat]`
///
/// Fetches real data, renders the main window's content (or Map Only, or
/// the Settings window) to a PNG and quits. Used for the images in docs/
/// and to see the UI without clicking around.
@MainActor
struct Snapshot {
    let output: URL
    let options: [String: String]
    let flags: Set<String>

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        output = URL(fileURLWithPath: arguments[index + 1])
        var options: [String: String] = [:]
        var flags = Set<String>()
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("--"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                options[String(arg.dropFirst(2))] = arguments[i + 1]
                i += 2
            } else {
                flags.insert(String(arg.dropFirst(2)))
                i += 1
            }
        }
        self.options = options
        self.flags = flags
    }

    /// "1200x780" (or "1200×780").
    private static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 200, parts[1] >= 200 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// `--size`: named sizes of the window's content. Small is the window's
    /// smallest size; medium, the default, keeps the images in docs/ compact.
    private static func namedSize(_ name: String?) -> CGSize {
        switch name {
        case "small"?: return CGSize(width: 720, height: 480)
        case "large"?: return CGSize(width: 1140, height: 720)
        case "huge"?: return CGSize(width: 1400, height: 860)
        default: return CGSize(width: 940, height: 600)
        }
    }

    private func writeLegacy() {
        let defaults = AppDefaults.store
        if let favorites = options["legacy-favorites"] {
            defaults.set(favorites.split(separator: ",").map(String.init), forKey: ListsStore.Keys.legacyFavorites)
        }
        // --legacy-list "Tech:AAPL,MSFT": a watchlist in the old format (only
        // `symbols`), with a list named "Favoritter" to see it reused.
        if let text = options["legacy-list"], let colon = text.firstIndex(of: ":") {
            let old: [[String: Any]] = [
                ["id": UUID().uuidString, "name": String(text[..<colon]),
                 "symbols": text[text.index(after: colon)...].split(separator: ",").map(String.init)],
                ["id": UUID().uuidString, "name": ListsStore.migratedListName, "symbols": ["AAPL"]]
            ]
            defaults.set(try? JSONSerialization.data(withJSONObject: old), forKey: ListsStore.Keys.watchlists)
        }
        if let symbols = options["legacy-funds"] {
            let funds = symbols.split(separator: ",").map { Fund(symbol: String($0), name: String($0), kind: "ETF") }
            defaults.set(try? JSONEncoder().encode(funds), forKey: ListsStore.Keys.legacyFunds)
        }
    }

    private static func printLists(_ heading: String) {
        print("\(heading):")
        for list in ListsStore.shared.watchlists {
            print("  \(list.name): \(list.items.map(\.key).joined(separator: ", "))")
        }
    }

    /// "NVDA,ASML.AS,fund:IWDA.AS,index:c25" → list items. Funds are looked
    /// up in the fund search for their name and type, and their holdings loaded.
    private static func items(_ text: String) async -> [ListItem] {
        var items: [ListItem] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("index:") {
                items.append(.index(String(part.dropFirst(6))))
            } else if part.hasPrefix("fund:") {
                items.append(.fund(await fund(String(part.dropFirst(5)))))
            } else {
                items.append(.stock(part))
            }
        }
        return items
    }

    private static func fund(_ symbol: String) async -> Fund {
        let found = await FundStore.search(symbol).first { $0.symbol.uppercased() == symbol.uppercased() }
        return found?.fund ?? Fund(symbol: symbol.uppercased(), name: symbol.uppercased(), kind: "ETF")
    }

    /// Puts the items in the list of that name (made if missing, emptied
    /// if not) and waits for the funds' holdings.
    @discardableResult
    private static func fill(_ name: String, with items: [ListItem]) async -> UUID {
        let lists = ListsStore.shared
        let id = lists.watchlists.first(where: { $0.name == name })?.id ?? lists.createWatchlist(named: name)
        lists.setItems(items, in: id)
        for item in items where item.kind == .fund {
            await FundStore.shared.ensureLoaded(item.symbol)
            if let error = FundStore.shared.errors[item.symbol] { print("Fond \(item.symbol): \(error)") }
        }
        return id
    }

    func run() async {
        // --legacy-favorites "AAPL,NVDA" --legacy-funds "SPY": favourites and
        // funds stored the way versions before lists held funds stored them,
        // written before the lists are loaded — to see them migrated.
        writeLegacy()

        let app = AppState.shared
        let market = MarketStore.shared
        let prefs = Preferences.shared

        if options["legacy-favorites"] != nil || options["legacy-funds"] != nil {
            Self.printLists("After migration")
            // --legacy-repeat: the old storage again and the migration run
            // again — it must reuse "Favoritter" and add nothing twice.
            if flags.contains("legacy-repeat") {
                writeLegacy()
                AppDefaults.store.set(0, forKey: ListsStore.Keys.version)
                ListsStore.shared.migrateLegacy()
                Self.printLists("After a second migration")
            }
            let left = [ListsStore.Keys.legacyFavorites, ListsStore.Keys.legacyFunds]
                .filter { AppDefaults.store.object(forKey: $0) != nil }
            print("Old keys left: \(left.isEmpty ? "none" : left.joined(separator: ", "))")
        }

        if let theme = options["theme"].flatMap(ThemeMode.init(rawValue:)) { prefs.theme = theme }
        if let lang = options["lang"] { prefs.language = lang == "en" ? .english : .danish }
        // --trading-hours: the overview's trading-hours band shown.
        prefs.showTradingHours = flags.contains("trading-hours")
        // --chart line: the stock page as a line of closes instead of candles.
        prefs.chartAsLine = options["chart"] == "line"
        // --overview table|relative: the overview's view (maps otherwise);
        // --benchmark c25: the index "Mod indeks" measures against.
        prefs.overviewMode = options["overview"].flatMap(OverviewMode.init(rawValue:)) ?? .maps
        if let benchmark = options["benchmark"] { prefs.benchmarkID = benchmark }
        if let index = options["index"] { app.indexID = index }
        if let tab = options["tab"].flatMap(PanelTab.init(rawValue:)) { app.tab = tab }
        // The map unless told otherwise, as the images in docs/ were made.
        app.screen = options["screen"] == "overview" ? .overview : .map
        if let watchlist = options["watchlist"],
           let list = ListsStore.shared.watchlists.first(where: { $0.name == watchlist }) {
            app.watchlistID = list.id
        }
        app.showList = flags.contains("list")
        if let period = options["period"].flatMap(Period.init(rawValue:)) { market.period = period }

        // The screener first: the fund's US stocks are checked against it.
        await market.refresh()

        // --add-list "Min portefølje" --items "NVDA,fund:IWDA.AS,index:c25":
        // that list, with exactly those items, opened.
        if let name = options["add-list"] {
            let id = await Self.fill(name, with: await Self.items(options["items"] ?? ""))
            app.openWatchlist(id)
        }
        // --fund SPY: the fund put in a list (the one named by --add-list or
        // --watchlist, or "Fonde") and opened from it, as a click on its tile does.
        if let symbol = options["fund"] {
            let fund = await Self.fund(symbol)
            let lists = ListsStore.shared
            let name = options["add-list"] ?? options["watchlist"] ?? tr("Fonde", "Funds")
            if let list = lists.watchlists.first(where: { $0.name == name }) {
                lists.add(.fund(fund), to: list.id)
                await FundStore.shared.ensureLoaded(fund.symbol)
            } else {
                await Self.fill(name, with: [.fund(fund)])
            }
            if let error = FundStore.shared.errors[fund.symbol] { print("Fond: \(error)") }
            if let list = lists.watchlists.first(where: { $0.name == name }) { app.openWatchlist(list.id) }
            app.openRef(fund.id)
        }
        // --open "fund:IWDA.AS" or "index:c25": a tile in the list on screen clicked.
        if let ref = options["open"] {
            app.openRef(ref)
            if let symbol = FundStore.symbol(fromID: ref) { await FundStore.shared.ensureLoaded(symbol) }
        }
        if options["screen"] == "overview" { app.showOverview() }
        // --search "MSCI World": the search dialog, open with results.
        // --fund-pick SEC0.DE: and with that fund picked and its holdings
        // loaded (or failed).
        if let query = options["search"] ?? options["fund-search"] {
            let picker = FundPicker.shared
            picker.query = query
            await picker.search(debounce: false)
            if let pick = options["fund-pick"],
               let result = picker.results.first(where: { $0.symbol.uppercased() == pick.uppercased() }) ?? picker.results.first {
                picker.select(result)
                await picker.waitForHoldings()
            }
            app.dialog = .search
            // --fund-add: and then "+ <list>" pressed for the picked fund
            // (the list on screen, or the first).
            if flags.contains("fund-add"), let result = picker.selected,
               let list = (app.tab == .watchlists ? app.watchlistID : nil) ?? ListsStore.shared.watchlists.first?.id {
                picker.add(result, to: list)
                await market.loadPeriod(.day, force: false)
            }
        }
        // --dialog new-list | rename-list: the watchlist dialogs.
        switch options["dialog"] {
        case "new-list"?:
            app.dialog = .newWatchlist(items: [])
        case "rename-list"?:
            let lists = ListsStore.shared
            let id = lists.watchlists.first?.id ?? lists.createWatchlist(named: tr("Tech-aktier", "Tech stocks"))
            app.dialog = .renameWatchlist(id)
        default:
            break
        }

        await market.refresh()
        if market.period != .day { await market.loadPeriod(market.period, force: false) }

        if let industry = options["industry"], let sector = options["sector"] {
            app.focus = .industry(sector: sector, industry: industry)
        } else if let sector = options["sector"] {
            app.focus = .sector(sector)
        }

        if prefs.overviewMode == .relative { await DailyLinesStore.shared.waitForLoad() }
        if prefs.overviewMode == .table { await market.loadHeadlines() }
        // --figures: every index's figure for the range and where it came
        // from, printed — to check them against the exchanges.
        if flags.contains("figures") {
            // With --overview relative, also where each card's line ends.
            let lines = DailyLinesStore.shared
            func end(_ kind: OverviewKind) -> String {
                guard let last = lines.line(kind)?.values.last(where: { $0 != nil }) ?? nil else { return "" }
                return "\tline ends \(Format.percent(last))"
            }
            for index in UniverseStore.shared.indices where !index.isFund {
                let figure = market.indexFigure(index, market.period)
                print("\(index.id)\t\(index.benchmark)\t\(Format.percent(figure.change))\t\(figure.source?.name ?? "–")\(end(.index(index.id)))")
            }
            for list in ListsStore.shared.watchlists {
                let figure = market.listFigure(list.items, market.period)
                print("list\t\(list.name)\t\(Format.percent(figure.change))\taverage\(end(.watchlist(list.id)))")
            }
        }
        // --stock NVDA: the stock page, with its chart loaded.
        if let stock = options["stock"] {
            app.openStock(stock)
            await market.loadPeriod(market.period, force: true)
            await StockChartStore.shared.waitForLoad(stock, period: market.period)
        }

        // The main window's content, at --window 1200x780 or a --size (without
        // the real title bar, which AppKit draws; the traffic lights' space
        // is left empty as in the window).
        // --fullscreen: the map alone, as in Map Only, on a 1440×900 screen.
        // --settings (or the old --tab settings): the Settings window.
        let fullscreen = flags.contains("fullscreen")
        let settings = flags.contains("settings") || options["tab"] == "settings"
        let windowSize = options["window"].flatMap(Self.parseSize) ?? Self.namedSize(options["size"])
        let size = fullscreen ? CGSize(width: 1440, height: 900)
            : settings ? CGSize(width: 540, height: 700) : windowSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // --seismograph 0.4: the seismograph open, paused 40 % into the range.
        if let fraction = (options["seismograph"] ?? options["replay"]).flatMap(Double.init) {
            let replay = ReplayStore.shared
            replay.start()
            for _ in 0..<120 where !replay.isReady { try? await Task.sleep(for: .milliseconds(250)) }
            replay.pause()
            replay.frame = Int(Double(max(replay.timeline.count - 1, 0)) * min(max(fraction, 0), 1))
        }
        // --notch 32: full screen as on a display with a notch.
        let notch = CGFloat(options["notch"].flatMap(Double.init) ?? 0)
        let root: AnyView
        if fullscreen {
            root = AnyView(FullscreenView(topInset: notch))
        } else if settings {
            root = AnyView(SettingsWindowContent())
        } else {
            root = AnyView(PanelRoot(size: windowSize))
        }
        let host = NSHostingView(rootView: root)
        host.appearance = prefs.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // Far off screen, so the mouse does not cause a stray tooltip.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.alphaValue = 0.01

        // Let layout and GeometryReader settle, also after zoom.
        try? await Task.sleep(for: .milliseconds(600))
        if let zoom = options["zoom"].flatMap(Double.init) {
            app.zoom = zoom
            app.offset = CGPoint(x: size.width * (zoom - 1) * 0.1, y: size.height * (zoom - 1) * 0.1)
            try? await Task.sleep(for: .milliseconds(400))
        }
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fputs("Kunne ikke rendere\n", stderr)
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: output)
            print("Skrev \(output.path) (\(Int(size.width))×\(Int(size.height)))")
            if let error = market.errorMessage { print("Fejl i data: \(error)") }
            exit(0)
        } catch {
            fputs("Kunne ikke skrive \(output.path): \(error)\n", stderr)
            exit(1)
        }
    }
}
