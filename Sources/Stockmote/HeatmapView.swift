import AppKit
import StockmoteShared
import SwiftUI

/// Selve kortet.
///
/// Felterne tegnes i én `Canvas` i stedet for 500 SwiftUI-views: det er
/// hurtigt, og hover og klik slås op i layoutet med et simpelt rektangel-tjek.
///
/// Zoom bygger layoutet om i den forstørrede størrelse frem for at skalere et
/// billede. Så forbliver teksten skarp, og små felter får deres navn efterhånden
/// som de bliver store nok — ligesom pinch-to-zoom på telefonen.
struct HeatmapView: View {
    let items: [HeatItem]
    let grouping: Grouping
    let focus: Focus
    let period: Period
    let style: ColorStyle
    /// Skifter når data eller lister ændrer sig. Layoutet bygges kun om da.
    let contentKey: Int
    var allowsDrillDown = true
    let onFocus: (Focus) -> Void
    var extraMenu: ((HeatItem) -> AnyView)? = nil

    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme
    @State private var layout: HeatmapLayout = .empty
    @State private var viewport: CGSize = .zero
    @State private var hoverPoint: CGPoint?
    @State private var gestureStart: (zoom: CGFloat, offset: CGPoint)?
    @State private var dragStart: CGPoint?
    @State private var scrollMonitor: Any?

    private struct LayoutKey: Equatable {
        let size: CGSize
        let zoom: CGFloat
        let focus: Focus
        let content: Int
        let period: Period
        let count: Int
    }

    private var key: LayoutKey {
        LayoutKey(size: viewport, zoom: app.zoom, focus: focus, content: contentKey,
                  period: period, count: items.count)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                HeatmapCanvas(layout: layout, offset: app.offset, period: period, style: style, theme: theme)
                    .equatable()

                HoverLayer(
                    layout: layout, offset: app.offset, point: hoverPoint, viewport: geo.size,
                    period: period, style: style, allowsDrillDown: allowsDrillDown
                )
                .allowsHitTesting(false)

                if app.zoom > 1.01 {
                    ZoomControls(zoom: app.zoom,
                                 onZoom: { zoom(by: $0, anchor: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)) },
                                 onReset: { app.resetZoom() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                click(at: point)
            }
            .gesture(magnify)
            .simultaneousGesture(pan)
            .contextMenu { contextMenu }
            .onAppear {
                viewport = geo.size
                rebuild()
                installScrollMonitor()
            }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: geo.size) { _, size in
                viewport = size
                clampOffset()
            }
            .onChange(of: key) { _, _ in rebuild() }
        }
        .clipped()
    }

    // MARK: Layout

    private func rebuild() {
        let size = CGSize(width: viewport.width * app.zoom, height: viewport.height * app.zoom)
        layout = TreemapBuilder.build(items: items, grouping: grouping, focus: focus, size: size)
    }

    private var hovered: Tile? {
        guard let hoverPoint else { return nil }
        return layout.tile(at: hoverPoint + app.offset)
    }

    // MARK: Klik

    private func click(at point: CGPoint) {
        let content = point + app.offset
        if allowsDrillDown, let header = layout.header(at: content) {
            onFocus(header.focus)
        } else if let tile = layout.tile(at: content) {
            Preferences.shared.openQuote(tile.item.symbol)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let tile = hovered {
            StockMenu(item: tile.item, showDrillDown: allowsDrillDown && grouping == .sectors, onFocus: onFocus)
            if let extraMenu {
                Divider()
                extraMenu(tile.item)
            }
        } else if let point = hoverPoint, allowsDrillDown, let header = layout.header(at: point + app.offset) {
            Button(tr("Vis \(header.name)", "Show \(header.name)")) { onFocus(header.focus) }
        }
    }

    // MARK: Zoom og panorering

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = gestureStart ?? (app.zoom, app.offset)
                if gestureStart == nil { gestureStart = start }
                setZoom(start.zoom * value.magnification, anchor: value.startLocation,
                        from: start.zoom, offset: start.offset)
            }
            .onEnded { _ in gestureStart = nil }
    }

    /// Træk med musen flytter rundt når der er zoomet ind.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard app.zoom > 1.01 else { return }
                let start = dragStart ?? app.offset
                if dragStart == nil { dragStart = start }
                app.offset = clamped(CGPoint(x: start.x - value.translation.width,
                                             y: start.y - value.translation.height), zoom: app.zoom)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint) {
        setZoom(app.zoom * factor, anchor: anchor, from: app.zoom, offset: app.offset)
    }

    /// Zoomer om `anchor`, så det punkt man peger på bliver stående.
    private func setZoom(_ target: CGFloat, anchor: CGPoint, from zoom: CGFloat, offset: CGPoint) {
        let newZoom = min(max(target, 1), 12)
        let content = CGPoint(x: (anchor.x + offset.x) / zoom, y: (anchor.y + offset.y) / zoom)
        let newOffset = CGPoint(x: content.x * newZoom - anchor.x, y: content.y * newZoom - anchor.y)
        app.zoom = newZoom
        app.offset = clamped(newOffset, zoom: newZoom)
    }

    private func clamped(_ offset: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: min(max(offset.x, 0), viewport.width * (zoom - 1)),
                y: min(max(offset.y, 0), viewport.height * (zoom - 1)))
    }

    private func clampOffset() {
        app.offset = clamped(app.offset, zoom: app.zoom)
    }

    /// To-finger-scroll på trackpad (og musehjul) panorerer når der er zoomet
    /// ind; ⌘-scroll zoomer. SwiftUI har ingen scroll-hændelse udenfor en
    /// ScrollView, så vi lytter lokalt og reagerer kun mens musen er over kortet.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let point = hoverPoint else { return event }
            if event.modifierFlags.contains(.command) {
                let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
                zoom(by: max(0.5, min(factor, 1.5)), anchor: point)
                return nil
            }
            guard app.zoom > 1.01 else { return event }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            app.offset = clamped(CGPoint(x: app.offset.x - event.scrollingDeltaX * scale,
                                         y: app.offset.y - event.scrollingDeltaY * scale), zoom: app.zoom)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

