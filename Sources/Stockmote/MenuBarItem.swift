import AppKit
import StockmoteShared
import Combine

/// The menu bar icon with the chosen index's change next to it.
///
/// Stockmote has one window, MainWindow; the icon is a way to it. A click
/// brings the window forward (opening it if it is closed or minimised), and
/// a click while the window is already in front puts it away again — the
/// app keeps running in the menu bar. In Map Only the click leaves Map Only.
/// Right-click (or ⌃-click) gives a small menu: open the window, Settings,
/// Quit — the only way to quit when the app runs from the menu bar alone,
/// where it has no Dock icon and no menu bar of its own.
@MainActor
final class MenuBarItem: NSObject {
    private let statusItem: NSStatusItem
    private var titleKey: String?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading
        updateLabel()

        // receive(on:) pushes the update to after the change —
        // objectWillChange fires before.
        MarketStore.shared.objectWillChange
            .merge(with: Preferences.shared.objectWillChange)
            .merge(with: UniverseStore.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)
    }

    // MARK: Label

    private func updateLabel() {
        let market = MarketStore.shared
        let prefs = Preferences.shared
        let index = prefs.menuBarIndexID.flatMap(UniverseStore.shared.index(withID:))
        let figure = index.map { market.indexFigure($0, .day) }
        let change = figure?.change
        let failed = market.quotes.isEmpty && market.errorMessage != nil

        let symbol = failed ? "exclamationmark.triangle" : "square.grid.2x2.fill"
        // "≈" marks a NAV fund's indicative value, as everywhere else.
        let text = figure.map { ($0.isIndicative && change != nil ? "≈ " : "") + Format.arrowPercent(change) } ?? ""
        // Icon and number in the app's colours: green up, red down (or blue/orange).
        // The system colours, because they adjust themselves to a light and dark menu bar.
        // Without a number — or at exactly 0 — the icon is a plain template.
        let tint: NSColor? = {
            guard let change, change != 0, !failed else { return nil }
            switch prefs.colorStyle {
            case .redGreen: return change > 0 ? .systemGreen : .systemRed
            case .blueOrange: return change > 0 ? .systemBlue : .systemOrange
            }
        }()
        let key = "\(symbol)|\(text)|\(tint?.description ?? "-")|\(Lang.isEnglish)"
        guard key != titleKey, let button = statusItem.button else { return }
        titleKey = key

        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let tint {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stockmote")?
            .withSymbolConfiguration(config)
        image?.isTemplate = tint == nil
        button.image = image

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        ]
        if let tint { attributes[.foregroundColor] = tint }
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " \(text)", attributes: attributes)
        var tip = "Stockmote"
        if let index { tip += " · \(index.name) \(Format.percent(change)) " + tr("i dag", "today") }
        if let error = market.errorMessage { tip += "\n\(error)" }
        button.toolTip = tip
    }

    // MARK: Click

    /// "Dock only" in settings hides the icon.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    @objc private func clicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        // In Map Only the icon leaves Map Only — same button, opposite direction.
        if FullscreenController.shared.isShowing {
            FullscreenController.shared.close()
            return
        }
        let window = MainWindow.shared
        // Already in front: the click puts the window away, as a second click
        // on a menu bar item closes what the first one opened. A window in
        // macOS full screen stays: closing it from its own Space is jarring.
        if window.isFrontmost, !window.isFullScreen {
            window.close()
        } else {
            window.show()
        }
    }

    /// The right-click menu, built each time so it follows the language.
    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: tr("Åbn vindue", "Open Window"), action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: tr("Indstillinger …", "Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Afslut Stockmote", "Quit Stockmote"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        // The classic way to drop a menu from a status item that also has a
        // click action: attach it for this one click.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openWindow() { MainWindow.shared.show() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
}
