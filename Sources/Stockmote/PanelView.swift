import AppKit
import StockmoteShared
import SwiftUI

/// The map's theme, based on the appearance the window has been given.
struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var heatTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Reads light/dark from the environment and passes it on as `heatTheme`.
struct ThemeProvider<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.heatTheme, scheme == .dark ? .dark : .light)
    }
}


/// The main window's content: the toolbar row, the screen — the overview,
/// a map or a stock — and the status line.
///
/// No sidebar: the overview is the start screen, and every level has a way
/// back (the chevron, the breadcrumb and Esc). It fills the window and runs
/// up under the transparent title bar.
struct PanelRoot: View {
    /// A fixed size, for snapshots of the window; otherwise the window's.
    var size: CGSize? = nil
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var replay = ReplayStore.shared

    var body: some View {
        ThemeProvider {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Toolbar()
                        .frame(minWidth: 0, maxWidth: .infinity)
                    Rectangle().fill(Palette.separator).frame(height: 1)
                    Content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if replay.isActive, app.isMap {
                        SeismographDrawer(maxRows: geometry.size.height < 620 ? 6 : 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    StatusLine()
                }
                .background(Palette.background)
                .overlay(alignment: .bottom) { ToastView().padding(.bottom, 34) }
                .overlay { DialogHost() }
            }
        }
        .frame(width: size?.width, height: size?.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        // In the window the content runs under the title bar; the toolbar row
        // makes room for the traffic lights itself.
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: replay.isActive)
        .animation(.easeOut(duration: 0.15), value: app.dialog)
        .animation(.easeOut(duration: 0.2), value: app.toast?.id)
        .modifier(ReplayReloader())
        .background { KeyboardShortcuts() }
        // When the language changes, everything is rebuilt so every text is read again.
        .id(prefs.language)
    }
}

private struct Content: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        switch app.screen {
        case .overview:
            OverviewView()
        case .stock(let symbol):
            StockPage(symbol: symbol)
        case .map:
            switch app.tab {
            case .map: MapContent()
            case .watchlists: WatchlistContent()
            }
        }
    }
}

/// The message at the bottom of the window: "SPY was removed · Undo".
private struct ToastView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if let toast = app.toast {
            HStack(spacing: 12) {
                // A longer message (why a fund has no map) wraps in a narrow window.
                Text(toast.text).font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let undo = toast.undo {
                    Button(tr("Fortryd", "Undo")) {
                        undo()
                        app.toast = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.outline))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var chrome = WindowChrome.shared

    /// The row starts at the window's edge, under the traffic lights —
    /// except in full screen, where they are gone.
    private var leadingInset: CGFloat {
        chrome.isFullScreen ? 0 : max(0, chrome.trafficLightsInset - 12)
    }

    var body: some View {
        HStack(spacing: 8) {
            if app.screen != .overview {
                Button { app.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Et niveau op (Esc)", "Up one level (Esc)"))
            }
            // The title gives way first: it is truncated with … rather than
            // pushing the controls out of a narrow window.
            // Below the overview the breadcrumb needs room too, so the picker
            // turns into a menu a little sooner there.
            TitleBlock()
                .frame(minWidth: app.screen == .overview ? 170 : 260, maxWidth: .infinity, alignment: .leading)
            // If there is no room for the whole period picker, it becomes a menu.
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            .layoutPriority(1)
        }
        .padding(.leading, leadingInset)
        .padding(.horizontal, 12)
        .frame(height: chrome.titlebarHeight)
        // This row is the title bar: empty space drags the window.
        .background { WindowDragArea() }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact { PeriodMenu() } else { PeriodPicker() }
            if app.isMap {
                SeismographButton()
                ViewModePicker()
            }
            if app.screen == .overview { TradingHoursButton() }
            SearchButton(compact: compact)
            ThemeToggleButton()
            RefreshButton()
            SettingsButton()
        }
        .fixedSize()
    }
}

/// "Søg ⌘K": the one search for indices, stocks and funds.
private struct SearchButton: View {
    let compact: Bool
    @ObservedObject private var app = AppState.shared
    @State private var isHovering = false

