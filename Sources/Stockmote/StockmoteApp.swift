import AppKit
import StockmoteShared
import SwiftUI

@main
struct StockmoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar icon and the panel are made in AppKit by MenuBarPanel. The Settings
        // scene is only something to give SwiftUI — but it is not invisible: when
        // the app is active (after full screen or "About Stockmote"), ⌘, opens
        // it as an empty window — and SwiftUI now and then shows it by itself at
        // launch. So the menu item is replaced, making ⌘, open the panel's own
        // settings, and the window closes itself, invisibly, if it
        // shows up anyway.
        Settings { SettingsRedirect() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(tr("Indstillinger…", "Settings…")) { openPanelSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

/// Shows the settings in the panel — the only place they exist.
@MainActor
func openPanelSettings() {
    if FullscreenController.shared.isShowing { FullscreenController.shared.close() }
    AppState.shared.tab = .settings
    MenuBarPanel.current?.show()
}

/// The content of SwiftUI's settings window: closes the window right away.
/// It does not open the panel — the window can show up by itself at launch, and then
/// nothing should happen. ⌘, goes through the menu command above.
private struct SettingsRedirect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Closer() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Closer: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    Self.redirect(window)
                })
            }
            window.alphaValue = 0
            if window.isVisible { Self.redirect(window) }
        }

        private static func redirect(_ window: NSWindow) {
            window.alphaValue = 0
            DispatchQueue.main.async { window.close() }
        }
    }
}

/// Keeps the app out of the Dock even when it runs via `swift run` (in the .app bundle
/// LSUIElement does the same) and builds the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarPanel?
    /// A click on the widget can launch the app; then the URL arrives before the menu bar
    /// is built.
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            Task { @MainActor in await snapshot.run() }
            return
        }

        MainActor.assumeIsolated {
            menuBar = MenuBarPanel()
            MarketStore.shared.start()
            // The funds' holdings are fetched again when they are a week old.
            FundStore.shared.refreshStale()
            WidgetSync.shared.start()
            if let pendingURL {
                self.pendingURL = nil
                handle(pendingURL)
            }
        }
    }

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

    @MainActor
    private func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = AppState.shared
        if let tab = items.first(where: { $0.name == "tab" })?.value.flatMap(PanelTab.init(rawValue:)) {
            app.tab = tab
        }
        if let index = items.first(where: { $0.name == "index" })?.value,
           UniverseStore.shared.index(withID: index) != nil {
            app.indexID = index
        }
        menuBar?.show()
    }
}

/// `Stockmote --snapshot out.png [--tab map|favorites|watchlists|settings]
/// [--index sp500|ndx|dji] [--period 1D|1U|1M|3M|ÅTD|1Å] [--sector "…"]
/// [--industry "…"] [--size small|medium|large|huge] [--list] [--zoom 2.5]
/// [--theme light|dark] [--lang da|en] [--no-sidebar] [--fullscreen [--notch 32]]
/// [--replay 0.4] [--fund SPY] [--fund-search "MSCI World" [--fund-pick URTH] [--fund-add]]
/// [--dialog new-list|rename-list]`
///
/// Fetches real data, renders the panel to a PNG and quits. Used for
/// the images in docs/ and to see the UI without clicking around.
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

    func run() async {
        let app = AppState.shared
        let market = MarketStore.shared
        let prefs = Preferences.shared

        if let size = options["size"].flatMap(PanelSize.init(rawValue:)) { prefs.panelSize = size }
        if let theme = options["theme"].flatMap(ThemeMode.init(rawValue:)) { prefs.theme = theme }
        if let lang = options["lang"] { prefs.language = lang == "en" ? .english : .danish }
        if flags.contains("no-sidebar") { prefs.sidebarVisible = false }
        if let index = options["index"] { app.indexID = index }
        if let tab = options["tab"].flatMap(PanelTab.init(rawValue:)) { app.tab = tab }
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
        // --fund-search "MSCI World": the add-fund dialog, open with results.
        // --fund-pick SEC0.DE: and with that result picked and its holdings
        // loaded (or failed).
        if let query = options["fund-search"] {
            let picker = FundPicker.shared
            picker.query = query
            await picker.search(debounce: false)
            if let pick = options["fund-pick"],
               let result = picker.results.first(where: { $0.symbol.uppercased() == pick.uppercased() }) ?? picker.results.first {
                picker.select(result)
                await picker.waitForHoldings()
            }
            app.dialog = .addFund
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

        // --fullscreen: the map alone, as in full screen, on a 1440×900 screen.
        let fullscreen = flags.contains("fullscreen")
        let size = fullscreen ? CGSize(width: 1440, height: 900) : prefs.panelSize.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // --replay 0.4: replay paused 40 % into the period.
        if let fraction = options["replay"].flatMap(Double.init) {
            let replay = ReplayStore.shared
            replay.start()
            for _ in 0..<120 where !replay.isReady { try? await Task.sleep(for: .milliseconds(250)) }
            replay.pause()
            replay.frame = Int(Double(max(replay.timeline.count - 1, 0)) * min(max(fraction, 0), 1))
        }
        // --notch 32: full screen as on a display with a notch.
        let notch = CGFloat(options["notch"].flatMap(Double.init) ?? 0)
        let host = NSHostingView(rootView: fullscreen ? AnyView(FullscreenView(topInset: notch)) : AnyView(PanelRoot()))
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