// MARK: - Hover

private struct HoverLayer: View {
    @Environment(\.heatTheme) private var theme
    let layout: HeatmapLayout
    let offset: CGPoint
    let point: CGPoint?
    let viewport: CGSize
    let period: Period
    let style: ColorStyle
    let allowsDrillDown: Bool

    var body: some View {
        if let point {
            let content = point + offset
            if allowsDrillDown, let header = layout.header(at: content), let rect = header.header {
                let local = rect.offsetBy(dx: -offset.x, dy: -offset.y)
                Rectangle()
                    .fill(theme.highlight.opacity(0.14))
                    .frame(width: local.width, height: local.height)
                    .offset(x: local.minX, y: local.minY)
                Tooltip(point: point, viewport: viewport, height: 64) {
                    GroupTooltip(box: header, period: period, style: style)
                }
            } else if let tile = layout.tile(at: content) {
                let local = tile.rect.offsetBy(dx: -offset.x, dy: -offset.y)
                Rectangle()
                    .strokeBorder(theme.highlight, lineWidth: 1.5)
                    .frame(width: local.width, height: local.height)
                    .offset(x: local.minX, y: local.minY)
                Tooltip(point: point, viewport: viewport, height: 150) {
                    StockTooltip(item: tile.item, period: period, style: style)
                }
            }
        }
    }
}

/// Lægger en tooltip ved musen og vender den, så den bliver på kortet.
private struct Tooltip<Content: View>: View {
    let point: CGPoint
    let viewport: CGSize
    let height: CGFloat
    @ViewBuilder let content: Content

    private let width: CGFloat = 250

    var body: some View {
        let x = point.x + 18 + width > viewport.width ? point.x - 14 - width : point.x + 18
        let y = min(max(point.y + 18, 4), max(viewport.height - height - 4, 4))
        content
            .frame(width: width, alignment: .leading)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surface.opacity(0.98))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Palette.outline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            }
            .fixedSize()
            .offset(x: max(x, 4), y: y)
    }
}