    var body: some View {
        Button { app.dialog = .search } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .semibold))
                if !compact {
                    Text(tr("Søg", "Search")).font(.system(size: 11.5, weight: .medium))
                    Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 0 : 9)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.hover : Palette.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Søg aktie, indeks eller fond (⌘K)", "Search for a stock, index or fund (⌘K)"))
        .onHover { isHovering = $0 }
    }
}

/// The seismograph on and off (⌘P): one row per sector, industry or stock
/// under the map, coloured step by step through the range.
private struct SeismographButton: View {
    @ObservedObject private var replay = ReplayStore.shared
    @State private var isHovering = false

    var body: some View {
        Button { replay.toggle() } label: {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(replay.isActive ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(replay.isActive ? Color.accentColor.opacity(0.18) : (isHovering ? Palette.raised : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Seismograf (⌘P) · mellemrum afspiller", "Seismograph (⌘P) · space plays"))
        .onHover { isHovering = $0 }
    }
}

/// The overview's trading-hours band on and off. Highlighted when on.
private struct TradingHoursButton: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var isHovering = false

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { prefs.showTradingHours.toggle() } } label: {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prefs.showTradingHours ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prefs.showTradingHours ? Color.accentColor.opacity(0.18) : (isHovering ? Palette.raised : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Handelstider", "Trading hours"))
        .onHover { isHovering = $0 }
    }
}

/// The source the map shows, for titles and breadcrumbs.
@MainActor
enum Source {
    static var title: String {
        let app = AppState.shared
        switch app.tab {
        case .map: return UniverseStore.shared.index(withID: app.indexID)?.title ?? ""
        case .watchlists: return ListsStore.shared.watchlist(app.watchlistID)?.name ?? tr("Watchliste", "Watchlist")
        }
    }

    /// The source as a breadcrumb step: a fund by its ticker ("VWCE"),
    /// since its full name is long.
    static var crumb: String {
        let app = AppState.shared
        if app.tab == .map, let symbol = FundStore.symbol(fromID: app.indexID),
           let fund = FundStore.shared.fund(symbol) {
            return fund.displaySymbol
        }
        return title
    }

    /// The current index or fund, when the source is one.
    static var index: MarketIndex? {
        let app = AppState.shared
        return app.tab == .map ? UniverseStore.shared.index(withID: app.indexID) : nil
    }
}

/// One step of the breadcrumb: its label and where a click takes you.
private struct Crumb: Identifiable {
    let id = UUID()
    let label: String
    let action: () -> Void
}

/// The title: the breadcrumb on top ("Overblik › S&P 500 › Information
/// Technology"), then what you are looking at with its change.
private struct TitleBlock: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let crumbs = crumbs
            if !crumbs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { position, crumb in
                        if position > 0 { Text("›").foregroundStyle(.tertiary) }
                        Button(action: crumb.action) {
                            Text(crumb.label).lineLimit(1).truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        // "Overblik" and the nearest level keep their full names;
                        // the levels in between are shortened first.
                        .layoutPriority(position == 0 || position == crumbs.count - 1 ? 1 : 0)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .help(crumbs.map(\.label).joined(separator: " › "))
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Lets a drag on the title move the window, as on a real title bar.
                    .allowsHitTesting(false)
                    .layoutPriority(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                if app.screen != .overview {
                    let figure = figure
                    Text(figure.text)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Heat.textColor(figure.change, style: prefs.colorStyle, theme: theme))
                        .help(figure.help)
                        .fixedSize()
                    // What kind of number it is, when it isn't read straight
                    // from a price: "indicative" or "average".
                    if let kind = figure.kindLabel, figure.change != nil {
                        Text(kind).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).help(figure.help)
                    }
                    Group {
                        if replay.isReady, app.isMap {
                            // With the seismograph on, the moment shown.
                            Text("▶ \(replay.timeLabel())")
                        } else {
                            Text(figure.rangeLabel)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            .lineLimit(1)
        }
    }

    private var title: String {
        switch app.screen {
        case .overview: return tr("Overblik", "Overview")
        case .stock(let symbol): return Symbols.display(symbol)
        case .map: return app.focus.title ?? Source.title
        }
    }

    private var subtitle: String? {
        if case .stock(let symbol) = app.screen { return market.info(symbol).name }
        if app.screen == .overview { return market.period.longName }
        return nil
    }

    private var crumbs: [Crumb] {
        var crumbs: [Crumb] = []
        guard app.screen != .overview else { return crumbs }
        crumbs.append(Crumb(label: tr("Overblik", "Overview")) { app.showOverview() })
        // A fund or index opened from a list: the list comes first.
        if let list = app.parentList {
            crumbs.append(Crumb(label: list.name) { app.openWatchlist(list.id) })
        }
        let source = Source.crumb
        let toMap: (Focus) -> Void = { focus in
            app.focus = focus
            app.screen = .map
        }
        switch app.screen {
        case .map:
            if app.focus != .all { crumbs.append(Crumb(label: source) { toMap(.all) }) }
            if case .industry(let sector, _) = app.focus { crumbs.append(Crumb(label: sector) { toMap(.sector(sector)) }) }
        case .stock(let symbol):
            guard app.stockReturn.screen == .map else { break }
            crumbs.append(Crumb(label: source) { toMap(.all) })
            // In an index or fund: the stock's sector and industry there.
            if let index = Source.index, index.symbols.contains(symbol) {
                let info = market.info(symbol)
                crumbs.append(Crumb(label: info.sector) { toMap(.sector(info.sector)) })
                crumbs.append(Crumb(label: info.industry) { toMap(.industry(sector: info.sector, industry: info.industry)) })
            }
        case .overview:
            break
        }
        return crumbs
    }

    private var figure: Figure {
        let period = market.period
        if case .stock(let symbol) = app.screen {
            return Figure(change: market.change(symbol, period), since: market.since(symbol, period), period: period)
        }
        if replay.isReady, app.tab != .map || app.focus == .all {
            return Figure(change: replay.curveValue, isIndicative: replay.curveIsIndicative,
                          isAverage: replay.curveIsAverage, period: period)
        }
        switch app.tab {
        case .map:
            guard let index = Source.index else { return Figure(period: period) }
            guard app.focus != .all else { return market.indexFigure(index, period) }
            // The sector's or industry's own change, weighted by market cap.
            let items = Items.make(index.symbols, weights: index.weights).filter { $0.matches(app.focus) }
            return Figure(change: Items.weightedChange(items), isAverage: true, isWeighted: true, period: period)
        case .watchlists: return market.viewFigure(period)
        }
    }
}

extension HeatItem {
    /// In the sector or industry `focus`.
    func matches(_ focus: Focus) -> Bool {
        switch focus {
        case .all: return true
        case .sector(let s): return sector == s
        case .industry(let s, let i): return sector == s && industry == i
        }
    }
}

/// The period picker as a menu, when the window is too narrow for the whole row.
private struct PeriodMenu: View {
    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        Menu {
            ForEach(Period.allCases) { period in
                let figure = market.viewFigure(period)
                Toggle("\(period.label)  ·  \(period.longName)  ·  \(figure.text)", isOn: Binding(
                    get: { market.period == period },
                    set: { _ in market.period = period }
                ))
            }
        } label: {
            HStack(spacing: 5) {
                Text(market.period.label).font(.system(size: 11.5, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(market.period.longName)
    }
}

/// 1D · 1U · 1M · 3M · 6M · ÅTD · 1Å · 3Å · 5Å · Alt as a segmented control,
/// where the selection slides over to the chosen one. Under each range, the
/// view's own change over it (the index, the fund, the list's average) —
/// "–" until it is loaded or where there is no price that far back.
private struct PeriodPicker: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { period in
                let isSelected = market.period == period
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { market.period = period }
                } label: {
                    let figure = market.viewFigure(period)
                    VStack(spacing: 0) {
                        Text(period.label)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        // The overview has no one figure per range.
                        if app.screen != .overview {
                            Text(figure.change == nil ? "–" : (figure.isIndicative ? "≈" : "") + Format.shortPercent(figure.change))
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Heat.textColor(figure.change, style: prefs.colorStyle, theme: theme))
                        }
                    }
                        .frame(minWidth: 30)
                        .padding(.horizontal, 3)
                        .frame(height: app.screen == .overview ? 26 : 34)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "period", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(market.viewFigure(period).help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        .fixedSize()
    }
}

private struct ViewModePicker: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            segment("square.grid.2x2", selected: !app.showList, help: tr("Kort (⌘L)", "Map (⌘L)")) { app.showList = false }
            segment("list.bullet", selected: app.showList, help: tr("Liste (⌘L)", "List (⌘L)")) { app.showList = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        .fixedSize()
    }

    private func segment(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 28, height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.surface)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RefreshButton: View {
    @ObservedObject private var market = MarketStore.shared
    @State private var spin = false

    var body: some View {
        ToolbarButton(symbol: "arrow.clockwise", help: tr("Opdatér (⌘R)", "Refresh (⌘R)")) {
            Task { await market.refresh() }
        }
        .rotationEffect(.degrees(spin ? 360 : 0))
        .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
        .onChange(of: market.isLoading || market.loadingPeriod != nil) { _, loading in spin = loading }
        .onAppear { spin = market.isLoading }
    }
}

/// Opens the Settings window. Its icon is two sliders, drawn here because
/// SF Symbols only has the three-slider version.
private struct SettingsButton: View {
    @State private var isHovering = false

    var body: some View {
        Button { SettingsWindow.shared.show() } label: {
            SlidersIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tr("Indstillinger (⌘,)", "Settings (⌘,)"))
        .onHover { isHovering = $0 }
    }
}

/// Two horizontal sliders, each a line with a round knob (on a 24-point grid).
private struct SlidersIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (from, to) in [((4, 7), (13, 7)), ((17, 7), (20, 7)), ((4, 17), (7, 17)), ((11, 17), (20, 17))] {
            path.move(to: p(CGFloat(from.0), CGFloat(from.1)))
            path.addLine(to: p(CGFloat(to.0), CGFloat(to.1)))
        }
        path.addEllipse(in: CGRect(origin: p(13, 5), size: CGSize(width: 4 * s, height: 4 * s)))
        path.addEllipse(in: CGRect(origin: p(7, 15), size: CGSize(width: 4 * s, height: 4 * s)))
        return path
    }
}

struct ToolbarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Status bar

private struct StatusLine: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared

    /// For a fund: where the holdings come from, and whether they are truncated.
    private var fundNote: String? {
        guard app.isMap, app.tab == .map, let symbol = FundStore.symbol(fromID: app.indexID) else { return nil }
        return funds.progress[symbol] ?? funds.sourceNote(symbol)
    }

    /// For the long ranges: that Alt measures each stock from its own first
    /// price, and how many stocks have no price for the whole range (listed
    /// later) — they are grey, not measured over a shorter span.
    private var periodNote: String? {
        let period = market.period
        guard period != .day, market.loadingPeriod != period, market.snapshots[period] != nil else { return nil }
        var parts: [String] = []
        if period == .all {
            parts.append(tr("Hver aktie regnes fra sin egen første kurs", "Each stock counts from its own first price"))
        } else {
            let missing = Items.current().items.filter { $0.change == nil }.count
            if missing > 0 {
                parts.append(tr("\(missing) uden kurs for hele perioden", "\(missing) without a price for the whole range"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let hours = MarketClock.current
            HStack(spacing: 6) {
                Circle()
                    .fill(hours.isOpen() ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(hours.statusText)
                Text("·").foregroundStyle(.tertiary)
                Text(tr("Opdateret \(Format.time(market.lastUpdated))", "Updated \(Format.time(market.lastUpdated))"))
                if let period = market.loadingPeriod, period != .day {
                    ProgressView().controlSize(.mini)
                    Text(tr("Henter \(period.longName)…", "Loading \(period.longName)…"))
                }
                if let periodNote, market.errorMessage == nil {
                    Text("·").foregroundStyle(.tertiary)
                    Text(periodNote).lineLimit(1).truncationMode(.tail).help(periodNote)
                        .layoutPriority(-1)
                }
                if let fundNote, market.errorMessage == nil {
                    Text("·").foregroundStyle(.tertiary)
                    Text(fundNote).lineLimit(1).truncationMode(.tail).help(fundNote)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if let error = market.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 22)
        }
    }
}

/// Invisible buttons that carry the keyboard shortcuts the main menu lacks.
private struct KeyboardShortcuts: View {
    var body: some View {
        ZStack {
            // ⌘1 … ⌘9: the indices in the overview's order.
            ForEach(1..<10) { number in
                Button("") {
                    let indices = UniverseStore.shared.indices
                    guard number <= indices.count else { return }
                    AppState.shared.selectIndex(indices[number - 1].id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

// MARK: - Content

/// Shared: map or list of some stocks.
struct StocksView: View {
    let items: [HeatItem]
    let grouping: Grouping
    let contentKey: Int
    var allowsDrillDown = true
    var extraMenu: ((HeatItem) -> AnyView)? = nil
    /// A fund's weights: the list shows them instead of market cap.
    var weights: [String: Double]? = nil

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if market.quotes.isEmpty && market.snapshots.isEmpty {
            LoadingView()
        } else if app.showList {
            StockList(items: items, period: market.period, style: prefs.colorStyle,
                      showDrillDown: allowsDrillDown, extraMenu: extraMenu, weights: weights)
        } else {
            HeatmapView(
                items: items, grouping: grouping, focus: allowsDrillDown ? app.focus : .all,
                period: market.period, style: prefs.colorStyle, contentKey: contentKey,
                allowsDrillDown: allowsDrillDown,
                onFocus: { app.focus = $0; app.tab = .map },
                extraMenu: extraMenu
            )
        }
    }
}

private struct LoadingView: View {
    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        VStack(spacing: 10) {
            if let error = market.errorMessage, !market.isLoading {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(tr("Prøv igen", "Try again")) { Task { await market.refresh() } }
            } else {
                ProgressView()
                Text(tr("Henter kurser…", "Loading quotes…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Builds the map's tiles from symbols.
@MainActor
enum Items {
    /// `weights`: a fund's weights. Then a tile's size is the stock's share of
    /// the fund and not its market cap.
    static func make(_ symbols: [String], byMarketCap: Bool = true, weights: [String: Double]? = nil) -> [HeatItem] {
        let market = MarketStore.shared
        let replay = ReplayStore.shared
        let size: (String) -> Double? = { symbol in weights.map { $0[symbol] } ?? market.marketCap(symbol) }
        let caps = symbols.compactMap(size)
        // BF.B and the like have no market cap. They get the smallest tile rather than
        // disappearing.
        let fallback = caps.min() ?? 1
        return symbols.map { symbol in
            let info = market.info(symbol)
            let cap = size(symbol) ?? fallback
            return HeatItem(
                symbol: symbol, name: info.name, sector: info.sector, industry: info.industry,
                weight: byMarketCap ? cap : 1,
                // During replay: the change at the selected time.
                change: replay.isReady ? (replay.change(symbol) ?? 0) : market.change(symbol, market.period)
            )
        }
    }

    /// A list's tiles: one per item, all the same size, each coloured by the
    /// item's own change — the stock's, the fund's own price or NAV, the
    /// index's own figure. Without one the tile is grey with "–".
    static func make(list items: [ListItem]) -> [HeatItem] {
        let market = MarketStore.shared
        let replay = ReplayStore.shared
        let universe = UniverseStore.shared
        return items.map { item in
            let quote = MarketStore.quoteSymbol(item) ?? item.symbol
            let figure = market.itemFigure(item, market.period)
            // During replay: the item's own series at the selected time.
            let change = replay.isReady ? replay.change(quote) : figure.change
            let isEstimate = !replay.isReady && figure.isIndicative
            switch item.kind {
            case .stock:
                let info = market.info(item.symbol)
                return HeatItem(symbol: item.symbol, name: info.name, sector: info.sector, industry: info.industry,
                                weight: 1, change: change)
            case .fund:
                let fund = item.fund
                return HeatItem(symbol: quote, name: fund?.name ?? item.symbol, sector: tr("Fonde", "Funds"),
                                industry: fund?.kindLabel ?? tr("Fond", "Fund"), weight: 1, change: change,
                                label: fund?.displaySymbol, ref: item.key, isEstimate: isEstimate)
            case .index:
                let index = universe.index(withID: item.symbol)
                let region = index.map { $0.isEuropean ? tr("Europa", "Europe") : tr("USA", "United States") } ?? ""
                // The tile says the index's name; the line under it what it is.
                return HeatItem(symbol: quote, name: index.map { tr("Indeks · \($0.symbols.count) aktier", "Index · \($0.symbols.count) stocks") } ?? item.symbol,
                                sector: tr("Indeks", "Indices"), industry: region,
                                weight: 1, change: change, label: index?.name, ref: item.key)
            }
        }
    }

    /// The list item a tile stands for.
    static func listItem(_ item: HeatItem) -> ListItem {
        guard let ref = item.ref else { return .stock(item.symbol) }
        if let symbol = FundStore.symbol(fromID: ref) {
            return FundStore.shared.fund(symbol).map(ListItem.fund) ?? ListItem(kind: .fund, symbol: symbol)
        }
        return .index(String(ref.dropFirst("index:".count)))
    }

    /// The change of a group of stocks, weighted by tile size (market value,
    /// or the fund's weights). Only stocks with a figure count.
    static func weightedChange(_ items: [HeatItem]) -> Double? {
        let known = items.filter { $0.change != nil }
        let weight = known.reduce(0) { $0 + $1.weight }
        return weight > 0 ? known.reduce(0) { $0 + $1.change! * $1.weight } / weight : nil
    }

    static func key(_ parts: AnyHashable...) -> Int {
        var hasher = Hasher()
        hasher.combine(MarketStore.shared.version)
        hasher.combine(MarketStore.shared.period)
        hasher.combine(FundStore.shared.holdings.count)
        let replay = ReplayStore.shared
        hasher.combine(replay.isReady ? replay.frame : -1)
        hasher.combine(replay.timeline.count)
        for part in parts { hasher.combine(part) }
        return hasher.finalize()
    }

    /// What is shown right now — also used by full screen.
    static func current() -> (items: [HeatItem], grouping: Grouping, key: Int, drillDown: Bool) {
        let app = AppState.shared
        let lists = ListsStore.shared
        switch app.tab {
        case .watchlists:
            let list = lists.watchlist(app.watchlistID)
            return (make(list: list?.items ?? []), .flat, key("watchlist", list), false)
        case .map:
            let universe = UniverseStore.shared
            let index = universe.index(withID: app.indexID) ?? universe.indices.first
            return (make(index?.symbols ?? [], weights: index?.weights), .sectors,
                    key(index?.id ?? "", index?.symbols.count ?? 0), true)
        }
    }
}

private struct MapContent: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if let symbol = FundStore.symbol(fromID: app.indexID), funds.holdings[symbol] == nil,
           let fund = funds.fund(symbol) {
            FundStatusView(fund: fund)
        } else if let error = universe.loadError {
            VStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(tr("Genindlæs indekslister", "Reload index lists")) { universe.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let current = Items.current()
            StocksView(
                items: current.items.filter { item in
                    guard app.showList else { return true }
                    switch app.focus {
                    case .all: return true
                    case .sector(let s): return item.sector == s
                    case .industry(let s, let i): return item.sector == s && item.industry == i
                    }
                },
                grouping: .sectors,
                contentKey: current.key,
                weights: universe.index(withID: app.indexID)?.weights
            )
        }
    }
}

/// A fund whose holdings have not been loaded: how far it has got, or
/// why it did not succeed.
private struct FundStatusView: View {
    let fund: Fund
    @ObservedObject private var funds = FundStore.shared

    var body: some View {
        VStack(spacing: 10) {
            if let error = funds.errors[fund.symbol] {
                Image(systemName: "chart.pie").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button(tr("Prøv igen", "Try again")) { funds.load(fund.symbol, force: true) }
                    if let list = AppState.shared.parentList {
                        Button(tr("Tilbage til \(list.name)", "Back to \(list.name)")) { AppState.shared.openWatchlist(list.id) }
                    }
                }
            } else {
                ProgressView()
                Text(funds.progress[fund.symbol] ?? tr("Henter beholdningen…", "Loading holdings…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(fund.name).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if funds.errors[fund.symbol] == nil { funds.load(fund.symbol, force: false) }
        }
    }
}

/// A list's map: one tile per stock, fund or index, all the same size.
private struct WatchlistContent: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            if let list = lists.watchlist(app.watchlistID) ?? lists.watchlists.first {
                if list.items.isEmpty {
                    EmptyListView(text: tr("\(list.name) er tom", "\(list.name) is empty"),
                                  detail: tr("Søg med ⌘K og klik + \(list.name) ved en aktie, en fond eller et indeks.",
                                             "Search with ⌘K and click + \(list.name) beside a stock, a fund or an index."))
                } else {
                    let current = Items.current()
                    StocksView(
                        items: current.items, grouping: .flat, contentKey: current.key, allowsDrillDown: false,
                        extraMenu: { item in
                            AnyView(Button(tr("Fjern \(item.title) fra \(list.name)", "Remove \(item.title) from \(list.name)")) {
                                app.remove(Items.listItem(item), from: list.id)
                            })
                        }
                    )
                }
            } else {
                EmptyListView(text: tr("Ingen lister", "No lists"),
                              detail: tr("Lav en med “+ Ny watchliste” i søgningen (⌘K).", "Make one with “+ New watchlist” in the search (⌘K)."))
            }
        }
        .onAppear {
            if app.watchlistID == nil { app.watchlistID = lists.watchlists.first?.id }
        }
    }
}

private struct EmptyListView: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List

enum SortKey: String, CaseIterable, Identifiable {
    case changeDown, changeUp, marketCap, symbol
    var id: String { rawValue }
    var label: String {
        switch self {
        case .changeDown: return tr("Største stigning", "Biggest gain")
        case .changeUp: return tr("Største fald", "Biggest loss")
        case .marketCap: return tr("Markedsværdi", "Market value")
        case .symbol: return tr("Symbol", "Symbol")
        }
    }
}

struct StockList: View {
    let items: [HeatItem]
    let period: Period
    let style: ColorStyle
    var showDrillDown = true
    var extraMenu: ((HeatItem) -> AnyView)? = nil
    var weights: [String: Double]? = nil

    @ObservedObject private var market = MarketStore.shared
    @AppStorage("listSort", store: AppDefaults.store) private var sort: SortKey = .changeDown

    /// Market cap — or the weight in the fund, when it is a fund.
    private func size(_ symbol: String) -> Double {
        (weights.map { $0[symbol] } ?? market.marketCap(symbol)) ?? 0
    }

    private var sorted: [HeatItem] {
        switch sort {
        case .changeDown: return items.sorted { ($0.change ?? -.infinity) > ($1.change ?? -.infinity) }
        case .changeUp: return items.sorted { ($0.change ?? .infinity) < ($1.change ?? .infinity) }
        case .marketCap: return items.sorted { size($0.symbol) > size($1.symbol) }
        case .symbol: return items.sorted { $0.title < $1.title }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(items.contains { $0.ref != nil }
                     ? tr("\(items.count) værdipapirer", "\(items.count) securities")
                     : tr("\(items.count) aktier", "\(items.count) stocks")).foregroundStyle(.secondary)
                Spacer()
                Picker(tr("Sortér", "Sort"), selection: $sort) {
                    ForEach(SortKey.allCases) { key in
                        Text(key == .marketCap && weights != nil ? tr("Vægt i fonden", "Weight in fund") : key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Text(tr("Symbol", "Symbol")).frame(width: 78, alignment: .leading)
                Text(tr("Navn", "Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(tr("Kurs", "Price")).frame(width: 96, alignment: .trailing)
                Text(weights != nil ? tr("Vægt", "Weight") : tr("Markedsværdi", "Market value"))
                    .frame(width: 100, alignment: .trailing)
                Text(period.label).frame(width: 82, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            Rectangle().fill(Palette.separator).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted, id: \.symbol) { item in
                        StockRow(item: item, price: market.price(item.symbol), currency: market.currency(item.symbol),
                                 marketCap: market.marketCap(item.symbol), weight: weights?[item.symbol],
                                 isFund: weights != nil, period: period, style: style)
                            .contextMenu {
                                StockMenu(item: item, showDrillDown: showDrillDown,
                                          onFocus: { AppState.shared.focus = $0; AppState.shared.showList = false })
                                if let extraMenu {
                                    Divider()
                                    extraMenu(item)
                                }
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct StockRow: View {
    let item: HeatItem
    let price: Double?
    let currency: String
    let marketCap: Double?
    var weight: Double? = nil
    var isFund = false
    let period: Period
    let style: ColorStyle

    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button {
            AppState.shared.open(item)
        } label: {
            HStack(spacing: 10) {
                Text(item.title).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    .frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    Text(item.ref == nil ? item.industry : "\(item.sector) · \(item.industry)")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A fund's or index's price has no currency the app knows of.
                Text(item.ref == nil ? Format.price(price, currency: currency)
                                     : Format.price(price, currency: "").trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 96, alignment: .trailing)
                Text(isFund ? Format.weight(weight) : item.ref == nil ? Format.marketCap(marketCap) : "–")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text(item.percentText)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.label(on: item.change, scale: period.colorScale, style: style, theme: theme))
                    .frame(width: 74, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Heat.color(item.change, scale: period.colorScale, style: style, theme: theme)))
                    .frame(width: 82, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.raised : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Sun/moon in the toolbar: switches between light and dark with one click.
/// The icon shows the theme you'd switch to, like macOS' own Control Centre
/// toggle. If the theme follows the system, the click flips away from what
/// the system shows right now. Right-click to go back to following the system.
private struct ThemeToggleButton: View {
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                prefs.theme = isDark ? .light : .dark
            }
        } label: {
            Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDark ? Color.yellow : Color.indigo)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isDark ? tr("Skift til lyst tema (⇧⌘T)", "Switch to light theme (⇧⌘T)")
                     : tr("Skift til mørkt tema (⇧⌘T)", "Switch to dark theme (⇧⌘T)"))
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(ThemeMode.allCases) { mode in
                Toggle(mode.label, isOn: Binding(get: { prefs.theme == mode }, set: { _ in prefs.theme = mode }))
            }
        }
    }
}
