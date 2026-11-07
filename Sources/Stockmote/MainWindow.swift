import AppKit
import Combine
import StockmoteShared
import SwiftUI

/// Where PanelRoot is shown: the compact panel under the menu bar icon, or
/// the main window. The two share all state (AppState, MarketStore …) but
/// differ in chrome: the window has traffic lights over the sidebar, no fixed
/// size, and leaves most keyboard shortcuts to the main menu.
enum PanelContext {
    case panel, window
}

private struct PanelContextKey: EnvironmentKey {
    static let defaultValue = PanelContext.panel
}

extension EnvironmentValues {
    var panelContext: PanelContext {
        get { self[PanelContextKey.self] }
        set { self[PanelContextKey.self] = newValue }
    }
}

/// What the SwiftUI content needs to know about the main window's title bar,
/// so the custom toolbar row lines up with the traffic lights.
@MainActor
final class WindowChrome: ObservableObject {
    static let shared = WindowChrome()

    /// In macOS full screen the traffic lights are gone (they slide in with the
    /// title bar), so nothing needs to make room for them.
    @Published var isFullScreen = false
    /// Room to leave at the leading edge for the traffic lights.
    @Published var trafficLightsInset: CGFloat = 78
    /// Height of the title bar, which the empty unified toolbar makes as tall
    /// as the custom toolbar row. The row and the sidebar header match it.
    @Published var titlebarHeight: CGFloat = 52
}

/// Keeps the quote refresh fast while any view of the map is on screen: the
/// panel, the main window or the map-only full screen.
@MainActor
enum LiveRefresh {
    static func update() {
        MarketStore.shared.panelVisible = MenuBarPanel.current?.isOpen == true
            || MainWindow.shared.isOnScreen
            || FullscreenController.shared.isShowing
    }
}

/// Keys shared by the panel and the main window: replay controls, and Esc,
/// which closes a dialog, then zoom, then replay, then goes up a level.
/// Returns nil when the key was used.
@MainActor
enum PanelKeys {
    static func handle(_ event: NSEvent, unhandledEscape: () -> Void) -> NSEvent? {
        if ReplayKeys.handle(event) { return nil }
        guard event.keyCode == 53 else { return event }   // 53 = Escape
        // An open dialog takes Esc first, even from a text field with text in
        // it: Esc cancels the dialog and never closes the panel or window.
        if AppState.shared.dialog != nil {
            AppState.shared.dialog = nil
            return nil
        }
        // A text field with content gets to clear itself first.
        if let editor = event.window?.firstResponder as? NSTextView, !editor.string.isEmpty {
            return event
        }
        if AppState.shared.handleEscape() { return nil }
        unhandledEscape()
        return nil
    }
}

