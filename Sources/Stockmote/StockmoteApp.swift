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
        if let tab = items.first(where: { $0.name == "tab" })?.value.flatMap(PanelTab.init(rawValue:)) {
            app.tab = tab
        }
        // A watchlist widget names its list.
        if let name = items.first(where: { $0.name == "list" })?.value,
           let list = ListsStore.shared.watchlists.first(where: { $0.name == name }) {
            app.watchlistID = list.id
        }
        app.focus = .all
        app.screen = .map
        if FullscreenController.shared.isShowing { FullscreenController.shared.close() }
        MainWindow.shared.show()
    }
}

/// `Stockmote --snapshot out.png [--screen overview|map] [--tab map|favorites|watchlists]
/// [--index sp500|ndx|dji] [--period 1D|1U|1M|3M|6M|ÅTD|1Å|3Å|5Å|Alt] [--sector "…"]
/// [--industry "…"] [--stock NVDA] [--size small|medium|large|huge] [--list] [--zoom 2.5]
/// [--theme light|dark] [--lang da|en] [--fullscreen [--notch 32]]
/// [--seismograph 0.4] [--fund SPY] [--search "MSCI World" [--fund-pick URTH] [--fund-add]]
/// [--dialog new-list|rename-list] [--window 1200x780] [--settings]`
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

    func run() async {
        let app = AppState.shared
        let market = MarketStore.shared
        let prefs = Preferences.shared

        if let theme = options["theme"].flatMap(ThemeMode.init(rawValue:)) { prefs.theme = theme }
        if let lang = options["lang"] { prefs.language = lang == "en" ? .english : .danish }
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

        // --fund SPY: the fund is added (as if it had been found in the search field) and
        // shown. Name and type are looked up in Yahoo's search.
        if let symbol = options["fund"] {
            let funds = FundStore.shared
            let found = await FundStore.search(symbol).first { $0.symbol.uppercased() == symbol.uppercased() }
            funds.add(found?.fund ?? Fund(symbol: symbol.uppercased(), name: symbol.uppercased(), kind: "ETF"))
            app.indexID = FundStore.id(found?.symbol ?? symbol.uppercased())
            app.tab = .map
            await funds.ensureLoaded(found?.symbol ?? symbol.uppercased())
            if let error = funds.errors[found?.symbol ?? symbol.uppercased()] { print("Fond: \(error)") }
        }
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
            // --fund-add: and then the Add button pressed.
            if flags.contains("fund-add") {
                picker.commit()
                await market.loadPeriod(.day, force: false)
            }
        }
        // --dialog new-list | rename-list: the watchlist dialogs.
        switch options["dialog"] {
        case "new-list"?:
            app.dialog = .newWatchlist(symbols: [])
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
