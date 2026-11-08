import AppKit
import StockmoteShared
import SwiftUI

/// The start screen: every market and list as a card with its own change
/// and a small map of its stocks. A click opens the map.
///
/// "Mine" holds the user's lists; then the US and the European indices.
/// Each card's figure is the same as the map's title: the index's own
/// change, or a list's average (marked as such). The small map colours each
/// stock — or a list's fund or index — by its own change; one without a
/// figure is grey.
struct OverviewView: View {
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var market = MarketStore.shared

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TradingHoursBand()
                    .padding(.bottom, 6)

                section(tr("Mine", "Mine"))
                if lists.watchlists.isEmpty {
                    Text(tr("Ingen lister endnu. Søg med ⌘K og tilføj aktier, fonde eller indeks med “+ Liste”.",
                            "No lists yet. Search with ⌘K and add stocks, funds or indices with “+ List”."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(lists.watchlists) { OverviewCard(kind: .watchlist($0.id)) }
                    }
                }

                section(tr("USA", "United States"))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(universe.indices.filter { !$0.isEuropean }) { OverviewCard(kind: .index($0.id)) }
                }

                section(tr("Europa", "Europe"))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(universe.indices.filter(\.isEuropean)) { OverviewCard(kind: .index($0.id)) }
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.leading, 2)
    }
}

/// What a card shows.
enum OverviewKind: Hashable {
    case watchlist(UUID)
    case index(String)
}

private struct OverviewCard: View {
    let kind: OverviewKind

    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    private var index: MarketIndex? {
        if case .index(let id) = kind { return universe.index(withID: id) }
        return nil
    }

    private var list: Watchlist? {
        if case .watchlist(let id) = kind { return lists.watchlist(id) }
        return nil
    }

    private var title: String {
        switch kind {
        case .watchlist: return list?.name ?? ""
        case .index: return index?.title ?? ""
        }
    }

    private var figure: Figure {
        if let index { return market.indexFigure(index, market.period) }
        return market.listFigure(list?.items ?? [], market.period)
    }

    /// The small map's tiles: an index's largest stocks by market value; a
    /// list's items, all the same size, each with its own change.
    private var tiles: [MiniTile] {
        if let index {
            return index.symbols.map { MiniTile(size: index.weights?[$0] ?? market.marketCap($0) ?? 0,
                                                change: market.change($0, market.period)) }
        }
        return (list?.items ?? []).map { MiniTile(size: 1, change: market.itemFigure($0, market.period).change) }
    }

    var body: some View {
        let figure = figure
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if case .watchlist = kind {
                    Text(tr("LISTE", "LIST"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.raised))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let kindLabel = figure.kindLabel, figure.change != nil {
                    // "gns." / "avg." — a list's figure is an average, not a price.
                    Text(figure.isIndicative ? "≈" : tr("gns.", "avg."))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .help(kindLabel)
                }
                Text(figure.change == nil ? "–" : Format.percent(figure.change))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(figure.change, style: prefs.colorStyle, theme: theme))
                    .help(figure.help)
            }
            mini
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovering ? Palette.raised : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.outline))
        .overlay(alignment: .topTrailing) {
            if list != nil, isHovering {
                Button { remove() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Palette.surface))
                        .overlay(Circle().strokeBorder(Palette.outline))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(removeTitle)
                .offset(x: 6, y: -6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { open() }
        .onHover { isHovering = $0 }
        .help(help)
        .contextMenu { menu }
    }

    @ViewBuilder private var mini: some View {
        let tiles = tiles
        if tiles.isEmpty {
            Text(list != nil ? tr("Tom liste", "Empty list") : tr("Henter…", "Loading…"))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.raised.opacity(0.5))
        } else {
            MiniMap(tiles: tiles, period: market.period, version: market.version, style: prefs.colorStyle, theme: theme)
        }
    }

    private var help: String {
        switch kind {
        case .index:
            guard let index else { return "" }
            return tr("\(index.name) · \(index.symbols.count) aktier · \(index.hours.statusText)",
                      "\(index.name) · \(index.symbols.count) stocks · \(index.hours.statusText)")
        case .watchlist:
            let items = list?.items ?? []
            var parts = [tr("\(items.filter { $0.kind == .stock }.count) aktier", "\(items.filter { $0.kind == .stock }.count) stocks")]
            let fundCount = items.filter { $0.kind == .fund }.count
            let indexCount = items.filter { $0.kind == .index }.count
            if fundCount > 0 { parts.append(tr("\(fundCount) fonde", "\(fundCount) funds")) }
            if indexCount > 0 { parts.append(tr("\(indexCount) indeks", "\(indexCount) indices")) }
            parts.append(tr("gennemsnit med lige vægt", "equal-weight average"))
            return parts.joined(separator: " · ")
        }
    }

    private var removeTitle: String { tr("Slet \(title)", "Delete \(title)") }

    private func open() {
        switch kind {
        case .watchlist(let id): app.openWatchlist(id)
        case .index(let id): app.openIndex(id)
        }
    }

    private func remove() {
        if case .watchlist(let id) = kind { app.removeWatchlist(id) }
    }

    @ViewBuilder private var menu: some View {
        Button(tr("Åbn", "Open")) { open() }
        if case .watchlist(let id) = kind {
            Button(tr("Omdøb …", "Rename …")) { app.dialog = .renameWatchlist(id) }
            Divider()
            Button(removeTitle, role: .destructive) { remove() }
        }
    }
}