/// The main window: a standard titled, resizable window with the same UI as
/// the panel, filling it. The title bar is transparent and the content runs
/// under it, so the traffic lights sit over the sidebar and the custom
/// toolbar row shares the title bar's height — like Mail or Notes.
///
/// AppKit rather than a SwiftUI `Window` scene: the app builds its own main
/// menu (so it follows the in-app language), and an NSWindow gives direct
/// control over frame autosave, full screen and reopening from the Dock.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()

    private static let autosaveName = "StockmoteMainWindow"
    private var window: NSWindow?
    private var monitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    var nsWindow: NSWindow? { window }
    var isOnScreen: Bool { window.map { $0.isVisible && !$0.isMiniaturized } ?? false }
    var isKey: Bool { window?.isKeyWindow == true }
    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// Opens the window, or brings it forward. Closes the panel: you have
    /// chosen the big view.
    func show() {
        MenuBarPanel.current?.hide()
        // Settings live in their own window here; the panel's settings tab
        // would otherwise fill the main window.
        if AppState.shared.tab == .settings { AppState.shared.toggleSettings() }
        let window = self.window ?? makeWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateChrome()
        LiveRefresh.update()
    }

    /// macOS full screen (its own Space). Opens the window first if needed.
    func toggleFullScreen() {
        if FullscreenController.shared.isShowing { FullscreenController.shared.close() }
        let wasOnScreen = isOnScreen
        show()
        if wasOnScreen {
            window?.toggleFullScreen(nil)
        } else {
            // A window that was just ordered in has to settle before it can
            // animate into its own Space.
            DispatchQueue.main.async { self.window?.toggleFullScreen(nil) }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Stockmote"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar makes the title bar ~52 pt tall and centres
        // the traffic lights in it, level with the custom toolbar row below.
        window.toolbar = NSToolbar(identifier: "StockmoteMain")
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // Size and position are kept by the frame autosave; the rest of the
        // state lives in AppState, so no window restoration.
        window.isRestorable = false
        window.appearance = Preferences.shared.appearance
        window.delegate = self

        let host = NSHostingView(rootView: PanelRoot(context: .window))
        // The window decides the size, not SwiftUI's ideal size.
        host.sizingOptions = []
        window.contentView = host

        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)

        // Esc and the replay keys, only for this window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            // Unhandled Esc does nothing: it never closes the window or leaves
            // full screen.
            return PanelKeys.handle(event) {}
        }

        Preferences.shared.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.appearance = Preferences.shared.appearance }
            .store(in: &cancellables)

        self.window = window
        return window
    }

    /// Measures where the traffic lights and the title bar actually are.
    private func updateChrome() {
        guard let window else { return }
        let chrome = WindowChrome.shared
        let fullScreen = window.styleMask.contains(.fullScreen)
        if chrome.isFullScreen != fullScreen { chrome.isFullScreen = fullScreen }
        guard !fullScreen else { return }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        if titlebar > 20, abs(titlebar - chrome.titlebarHeight) > 0.5 { chrome.titlebarHeight = titlebar }
        if let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview {
            let inset = superview.convert(zoom.frame, to: nil).maxX + 12
            if abs(inset - chrome.trafficLightsInset) > 0.5 { chrome.trafficLightsInset = inset }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        WindowChrome.shared.isFullScreen = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        WindowChrome.shared.isFullScreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateChrome()
    }

    /// In full screen the (empty) toolbar hides with the menu bar, so the map
    /// gets the whole screen.
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    func windowDidResize(_ notification: Notification) { updateChrome() }
    func windowDidMiniaturize(_ notification: Notification) { LiveRefresh.update() }
    func windowDidDeminiaturize(_ notification: Notification) { LiveRefresh.update() }
    func windowDidChangeOcclusionState(_ notification: Notification) { LiveRefresh.update() }

    func windowWillClose(_ notification: Notification) {
        // Closing only hides the window: the app keeps running in the menu
        // bar (or the Dock) and the window comes back as it was.
        DispatchQueue.main.async { LiveRefresh.update() }
    }
}

/// Empty space in the window's custom title bar row: drag to move the window,
/// double-click to zoom (or minimise, as set in System Settings) — what a real
/// title bar does. Placed behind the toolbar row and the sidebar header, so
/// their buttons still get their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize"?: window.performMiniaturize(nil)
                case "None"?: break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

// MARK: - Settings window

/// The standard Settings window (⌘,), with the same content as the panel's
/// settings tab.
@MainActor
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    var isVisible: Bool { window?.isVisible == true }
    var nsWindow: NSWindow? { window }

    func show() {
        let window = self.window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = tr("Indstillinger", "Settings")
        window.contentMinSize = NSSize(width: 500, height: 360)
        window.contentMaxSize = NSSize(width: 760, height: 1200)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = Preferences.shared.appearance

        let host = NSHostingView(rootView: SettingsWindowContent())
        host.sizingOptions = []
        window.contentView = host

        window.center()
        window.setFrameAutosaveName("StockmoteSettings")

        Preferences.shared.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.appearance = Preferences.shared.appearance }
            .store(in: &cancellables)
        Preferences.shared.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.title = tr("Indstillinger", "Settings") }
            .store(in: &cancellables)

        self.window = window
        return window
    }
}

/// The settings tab, filling the Settings window.
struct SettingsWindowContent: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ThemeProvider {
            SettingsTab()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .id(prefs.language)
    }
}
