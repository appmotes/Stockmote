import AppKit
import StockmoteShared
import Combine
import SwiftUI

/// The menu bar icon and the compact panel below it — the quick look. The
/// main window (MainWindow) is the full app; "Open window" in the panel's
/// sidebar or ⌘O goes there.
///
/// Built in AppKit as in DRmote: a window we create ourselves can be painted fully
/// black, and it can change size when you pick another panel size.
/// `MenuBarExtra(.window)` can do neither.
@MainActor
final class MenuBarPanel: NSObject {
    /// The one menu bar — so full screen and the main window can close the panel.
    static weak var current: MenuBarPanel?

    private let statusItem: NSStatusItem
    private var panel: Panel?
    private var host: NSHostingView<PanelRoot>?
    private var monitors: [Any] = []
    private var titleKey: String?
    private var lastClose = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        Self.current = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
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

        Preferences.shared.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.host?.appearance = Preferences.shared.appearance }
            .store(in: &cancellables)

        Preferences.shared.$panelSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)
    }

    // MARK: Menu bar

    private func updateLabel() {
        let market = MarketStore.shared
        let prefs = Preferences.shared
        let index = prefs.menuBarIndexID.flatMap(UniverseStore.shared.index(withID:))
        let change = index.flatMap { market.indexChange($0, .day) }
        let failed = market.quotes.isEmpty && market.errorMessage != nil

        let symbol = failed ? "exclamationmark.triangle" : "square.grid.2x2.fill"
        let text = index.map { _ in Format.arrowPercent(change) } ?? ""
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

    // MARK: Panel

    func hide() {
        close()
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// "Dock only" in settings hides the icon (and with it the panel).
    func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        if !visible { close() }
    }

    /// Click on the icon: opens the panel, or closes it if it is open.
    @objc private func toggle() {
        // In full screen the icon closes full screen — same button, opposite direction.
        if FullscreenController.shared.isShowing {
            FullscreenController.shared.close()
            return
        }
        if panel?.isVisible == true {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.35 {
            // If the global monitor closed the panel on this very click (see
            // open()), the click should not open it again.
            open()
        }
    }

    /// The icon's frame on screen.
    private var statusItemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Opens the panel if it is not already open. Used by the widget.
    func show() {
        if panel?.isVisible != true { open() }
    }

    private func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applySize(to: panel)
        panel.makeKeyAndOrderFront(nil)
        LiveRefresh.update()

        // A global monitor only sees clicks in *other* apps, so it does not get in
        // the way of our own icon, panel, menus or popovers.
        monitors = [
            // On newer macOS, menu bar icons are drawn by another process, so a
            // click on our own icon also arrives here. It should not close —
            // toggle() handles that — otherwise the panel closes on mouse down and
            // opens again on release.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    if let frame = self.statusItemFrame, frame.insetBy(dx: -2, dy: -2).contains(location) { return }
                    self.close()
                }
            },
            // A click in one of our own windows (the main window, Settings)
            // closes the panel too. The icon is left to toggle(), as above.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = event.window, window !== self.panel,
                      window !== self.statusItem.button?.window else { return event }
                self.close()
                return event
            },
            // Only keys meant for the panel: the main window has its own monitor.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                return PanelKeys.handle(event) { self.close() }
            }
        ].compactMap { $0 }
    }

    private func close() {
        if panel?.isVisible == true { lastClose = Date() }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        LiveRefresh.update()
    }

    private func resize() {
        guard let panel, panel.isVisible else { return }
        applySize(to: panel)
    }

    private func applySize(to panel: NSPanel) {
        let size = Preferences.shared.panelSize.size
        panel.setContentSize(size)
        host?.frame = NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(origin(for: panel))
    }

    private func makePanel() -> Panel {
        let size = Preferences.shared.panelSize.size
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        // fullScreenAuxiliary: the panel also opens over the main window when
        // that is in full screen on its own Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        let backdrop = NSView()
        backdrop.wantsLayer = true
        // No colour here: the SwiftUI root paints the background in the chosen theme.
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor(white: 0.5, alpha: 0.25).cgColor

        let host = NSHostingView(rootView: PanelRoot(context: .panel))
        // Light, dark or as the system — see Preferences.theme.
        host.appearance = Preferences.shared.appearance
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        backdrop.addSubview(host)
        self.host = host

        panel.contentView = backdrop
        return panel
    }

    /// The panel is hung below the icon and kept within the screen.
    private func origin(for panel: NSPanel) -> NSPoint {
        guard let button = statusItem.button, let buttonWindow = button.window else { return .zero }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX + 8),
                    visible.maxX - panel.frame.width - 8)
        let y = max(anchor.minY - panel.frame.height - 6, visible.minY + 8)
        return NSPoint(x: x, y: y)
    }

    /// Otherwise a borderless window cannot become key, and then neither
    /// the search field, the keyboard shortcuts nor Esc work.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