/// One tile of a card's small map.
private struct MiniTile {
    let size: Double
    let change: Double?
}

/// A card's small map: an index's largest stocks, or a list's items, each
/// coloured by its own change over the range. Drawn in one Canvas.
private struct MiniMap: View {
    let tiles: [MiniTile]
    let period: Period
    /// Redraws when the prices change.
    let version: Int
    let style: ColorStyle
    let theme: Theme

    /// More than this and the tiles are too small to see.
    private let limit = 60

    var body: some View {
        let largest = tiles.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(limit)
        Canvas { context, size in
            let rects = TreemapBuilder.squarify(largest.map(\.size), in: CGRect(origin: .zero, size: size))
            for (tile, rect) in zip(largest, rects) {
                let color = Heat.color(tile.change, scale: period.colorScale, style: style, theme: theme)
                context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color))
            }
        }
        .background(theme.isDark ? Color.black : Color.white)
    }
}

/// The opening hours of Europe's and America's exchanges today, in your own
/// time, with a marker for now. Holidays are not known.
private struct TradingHoursBand: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let europe = Self.span(timezone: "Europe/Berlin", open: (9, 0), close: (17, 30), on: now)
            let usa = Self.span(timezone: "America/New_York", open: (9, 30), close: (16, 0), on: now)
            let weekend = Calendar.current.isDateInWeekend(now)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(tr("Handelstider i dag, din tid", "Trading hours today, your time"))
                        .foregroundStyle(.secondary)
                    if weekend {
                        Text(tr("Lukket i weekenden", "Closed for the weekend")).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    legend(tr("Europa", "Europe"), europe, .blue)
                    legend(tr("USA", "USA"), usa, .purple)
                }
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)

                GeometryReader { geometry in
                    let width = geometry.size.width
                    let x: (Double) -> CGFloat = { CGFloat($0 / 24) * width }
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Palette.separator).frame(height: 1).offset(y: 10)
                        bar(europe, color: .blue, x: x, y: 2)
                        bar(usa, color: .purple, x: x, y: 12)
                        ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                            Text("\(hour)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .position(x: min(max(x(Double(hour)), 6), width - 6), y: 28)
                        }
                        Rectangle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 2, height: 22)
                            .offset(x: x(Self.hours(now, in: .current)) - 1)
                    }
                    .opacity(weekend ? 0.5 : 1)
                }
                .frame(height: 34)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.outline))
        }
    }

    private func bar(_ span: (Double, Double), color: Color, x: (Double) -> CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.75))
            .frame(width: max(x(span.1) - x(span.0), 2), height: 8)
            .offset(x: x(span.0), y: y)
    }

    private func legend(_ name: String, _ span: (Double, Double), _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
            Text("\(name) \(Self.clock(span.0))–\(Self.clock(span.1))").monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    /// An exchange's hours today, as hours since your own midnight.
    static func span(timezone: String, open: (Int, Int), close: (Int, Int), on date: Date) -> (Double, Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = open.0
        parts.minute = open.1
        let start = calendar.date(from: parts) ?? date
        parts.hour = close.0
        parts.minute = close.1
        let end = calendar.date(from: parts) ?? date
        return (hours(start, in: .current), hours(end, in: .current))
    }

    static func hours(_ date: Date, in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    /// "9.00" in Danish, "9:00" in English.
    static func clock(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return String(format: Lang.isEnglish ? "%d:%02d" : "%d.%02d", total / 60, total % 60)
    }
}
