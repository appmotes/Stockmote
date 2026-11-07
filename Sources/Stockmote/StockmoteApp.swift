import AppKit
import StockmoteShared
import SwiftUI

@main
struct StockmoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menubar-ikonet og panelet laves i AppKit af MenuBarPanel. Settings-
        // scenen er kun noget at give SwiftUI — men den er ikke usynlig: når
        // appen er aktiv (efter fuld skærm eller "Om Stockmote"), åbner ⌘,
        // den som et tomt vindue — og SwiftUI viser det af og til selv ved
        // start. Menupunktet erstattes derfor, så ⌘, åbner panelets egne
        // indstillinger, og vinduet lukker sig selv, usynligt, hvis det
        // alligevel kommer frem.
        Settings { SettingsRedirect() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(tr("Indstillinger…", "Settings…")) { openPanelSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

/// Viser indstillingerne i panelet — det eneste sted de findes.
@MainActor
func openPanelSettings() {
    if FullscreenController.shared.isShowing { FullscreenController.shared.close() }
    AppState.shared.tab = .settings
    MenuBarPanel.current?.show()
}

/// Indholdet af SwiftUI's indstillingsvindue: lukker vinduet med det samme.
/// Det åbner ikke panelet — vinduet kan komme frem af sig selv ved start, og så
/// skal der ikke ske noget. ⌘, går gennem menukommandoen ovenfor.
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

/// Holder appen ude af docken også når den kører via `swift run` (i .app-bundlen
/// gør LSUIElement det samme) og bygger menubar-ikonet.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarPanel?
    /// Et klik på widget'en kan starte appen; så kommer URL'en før menubaren
    /// er bygget.
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
            // Fondenes beholdninger hentes igen når de er en uge gamle.
            FundStore.shared.refreshStale()
            WidgetSync.shared.start()
            if let pendingURL {
                self.pendingURL = nil
                handle(pendingURL)
            }
        }
    }

    /// `stockmote://open?tab=favorites&index=ndx` — fra widget'en.
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

/// `Stockmote --snapshot ud.png [--tab map|favorites|watchlists|settings]
/// [--index sp500|ndx|dji] [--period 1D|1U|1M|3M|ÅTD|1Å] [--sector "…"]
/// [--industry "…"] [--size small|medium|large|huge] [--list] [--zoom 2.5]
/// [--theme light|dark] [--lang da|en] [--no-sidebar] [--fullscreen [--notch 32]]
/// [--replay 0.4] [--fund SPY] [--fund-search "MSCI World"]`
///
/// Henter rigtige data, renderer panelet til en PNG og afslutter. Bruges til
/// billederne i docs/ og til at se UI'et uden at klikke rundt.
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

        // Screeneren først: fondens amerikanske aktier tjekkes mod den.
        await market.refresh()

        // --fund SPY: fonden tilføjes (som om den var fundet i søgefeltet) og
        // vises. Navn og type slås op i Yahoo's søgning.
        if let symbol = options["fund"] {
            let funds = FundStore.shared
            let found = await FundStore.search(symbol).first { $0.symbol.uppercased() == symbol.uppercased() }
            funds.add(found?.fund ?? Fund(symbol: symbol.uppercased(), name: symbol.uppercased(), kind: "ETF"))
            app.indexID = FundStore.id(found?.symbol ?? symbol.uppercased())
            app.tab = .map
            await funds.ensureLoaded(found?.symbol ?? symbol.uppercased())
            if let error = funds.errors[found?.symbol ?? symbol.uppercased()] { print("Fond: \(error)") }
        }
        // --fund-search "MSCI World": søgefeltet under Fonde, åbent med resultater.
        if let query = options["fund-search"] {
            app.fundSearchOpen = true
            app.fundQuery = query
        }

        await market.refresh()
        if market.period != .day { await market.loadPeriod(market.period, force: false) }

        if let industry = options["industry"], let sector = options["sector"] {
            app.focus = .industry(sector: sector, industry: industry)
        } else if let sector = options["sector"] {
            app.focus = .sector(sector)
        }

        // --fullscreen: kortet alene, som i fuldskærm, på en 1440×900-skærm.
        let fullscreen = flags.contains("fullscreen")
        let size = fullscreen ? CGSize(width: 1440, height: 900) : prefs.panelSize.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // --replay 0.4: afspilning stoppet 40 % inde i tidsrummet.
        if let fraction = options["replay"].flatMap(Double.init) {
            let replay = ReplayStore.shared
            replay.start()
            for _ in 0..<120 where !replay.isReady { try? await Task.sleep(for: .milliseconds(250)) }
            replay.pause()
            replay.frame = Int(Double(max(replay.timeline.count - 1, 0)) * min(max(fraction, 0), 1))
        }
        // --notch 32: fuldskærm som på en skærm med notch.
        let notch = CGFloat(options["notch"].flatMap(Double.init) ?? 0)
        let host = NSHostingView(rootView: fullscreen ? AnyView(FullscreenView(topInset: notch)) : AnyView(PanelRoot()))
        host.appearance = prefs.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // Langt uden for skærmen, så musen ikke giver en tilfældig tooltip.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.alphaValue = 0.01

        // Lad layout og GeometryReader falde på plads, også efter zoom.
        try? await Task.sleep(for: .milliseconds(600))
        // Søgningen svarer først efter en pause i skrivningen og et kald til Yahoo.
        if options["fund-search"] != nil { try? await Task.sleep(for: .seconds(3)) }
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
