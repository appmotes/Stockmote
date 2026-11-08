import AppKit
import Combine
import StockmoteShared

/// The main menu, built in AppKit so every title goes through `tr()` and
/// follows the in-app language — the standard menus SwiftUI makes are named
/// in the system's language. Rebuilt when the language changes.
///
/// Titles and checkmarks that depend on state (Hide/Show Sidebar, the chosen
/// time range …) are set in `validateMenuItem`, which AppKit calls each time
/// the menu opens or a shortcut is checked.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    static let shared = MainMenu()

    private var cancellables: Set<AnyCancellable> = []

    func install() {
        NSApp.mainMenu = build()
        guard cancellables.isEmpty else { return }
        Preferences.shared.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.install() }
            .store(in: &cancellables)
    }

    private func build() -> NSMenu {
        let main = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Stockmote")
        menu.addItem(item(tr("Om Stockmote", "About Stockmote"), #selector(about)))
        menu.addItem(.separator())
        menu.addItem(item(tr("Indstillinger …", "Settings…"), #selector(openSettings), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: tr("Tjenester", "Services"))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item(tr("Skjul Stockmote", "Hide Stockmote"), #selector(NSApplication.hide(_:)), "h", system: true))
        menu.addItem(item(tr("Skjul andre", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                          [.command, .option], system: true))
        menu.addItem(item(tr("Vis alle", "Show All"), #selector(NSApplication.unhideAllApplications(_:)), system: true))
        menu.addItem(.separator())
        menu.addItem(item(tr("Afslut Stockmote", "Quit Stockmote"), #selector(NSApplication.terminate(_:)), "q", system: true))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: tr("Arkiv", "File"))
        menu.addItem(item(tr("Åbn vindue", "Open Window"), #selector(openWindow), "o"))
        menu.addItem(.separator())
        menu.addItem(item(tr("Ny watchliste …", "New Watchlist…"), #selector(newWatchlist), "n"))
        menu.addItem(item(tr("Søg …", "Search…"), #selector(search), "k"))
        menu.addItem(.separator())
        menu.addItem(item(tr("Luk vindue", "Close Window"), #selector(NSWindow.performClose(_:)), "w", system: true))
        return menu
    }

    /// Needed for ⌘C, ⌘V and ⌘A in the search fields: those go through the menu.
    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: tr("Rediger", "Edit"))
        menu.addItem(item(tr("Fortryd", "Undo"), Selector(("undo:")), "z", system: true))
        menu.addItem(item(tr("Gentag", "Redo"), Selector(("redo:")), "z", [.command, .shift], system: true))
        menu.addItem(.separator())
        menu.addItem(item(tr("Klip", "Cut"), #selector(NSText.cut(_:)), "x", system: true))
        menu.addItem(item(tr("Kopiér", "Copy"), #selector(NSText.copy(_:)), "c", system: true))
        menu.addItem(item(tr("Sæt ind", "Paste"), #selector(NSText.paste(_:)), "v", system: true))
        menu.addItem(item(tr("Vælg alt", "Select All"), #selector(NSText.selectAll(_:)), "a", system: true))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: tr("Vis", "View"))
        // ⌘1 … ⌘9 are the indices, so the ten time ranges get ⌥⌘1 … ⌥⌘9 and ⌥⌘0.
        for (number, period) in Period.allCases.enumerated() {
            let entry = item("\(period.label)  ·  \(period.longName)", #selector(setPeriod(_:)),
                             "\((number + 1) % 10)", [.command, .option])
            entry.representedObject = period.rawValue
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(tr("Vis som liste", "Show as List"), #selector(toggleList), "l"))
        menu.addItem(item(tr("Overblik", "Overview"), #selector(showOverview), "0"))
        menu.addItem(item(tr("Handelstider på overblikket", "Trading Hours on Overview"), #selector(toggleTradingHours)))
        menu.addItem(item(tr("Tilbage", "Back"), #selector(goBack), "["))
        menu.addItem(.separator())
        menu.addItem(item(tr("Seismograf", "Seismograph"), #selector(toggleReplay), "p"))
        menu.addItem(item(tr("Skift til lyst tema", "Switch to Light Theme"), #selector(toggleTheme), "t", [.command, .shift]))
        menu.addItem(item(tr("Opdatér", "Refresh"), #selector(refresh), "r"))
        menu.addItem(.separator())
        menu.addItem(item(tr("Kun kortet", "Map Only"), #selector(toggleMapOnly), "f", [.command, .shift]))
        // Not AppKit's toggleFullScreen: — AppKit renames items with that
        // action in the system's language, not the app's.
        menu.addItem(item(tr("Fuld skærm", "Enter Full Screen"), #selector(toggleFullScreen), "f", [.command, .control]))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: tr("Vindue", "Window"))
        menu.addItem(item(tr("Minimér", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", system: true))
        menu.addItem(item(tr("Zoom", "Zoom"), #selector(NSWindow.performZoom(_:)), system: true))
        menu.addItem(.separator())
        menu.addItem(item(tr("Anbring alle forrest", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), system: true))
        // AppKit lists the open windows below.
        NSApp.windowsMenu = menu
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: tr("Hjælp", "Help"))
        menu.addItem(item(tr("Tastaturgenveje", "Keyboard Shortcuts"), #selector(showShortcuts)))
        NSApp.helpMenu = menu
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command, system: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        // System actions (hide, copy, close …) go up the responder chain.
        item.target = system ? nil : self
        return item
    }

    // MARK: State

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let market = MarketStore.shared
        switch item.action {
        case #selector(setPeriod(_:)):
            item.state = (item.representedObject as? String) == market.period.rawValue ? .on : .off
        case #selector(toggleTradingHours):
            item.state = Preferences.shared.showTradingHours ? .on : .off
        case #selector(toggleList):
            item.state = AppState.shared.showList ? .on : .off
        case #selector(toggleReplay):
            item.state = ReplayStore.shared.isActive ? .on : .off
            return AppState.shared.isMap
        case #selector(goBack):
            return AppState.shared.screen != .overview
        case #selector(toggleTheme):
            item.title = isDark ? tr("Skift til lyst tema", "Switch to Light Theme")
                                : tr("Skift til mørkt tema", "Switch to Dark Theme")
        case #selector(toggleMapOnly):
            item.state = FullscreenController.shared.isShowing ? .on : .off
        case #selector(toggleFullScreen):
            item.title = MainWindow.shared.isFullScreen ? tr("Afslut fuld skærm", "Exit Full Screen")
                                                        : tr("Fuld skærm", "Enter Full Screen")
        default:
            break
        }
        return true
    }

    private var isDark: Bool {
        let appearance = Preferences.shared.appearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Actions

    @objc private func about() { showAbout() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func openWindow() { MainWindow.shared.show() }
    @objc private func newWatchlist() { present(.newWatchlist(items: [])) }
    @objc private func search() { present(.search) }

    /// Dialogs live inside the main window, which is opened first.
    private func present(_ dialog: PanelDialog) {
        MainWindow.shared.show()
        AppState.shared.dialog = dialog
    }

    @objc private func setPeriod(_ sender: NSMenuItem) {
        guard let period = (sender.representedObject as? String).flatMap(Period.init(rawValue:)) else { return }
        MarketStore.shared.period = period
    }

    @objc private func toggleList() { AppState.shared.showList.toggle() }
    @objc private func toggleTradingHours() { Preferences.shared.showTradingHours.toggle() }
    @objc private func showOverview() { MainWindow.shared.show(); AppState.shared.showOverview() }
    @objc private func goBack() { AppState.shared.goBack() }
    @objc private func toggleReplay() { ReplayStore.shared.toggle() }
    @objc private func toggleTheme() { Preferences.shared.theme = isDark ? .light : .dark }
    @objc private func refresh() { Task { await MarketStore.shared.refresh() } }
    @objc private func toggleMapOnly() { FullscreenController.shared.toggle() }
    @objc private func toggleFullScreen() { MainWindow.shared.toggleFullScreen() }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = tr("Tastaturgenveje", "Keyboard Shortcuts")
        alert.informativeText = tr("""
            ⌘K eller /  Søg aktie, indeks eller fond
            ⌘0  Overblik · ⌘1 … ⌘9  Indeks
            Esc eller ⌘[  Et niveau op: aktie → kort → overblik
            ⌥⌘1 … ⌥⌘0  Tidsrum: 1D … Alt
            ⌘L  Kort / liste
            ⌘P  Seismograf · mellemrum afspiller, ← → et trin
            ⇧⌘T  Lyst / mørkt tema
            ⌘R  Opdatér
            ⌃⌘F  Fuld skærm
            ⇧⌘F  Kun kortet, kant til kant
            ⌘N  Ny watchliste
            ⌘O  Åbn vindue · ⌘,  Indstillinger
            """, """
            ⌘K or /  Search for a stock, index or fund
            ⌘0  Overview · ⌘1 … ⌘9  Index
            Esc or ⌘[  Up one level: stock → map → overview
            ⌥⌘1 … ⌥⌘0  Time range: 1D … All
            ⌘L  Map / list
            ⌘P  Seismograph · space plays, ← → one step
            ⇧⌘T  Light / dark theme
            ⌘R  Refresh
            ⌃⌘F  Full screen
            ⇧⌘F  Map only, edge to edge
            ⌘N  New watchlist
            ⌘O  Open window · ⌘,  Settings
            """)
        alert.addButton(withTitle: tr("Luk", "Close"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
