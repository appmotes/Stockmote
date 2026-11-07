import AppKit
import StockmoteShared
import SwiftUI

/// The map alone, edge to edge across the whole screen.
///
/// Not macOS's own full screen: that creates a new Space with an animation and
/// expects an ordinary window with a title bar. This is a borderless window
/// the size of the screen, with the menu bar and Dock hidden while it's
/// showing. Hover, click, right-click and zoom work as in the panel.
///
/// Screens with a notch: the top ~32 pt sit behind the camera. The map starts
/// below the notch — otherwise the sector and industry strips would vanish into
/// it — and the band beside the notch shows the title and figure instead of
/// sitting empty.
///
/// Esc: first out of zoom, then out of playback, then up a level, and finally
/// closes full screen. ⌃⌘F closes at once. Space, ← and → control playback,
/// which loops here — a living screen.
@MainActor
final class FullscreenController {
    static let shared = FullscreenController()

    private var window: NSWindow?
    private var monitor: Any?
    private var savedOptions: NSApplication.PresentationOptions = []

    var isShowing: Bool { window != nil }

    func show() {
        guard window == nil else { return }
        MenuBarPanel.current?.hide()
        AppState.shared.resetZoom()

        // The screen the mouse is on — that's where you're looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.setFrame(screen.frame, display: false)

        let host = NSHostingView(rootView: FullscreenView(topInset: screen.safeAreaInsets.top))
        host.appearance = Preferences.shared.appearance
        window.contentView = host
        self.window = window

        // An LSUIElement app must be active to hide the menu bar and Dock — and to
        // receive key presses.
        NSApp.activate(ignoringOtherApps: true)
        savedOptions = NSApp.presentationOptions
        // Auto-hidden, not gone: move the mouse to the top and the menu bar slides
        // in, and a click on the Stockmote icon closes full screen.
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        window.makeKeyAndOrderFront(nil)
        MarketStore.shared.panelVisible = true
        ReplayStore.shared.loops = true
        if ReplayStore.shared.isReady, !ReplayStore.shared.isPlaying { ReplayStore.shared.play() }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil else { return event }
            if ReplayKeys.handle(event) { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 3, flags == [.command, .control] {      // ⌃⌘F
                self.close()
                return nil
            }
            guard event.keyCode == 53 else { return event }               // Esc
            if !AppState.shared.handleEscape() { self.close() }
            return nil
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
        NSApp.presentationOptions = savedOptions
        AppState.shared.resetZoom()
        MarketStore.shared.panelVisible = false
        ReplayStore.shared.loops = false
    }

    func toggle() {
        isShowing ? close() : show()
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}

struct FullscreenView: View {
    /// Height of the notch band. 0 on screens without a notch.
    var topInset: CGFloat = 0

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var replay = ReplayStore.shared
    @State private var showHint = true

    var body: some View {
        ThemeProvider {
            let current = Items.current()
            VStack(spacing: 0) {
                if topInset > 0 {
                    NotchBand()
                        .frame(height: topInset)
                }
                ZStack(alignment: .bottom) {
                    HeatmapView(
                        items: current.items, grouping: current.grouping,
                        focus: current.drillDown ? app.focus : .all,
                        period: market.period, style: prefs.colorStyle, contentKey: current.key,
                        allowsDrillDown: current.drillDown,
                        onFocus: { app.focus = $0 },
                        extraMenu: { _ in
                            AnyView(Group {
                                Button(replay.isActive ? tr("Stop afspilning", "Stop replay")
                                                       : tr("Afspil \(market.period.longName)", "Replay \(market.period.longName)")) {
                                    replay.toggle()
                                }
                                Button(tr("Afslut fuld skærm (⌃⌘F)", "Exit full screen (⌃⌘F)")) {
                                    FullscreenController.shared.close()
                                }
                            })
                        }
                    )
                    // Without a notch there's no band to show the time in, so
                    // playback gets a small pill at the bottom instead.
                    if replay.isActive, topInset == 0 {
                        ReplayPill()
                            .padding(.bottom, 14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    // A discreet hint for the first few seconds, so you know how
                    // to get out again. It goes away by itself.
                    if showHint {
                        Text(tr("Esc for at lukke", "Esc to exit"))
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .padding(.top, 18)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .background(Theme(isDark: true).gap)
        }
        .modifier(ReplayReloader())
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.6)) { showHint = false }
            }
        }
    }
}

/// The band beside the notch: title and change on the left, time range or
/// playback time on the right. Always black — it blends in with the notch.
private struct NotchBand: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var replay = ReplayStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Text(Format.percent(change))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Heat.textColor(change, style: prefs.colorStyle, theme: .dark))
            Spacer(minLength: 0)
            if replay.isReady {
                Image(systemName: replay.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 10))
                Text(replay.timeLabel())
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                ProgressLine(progress: replay.progress)
                    .frame(width: 90, height: 3)
            } else {
                Text(market.period.longName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        switch app.tab {
        case .favorites: return tr("Favoritter", "Favorites")
        case .watchlists: return lists.watchlist(app.watchlistID)?.name ?? ""
        default:
            let index = universe.index(withID: app.indexID)
            let base = index?.title ?? ""
            return app.focus.title.map { "\(base) › \($0)" } ?? base
        }
    }

    private var change: Double? {
        if app.tab == .map, app.focus == .all, let value = replay.curveValue { return value }
        if app.tab == .map, app.focus == .all, let index = universe.index(withID: app.indexID) {
            return market.indexChange(index, market.period)
        }
        let items = Items.current().items.filter { item in
            switch app.focus {
            case .all: return true
            case .sector(let s): return app.tab != .map || item.sector == s
            case .industry(let s, let i): return app.tab != .map || (item.sector == s && item.industry == i)
            }
        }
        let known = items.filter { $0.change != nil }
        let weight = known.reduce(0) { $0 + $1.weight }
        return weight > 0 ? known.reduce(0) { $0 + $1.change! * $1.weight } / weight : nil
    }
}

private struct ReplayPill: View {
    @ObservedObject private var replay = ReplayStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: replay.isPlaying ? "play.fill" : "pause.fill").font(.system(size: 10))
            Text(replay.isReady ? replay.timeLabel() : tr("Henter…", "Loading…"))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
            ProgressLine(progress: replay.progress).frame(width: 120, height: 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.25))
                Capsule().fill(Color.primary).frame(width: geo.size.width * progress)
            }
        }
    }
}
