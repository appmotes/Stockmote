import AppKit
import StockmoteShared
import Combine
import SwiftUI

/// Menubar-ikonet og panelet under det.
///
/// Bygget i AppKit som i DRmote: et vindue vi selv opretter kan males helt
/// sort, og det kan skifte størrelse når man vælger en anden panelstørrelse.
/// `MenuBarExtra(.window)` kan ingen af delene.
@MainActor
final class MenuBarPanel: NSObject {
    /// Den ene menubar — så fuldskærm kan lukke panelet.
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

        // receive(on:) skubber opdateringen til efter ændringen —
        // objectWillChange fyrer før.
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

    // MARK: Menubar

    private func updateLabel() {
        let market = MarketStore.shared
        let prefs = Preferences.shared
        let index = prefs.menuBarIndexID.flatMap(UniverseStore.shared.index(withID:))
        let change = index.flatMap { market.indexChange($0, .day) }
        let failed = market.quotes.isEmpty && market.errorMessage != nil

        let symbol = failed ? "exclamationmark.triangle" : "square.grid.2x2.fill"
        let text = index.map { _ in Format.arrowPercent(change) } ?? ""
        // Ikon og tal i appens farver: grøn op, rød ned (eller blå/orange).
        // Systemfarverne, fordi de selv justerer sig til lys og mørk menubar.
        // Uden tal — eller ved præcis 0 — er ikonet en almindelig skabelon.
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

    /// Klik på ikonet: åbner panelet, eller lukker det hvis det er åbent.
    @objc private func toggle() {
        // I fuldskærm lukker ikonet fuldskærm — samme knap, modsat vej.
        if FullscreenController.shared.isShowing {
            FullscreenController.shared.close()
            return
        }
        if panel?.isVisible == true {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.35 {
            // Lukkede den globale monitor panelet på selve dette klik (se
            // open()), skal klikket ikke åbne det igen.
            open()
        }
    }

    /// Ikonets ramme på skærmen.
    private var statusItemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Åbner panelet, hvis det ikke allerede er åbent. Bruges af widget'en.
    func show() {
        if panel?.isVisible != true { open() }
    }

    private func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applySize(to: panel)
        panel.makeKeyAndOrderFront(nil)
        MarketStore.shared.panelVisible = true

        // En global monitor ser kun klik i *andre* apps, så den kommer ikke på
        // tværs af vores eget ikon, panel, menuer eller popovers.
        monitors = [
            // På nyere macOS tegnes menubar-ikoner af en anden proces, så et
            // klik på vores eget ikon kommer også her. Det skal ikke lukke —
            // det klarer toggle() — ellers lukker panelet ved museklik ned og
            // åbner igen ved slip.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    if let frame = self.statusItemFrame, frame.insetBy(dx: -2, dy: -2).contains(location) { return }
                    self.close()
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if ReplayKeys.handle(event) { return nil }
                guard event.keyCode == 53 else { return event }   // 53 = Escape
                // Et tekstfelt med indhold får selv lov at rydde op.
                if let editor = event.window?.firstResponder as? NSTextView, !editor.string.isEmpty {
                    return event
                }
                if AppState.shared.handleEscape() { return nil }
                Task { @MainActor in self?.close() }
                return nil
            }
        ].compactMap { $0 }
    }

    private func close() {
        if panel?.isVisible == true { lastClose = Date() }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        MarketStore.shared.panelVisible = false
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
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let backdrop = NSView()
        backdrop.wantsLayer = true
        // Ingen farve her: SwiftUI-roden maler baggrunden i det valgte tema.
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor(white: 0.5, alpha: 0.25).cgColor

        let host = NSHostingView(rootView: PanelRoot())
        // Lyst, mørkt eller som systemet — se Preferences.theme.
        host.appearance = Preferences.shared.appearance
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        backdrop.addSubview(host)
        self.host = host

        panel.contentView = backdrop
        return panel
    }

    /// Panelet hænges under ikonet og holdes indenfor skærmen.
    private func origin(for panel: NSPanel) -> NSPoint {
        guard let button = statusItem.button, let buttonWindow = button.window else { return .zero }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX + 8),
                    visible.maxX - panel.frame.width - 8)
        let y = max(anchor.minY - panel.frame.height - 6, visible.minY + 8)
        return NSPoint(x: x, y: y)
    }

    /// Et borderless vindue kan ellers ikke blive key, og så virker hverken
    /// søgefeltet, tastaturgenveje eller Esc.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
