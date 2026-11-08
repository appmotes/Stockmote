import AppKit
import StockmoteShared
import SwiftUI

/// The start screen: every market and list as a card with its own change
/// and a small map of its stocks. A click opens the map.
///
/// "Mine" holds favourites, watchlists and funds; then the US and the
/// European indices. Each card's figure is the same as the map's title: the
/// index's or fund's own change, or a list's average (marked as such). The
/// small map colours each stock by its own change; one without a figure is
/// grey.
struct OverviewView: View {
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var market = MarketStore.shared

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TradingHoursBand()
                    .padding(.bottom, 6)

                section(tr("Mine", "Mine"))
                LazyVGrid(columns: columns, spacing: 12) {
                    OverviewCard(kind: .favorites)
                    ForEach(lists.watchlists) { OverviewCard(kind: .watchlist($0.id)) }
                    ForEach(funds.funds) { OverviewCard(kind: .fund($0.symbol)) }
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
    case favorites
    case watchlist(UUID)
    case fund(String)
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
        switch kind {
        case .index(let id): return universe.index(withID: id)
        case .fund(let symbol): return funds.fund(symbol).map(funds.index(for:))
        default: return nil
        }
    }

    private var symbols: [String] {
        switch kind {
        case .favorites: return lists.favorites
        case .watchlist(let id): return lists.watchlist(id)?.symbols ?? []
        default: return index?.symbols ?? []
        }
    }

    private var title: String {
        switch kind {
        case .favorites: return tr("Favoritter", "Favorites")
        case .watchlist(let id): return lists.watchlist(id)?.name ?? ""
        case .fund(let symbol): return funds.fund(symbol)?.shortName ?? symbol
        case .index: return index?.title ?? ""
        }
    }

    /// The small label before the title.
    private var badge: String? {
        switch kind {
        case .favorites: return "★"
        case .watchlist: return tr("LISTE", "LIST")
        case .fund(let symbol): return funds.fund(symbol)?.displaySymbol
        case .index: return nil
        }
    }

    private var figure: Figure {
        if let index { return market.indexFigure(index, market.period) }
        return market.listFigure(symbols, market.period)
    }

    private var isRemovable: Bool {
        switch kind {
        case .watchlist, .fund: return true
        default: return false
        }
    }

    var body: some View {
        let figure = figure
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(kind == .favorites ? Color.yellow : .secondary)
                        .padding(.horizontal, kind == .favorites ? 0 : 4)
                        .padding(.vertical, 1)
                        .background {
                            if kind != .favorites {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.raised)
                            }
                        }
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
            if isRemovable, isHovering {
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
        if case .fund(let symbol) = kind, funds.holdings[symbol] == nil {
            VStack(spacing: 5) {
                if let error = funds.errors[symbol] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView().controlSize(.small)
                    Text(funds.progress[symbol] ?? tr("Henter beholdningen…", "Loading holdings…"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.raised.opacity(0.5))
        } else if symbols.isEmpty {
            Text(tr("Tom liste", "Empty list"))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.raised.opacity(0.5))
        } else {
            MiniMap(symbols: symbols, weights: index?.weights, byMarketCap: index != nil || prefs.listsByMarketCap,
                    period: market.period, version: market.version, style: prefs.colorStyle, theme: theme)
        }
    }

    private var help: String {
        switch kind {
        case .index:
            guard let index else { return "" }
            return tr("\(index.name) · \(index.symbols.count) aktier · \(index.hours.statusText)",
                      "\(index.name) · \(index.symbols.count) stocks · \(index.hours.statusText)")
        case .fund(let symbol):
            guard let fund = funds.fund(symbol) else { return "" }
            var lines = ["\(fund.name) · \(fund.displaySymbol) · \(fund.kindLabel)"]
            if let note = funds.sourceNote(symbol) { lines.append(note) }
            return lines.joined(separator: "\n")
        case .favorites, .watchlist:
            return tr("\(symbols.count) aktier · gennemsnit med lige vægt", "\(symbols.count) stocks · equal-weight average")
        }
    }

    private var removeTitle: String {
        switch kind {
        case .fund(let symbol): return tr("Fjern \(funds.fund(symbol)?.displaySymbol ?? symbol)", "Remove \(funds.fund(symbol)?.displaySymbol ?? symbol)")
        case .watchlist: return tr("Slet \(title)", "Delete \(title)")
        default: return ""
        }
    }

    private func open() {
        switch kind {
        case .favorites: app.openFavorites()
        case .watchlist(let id): app.openWatchlist(id)
        case .fund(let symbol): app.openIndex(FundStore.id(symbol))
        case .index(let id): app.openIndex(id)
        }
    }

    private func remove() {
        switch kind {
        case .fund(let symbol): app.removeFund(symbol)
        case .watchlist(let id): app.removeWatchlist(id)
        default: break
        }
    }

    @ViewBuilder private var menu: some View {
        Button(tr("Åbn", "Open")) { open() }
        switch kind {
        case .fund(let symbol):
            Button(tr("Hent beholdningen igen", "Reload holdings")) { funds.load(symbol, force: true) }
            Button(tr("Kopiér symbol", "Copy symbol")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(funds.fund(symbol)?.displaySymbol ?? symbol, forType: .string)
            }
            Divider()
            Button(removeTitle, role: .destructive) { remove() }
        case .watchlist(let id):
            Button(tr("Omdøb …", "Rename …")) { app.dialog = .renameWatchlist(id) }
            Divider()
            Button(removeTitle, role: .destructive) { remove() }
        default:
            EmptyView()
        }
    }
}

/// A card's small map: the largest stocks, each coloured by its own change
/// over the range. Drawn in one Canvas.
private struct MiniMap: View {
    let symbols: [String]
    let weights: [String: Double]?
    let byMarketCap: Bool
    let period: Period
    /// Redraws when the prices change.
    let version: Int
    let style: ColorStyle
    let theme: Theme

    /// More than this and the tiles are too small to see.
    private let limit = 60

    var body: some View {
        let market = MarketStore.shared
        let sized: [(symbol: String, size: Double)] = symbols.map { symbol in
            let size = byMarketCap ? (weights?[symbol] ?? market.marketCap(symbol) ?? 0) : 1
            return (symbol, size)
        }
        let largest = sized.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(limit)
        let changes = largest.map { market.change($0.symbol, period) }
        Canvas { context, size in
            let rects = TreemapBuilder.squarify(largest.map(\.size), in: CGRect(origin: .zero, size: size))
            for (i, rect) in rects.enumerated() where i < changes.count {
                let color = Heat.color(changes[i], scale: period.colorScale, style: style, theme: theme)
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