struct StockTooltip: View {
    @Environment(\.heatTheme) private var theme
    @ObservedObject private var replay = ReplayStore.shared
    let item: HeatItem
    let period: Period
    let style: ColorStyle

    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        let dayChange = market.change(item.symbol, .day)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Symbols.display(item.symbol)).font(.system(size: 16, weight: .bold))
                if item.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                }
                Spacer(minLength: 8)
                Text(Format.percent(item.change))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(item.change, style: style, theme: theme))
            }
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text("\(item.sector) › \(item.industry)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Divider().padding(.vertical, 2)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row(replay.isReady ? tr("Kurs \(replay.timeLabel())", "Price \(replay.timeLabel())") : tr("Kurs", "Price"),
                    Format.price(replay.price(item.symbol) ?? market.price(item.symbol), currency: market.currency(item.symbol)))
                if let weight = FundStore.shared.weight(of: item.symbol, inIndex: AppState.shared.indexID),
                   AppState.shared.tab == .map {
                    row(tr("Vægt i fonden", "Weight in fund"), Format.weight(weight))
                }
                row(tr("Markedsværdi", "Market value"), Format.marketCap(market.marketCap(item.symbol)))
                if period != .day {
                    GridRow {
                        Text(Period.day.longName).foregroundStyle(.secondary)
                        Text(Format.percent(dayChange))
                            .foregroundStyle(Heat.textColor(dayChange, style: style, theme: theme))
                    }
                }
                GridRow {
                    Text(period.longName).foregroundStyle(.secondary)
                    Text(Format.percent(item.change))
                        .foregroundStyle(Heat.textColor(item.change, style: style, theme: theme))
                }
            }
            .font(.system(size: 11).monospacedDigit())

            Text(tr("Klik for at åbne · højreklik for mere", "Click to open · right-click for more"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct GroupTooltip: View {
    @Environment(\.heatTheme) private var theme
    let box: HeatGroup
    let period: Period
    let style: ColorStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(box.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(Format.percent(box.change))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(box.change, style: style, theme: theme))
            }
            Text(tr("Vægtet efter markedsværdi · \(period.longName) · klik for at åbne", "Weighted by market value · \(period.longName) · click to open"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ZoomControls: View {
    let zoom: CGFloat
    let onZoom: (CGFloat) -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("minus", help: tr("Zoom ud", "Zoom out")) { onZoom(1 / 1.5) }
            Button(action: onReset) {
                Text(String(format: "%.1f×", zoom).replacingOccurrences(of: ".", with: Lang.isEnglish ? "." : ","))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 44, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Nulstil zoom (Esc)", "Reset zoom (Esc)"))
            button("plus", help: tr("Zoom ind", "Zoom in")) { onZoom(1.5) }
        }
        .padding(3)
        .background(Capsule().fill(Palette.surface.opacity(0.96)))
        .overlay(Capsule().strokeBorder(Palette.outline))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Højreklik

/// Menuen på en aktie — bruges både på kortet og i listen.
struct StockMenu: View {
    let item: HeatItem
    var showDrillDown = true
    var onFocus: (Focus) -> Void = { _ in }

    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    private var shown: String { Symbols.display(item.symbol) }

    var body: some View {
        Button(tr("Åbn \(shown) på \(prefs.quoteSite.label)", "Open \(shown) on \(prefs.quoteSite.label)")) {
            prefs.openQuote(item.symbol)
        }
        Button(lists.isFavorite(item.symbol) ? tr("Fjern \(shown) fra favoritter", "Remove \(shown) from favorites") : tr("Føj \(shown) til favoritter", "Add \(shown) to favorites")) {
            lists.toggleFavorite(item.symbol)
        }
        Menu(tr("Watchlister", "Watchlists")) {
            ForEach(lists.watchlists) { list in
                Toggle(list.name, isOn: Binding(
                    get: { lists.contains(item.symbol, in: list.id) },
                    set: { _ in lists.toggle(item.symbol, in: list.id) }
                ))
            }
            if !lists.watchlists.isEmpty { Divider() }
            Button(tr("Ny watchliste med \(shown)", "New watchlist with \(shown)")) {
                let id = lists.createWatchlist(with: [item.symbol])
                AppState.shared.watchlistID = id
            }
        }
        if showDrillDown {
            Divider()
            // Står man allerede i branchen eller sektoren, fører punktet
            // tilbage til hele indekset i stedet.
            let industry = Focus.industry(sector: item.sector, industry: item.industry)
            let sector = Focus.sector(item.sector)
            if app.focus == industry || app.focus == sector {
                Button(tr("Tilbage til hele indekset", "Back to the whole index")) { onFocus(.all) }
            }
            if app.focus != industry {
                Button(tr("Vis branchen \(item.industry)", "Show industry \(item.industry)")) { onFocus(industry) }
            }
            if app.focus != sector {
                Button(tr("Vis sektoren \(item.sector)", "Show sector \(item.sector)")) { onFocus(sector) }
            }
        }
        Divider()
        Button(tr("Kopiér \(shown)", "Copy \(shown)")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.symbol, forType: .string)
        }
    }
}
