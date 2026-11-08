import AppIntents
import StockmoteShared
import SwiftUI
import WidgetKit

@main
struct StockmoteWidgets: WidgetBundle {
    init() {
        // The language must be set before the widget's name and description are read.
        Lang.isEnglish = WidgetShare.read()?.english ?? false
    }

    var body: some Widget {
        StockmoteWidget()
    }
}

struct StockmoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "StockmoteHeatmap", intent: HeatmapIntent.self, provider: Provider()) { entry in
            // The app's theme choice (System / Light / Dark) applies here too.
            HeatmapWidgetView(entry: entry)
                .themed(entry.themeMode)
                .containerBackground(for: .widget) { WidgetBackground().themed(entry.themeMode) }
        }
        .configurationDisplayName("Stockmote")
        .description(tr("Heatmap over en af dine lister, et indeks eller en sektor.",
                        "Heatmap of one of your lists, an index or a sector."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Configuration

enum WidgetSource: String, AppEnum {
    case watchlist, index

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Indhold"
    static var caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .watchlist: "Liste",
        .index: "Indeks eller sektor"
    ]
}

/// An index from the app. The list is read from the shared file, so new indices
/// (e.g. once update-indices.sh has added one) show up by themselves.
struct IndexEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Indeks"
    static var defaultQuery = IndexQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct IndexQuery: EntityQuery {
    private func all() -> [IndexEntity] {
        let list = WidgetShare.read()?.indexList ?? []
        if list.isEmpty { return [IndexEntity(id: "sp500", name: "🇺🇸 S&P 500")] }
        return list.map { IndexEntity(id: $0.id, name: "\($0.flag ?? "") \($0.name)") }
    }

    func entities(for identifiers: [String]) async throws -> [IndexEntity] {
        let known = all()
        return identifiers.map { id in known.first { $0.id == id } ?? IndexEntity(id: id, name: id) }
    }

    func suggestedEntities() async throws -> [IndexEntity] { all() }

    func defaultResult() async -> IndexEntity? { all().first }
}

enum SectorChoice: String, AppEnum {
    case all
    case informationTechnology = "Information Technology"
    case communicationServices = "Communication Services"
    case consumerDiscretionary = "Consumer Discretionary"
    case consumerStaples = "Consumer Staples"
    case financials = "Financials"
    case healthCare = "Health Care"
    case industrials = "Industrials"
    case energy = "Energy"
    case utilities = "Utilities"
    case realEstate = "Real Estate"
    case materials = "Materials"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sektor"
    static var caseDisplayRepresentations: [SectorChoice: DisplayRepresentation] = [
        .all: "Alle sektorer",
        .informationTechnology: "Information Technology",
        .communicationServices: "Communication Services",
        .consumerDiscretionary: "Consumer Discretionary",
        .consumerStaples: "Consumer Staples",
        .financials: "Financials",
        .healthCare: "Health Care",
        .industrials: "Industrials",
        .energy: "Energy",
        .utilities: "Utilities",
        .realEstate: "Real Estate",
        .materials: "Materials"
    ]
}

enum PeriodChoice: String, AppEnum {
    case day, week, month, quarter, halfYear, ytd, year, threeYears, fiveYears, all

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tidsrum"
    static var caseDisplayRepresentations: [PeriodChoice: DisplayRepresentation] = [
        .day: "1 dag", .week: "1 uge", .month: "1 måned",
        .quarter: "3 måneder", .halfYear: "6 måneder", .ytd: "År til dato", .year: "1 år",
        .threeYears: "3 år", .fiveYears: "5 år", .all: "Hele historikken"
    ]

    var period: Period {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .halfYear: return .halfYear
        case .ytd: return .ytd
        case .year: return .year
        case .threeYears: return .threeYears
        case .fiveYears: return .fiveYears
        case .all: return .all
        }
    }
}

/// A watchlist from the app. The list is read from the shared file, so it keeps
/// up when you create new ones in Stockmote.
struct WatchlistEntity: AppEntity {
    let id: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Watchliste"
    static var defaultQuery = WatchlistQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct WatchlistQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchlistEntity] {
        identifiers.map(WatchlistEntity.init(id:))
    }

    func suggestedEntities() async throws -> [WatchlistEntity] {
        (WidgetShare.read()?.watchlists ?? []).map { WatchlistEntity(id: $0.name) }
    }

    func defaultResult() async -> WatchlistEntity? {
        try? await suggestedEntities().first
    }
}

struct HeatmapIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Stockmote"
    static var description = IntentDescription("Vælg hvad widget'en viser.")

    @Parameter(title: "Indhold", default: .watchlist)
    var source: WidgetSource

    @Parameter(title: "Liste")
    var watchlist: WatchlistEntity?

    @Parameter(title: "Indeks")
    var index: IndexEntity?

    @Parameter(title: "Sektor", default: .all)
    var sector: SectorChoice

    @Parameter(title: "Branche", description: "Valgfri. Fx Semiconductors eller Diversified Banks.")
    var industry: String?

    @Parameter(title: "Tidsrum", default: .day)
    var period: PeriodChoice

    static var parameterSummary: some ParameterSummary {
        When(\.$source, .equalTo, .index) {
            Summary("\(\.$source)") {
                \.$index
                \.$sector
                \.$industry
                \.$period
            }
        } otherwise: {
            Summary("\(\.$source)") {
                \.$watchlist
                \.$period
            }
        }
    }
}

// MARK: - Data

struct Entry: TimelineEntry {
    let date: Date
    let title: String
    let change: Double?
    /// The change is a list's equal-weight average, marked "gns." / "avg.".
    var isAverage = false
    let period: Period
    let style: ColorStyle
    let items: [HeatItem]
    let grouping: Grouping
    let link: URL
    let message: String?
    var marketOpen = false
    var themeMode: ThemeMode = .system

    static var placeholder: Entry { Entry(
        date: Date(), title: "AI", change: 0.42, isAverage: true, period: .day, style: .redGreen,
        items: ["AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META"].enumerated().map { index, symbol in
            HeatItem(symbol: symbol, name: symbol, sector: "", industry: "",
                     weight: 1, change: Double(index % 3) - 1)
        },
        grouping: .flat, link: URL(string: "stockmote://open?tab=watchlists")!, message: nil,
        themeMode: ThemeMode(rawValue: WidgetShare.read()?.theme ?? "") ?? .system
    ) }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { .placeholder }

    func snapshot(for configuration: HeatmapIntent, in context: Context) async -> Entry {
        context.isPreview ? .placeholder : await load(configuration, family: context.family)
    }

    func timeline(for configuration: HeatmapIntent, in context: Context) async -> Timeline<Entry> {
        let entry = await load(configuration, family: context.family)
        // Every quarter of an hour while the exchange is open, otherwise hourly.
        // WidgetKit decides the actual time itself, based on its budget.
        let next = Date().addingTimeInterval(entry.marketOpen ? 15 * 60 : 60 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// How many tiles there's room to read.
    private func limit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 9
        case .systemMedium: return 24
        case .systemLarge: return 60
        default: return 140
        }
    }

    private func load(_ config: HeatmapIntent, family: WidgetFamily) async -> Entry {
        let share = WidgetShare.read()
        Lang.isEnglish = share?.english ?? false
        let period = config.period.period
        let style = ColorStyle(rawValue: share?.colorStyle ?? "") ?? .redGreen
        let themeMode = ThemeMode(rawValue: share?.theme ?? "") ?? .system

        if config.source == .watchlist {
            return await loadList(config, share: share, period: period, style: style, family: family, themeMode: themeMode)
        }

        let indexID = config.index?.id ?? share?.indexList?.first?.id ?? "sp500"
        let meta = share?.indexList?.first { $0.id == indexID }
        let members = share?.indices[indexID] ?? []
        let industry = config.industry?.trimmingCharacters(in: .whitespaces).lowercased()
        var symbols = members.filter { symbol in
            guard let stock = share?.stocks[symbol] else { return false }
            if config.sector != .all, stock.sector != config.sector.rawValue { return false }
            if let industry, !industry.isEmpty, !stock.industry.lowercased().contains(industry) { return false }
            return true
        }
        let title: String
        var benchmark: String?
        var grouping = Grouping.flat
        if let industry = config.industry, !industry.isEmpty {
            title = industry
        } else if config.sector != .all {
            title = config.sector.rawValue
        } else {
            title = meta.map { "\($0.flag ?? "") \($0.name)" } ?? indexID
            benchmark = meta?.benchmark
            if family == .systemLarge || family == .systemExtraLarge { grouping = .sectors }
        }
        let link = "stockmote://open?tab=map&index=\(indexID)"
        var message: String?
        if share == nil { message = tr("Åbn Stockmote én gang", "Open Stockmote once") }
        else if symbols.isEmpty { message = tr("Ingen aktier matcher", "No stocks match") }

        // Largest companies first, so they're the ones that make the cut. A fund
        // has its own weights; an index uses market cap.
        let fundWeights = share?.weights?[indexID]
        let size: (String) -> Double = { fundWeights?[$0] ?? max(share?.stocks[$0]?.cap ?? 1, 1) }
        // Without the index's own figure (a sector), the headline is the
        // average of all of them, not just the tiles that fit.
        let everyone = symbols
        symbols = Array(symbols.sorted { size($0) > size($1) }.prefix(limit(for: family)))

        let values = await Yahoo.fetch(benchmark.map { symbols + [$0] } ?? everyone, period: period, concurrency: 3)
        if values.isEmpty, !symbols.isEmpty, message == nil { message = tr("Ingen forbindelse til Yahoo", "No connection to Yahoo") }

        let items = symbols.map { symbol -> HeatItem in
            let stock = share?.stocks[symbol]
            return HeatItem(
                symbol: symbol, name: stock?.name ?? symbol,
                sector: stock?.sector ?? tr("Øvrige", "Other"), industry: stock?.industry ?? tr("Øvrige", "Other"),
                weight: size(symbol), change: values[symbol]?.change
            )
        }

        // The index's or fund's own figure, or "–" (a NAV fund's day, before
        // its NAV is out). A sector: the average of all its stocks, weighted
        // by market value (by the fund's weights in a fund).
        let change: Double?
        if let benchmark {
            change = values[benchmark]?.change
        } else {
            let known = everyone.compactMap { symbol in values[symbol].map { ($0.change, size(symbol)) } }
            let weight = known.reduce(0) { $0 + $1.1 }
            change = weight > 0 ? known.reduce(0) { $0 + $1.0 * $1.1 } / weight : nil
        }

        return Entry(date: Date(), title: title, change: change, isAverage: benchmark == nil, period: period, style: style,
                     items: items, grouping: grouping, link: URL(string: link)!, message: message,
                     marketOpen: (meta?.hours ?? .newYork).isOpen() || MarketHours.newYork.isOpen(),
                     themeMode: themeMode)
    }

    /// A list: one tile per stock, fund or index, all the same size, each
    /// coloured by its own change (a fund's own price, an index's own
    /// figure). The headline is the equal-weight average, marked as such.
    private func loadList(_ config: HeatmapIntent, share: WidgetShare?, period: Period, style: ColorStyle,
                          family: WidgetFamily, themeMode: ThemeMode) async -> Entry {
        let name = config.watchlist?.id
        let list = share?.watchlists.first { $0.name == name } ?? share?.watchlists.first
        let title = list?.name ?? tr("Liste", "List")
        // A file from before lists held funds and indices has only stocks.
        let all = list?.items ?? (list?.symbols ?? []).map {
            WidgetShare.Item(kind: "stock", symbol: $0, label: $0, name: share?.stocks[$0]?.name ?? $0)
        }
        let shown = Array(all.prefix(limit(for: family)))
        var link = "stockmote://open?tab=watchlists"
        if let encoded = list?.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { link += "&list=\(encoded)" }
        var message: String?
        if list == nil { message = tr("Lav en liste i Stockmote", "Make a list in Stockmote") }
        else if all.isEmpty { message = tr("\(title) er tom", "\(title) is empty") }

        // A NAV fund has no price for today until the evening: its tile is "–".
        let values = await Yahoo.fetch(Array(Set(all.map(\.symbol))), period: period, concurrency: 3)
        if values.isEmpty, !all.isEmpty, message == nil { message = tr("Ingen forbindelse til Yahoo", "No connection to Yahoo") }

        let items = shown.map { item -> HeatItem in
            let stock = share?.stocks[item.symbol]
            let isStock = item.kind == "stock"
            return HeatItem(
                symbol: item.symbol, name: item.name,
                sector: isStock ? (stock?.sector ?? tr("Øvrige", "Other")) : (item.kind == "fund" ? tr("Fonde", "Funds") : tr("Indeks", "Indices")),
                industry: stock?.industry ?? "", weight: 1, change: values[item.symbol]?.change,
                label: isStock ? nil : item.label, ref: isStock ? nil : "\(item.kind):\(item.symbol)"
            )
        }
        let changes = all.compactMap { values[$0.symbol]?.change }
        let change = changes.isEmpty ? nil : changes.reduce(0, +) / Double(changes.count)

        return Entry(date: Date(), title: title, change: change, isAverage: true, period: period, style: style,
                     items: items, grouping: .flat, link: URL(string: link)!, message: message,
                     marketOpen: MarketHours.newYork.isOpen() || share?.indexList?.contains { $0.hours.isOpen() } == true,
                     themeMode: themeMode)
    }
}

// MARK: - View

struct HeatmapWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: family == .systemSmall ? 11 : 12.5, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.isAverage, entry.change != nil {
                    Text(tr("gns.", "avg."))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(Format.percent(entry.change))
                    .font(.system(size: family == .systemSmall ? 10.5 : 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(entry.change, style: entry.style, theme: scheme == .dark ? .dark : .light))
                Text(entry.period.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: family == .systemSmall ? 24 : 28)

            if let message = entry.message, entry.items.allSatisfy({ $0.change == nil }) {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    HeatmapCanvas(
                        layout: TreemapBuilder.build(items: entry.items, grouping: entry.grouping,
                                                     focus: .all, size: geo.size),
                        period: entry.period, style: entry.style,
                        theme: scheme == .dark ? .dark : .light
                    )
                }
            }
        }
        .widgetURL(entry.link)
    }
}

/// Black in dark mode, near-white in light — the same gaps as in the panel.
private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Theme.dark : Theme.light).gap
    }
}

/// Forces light or dark when the app is set to it; otherwise the widget follows
/// the system. Everything below — text, the map's theme, background — reads
/// colorScheme and so follows along.
private struct ThemedModifier: ViewModifier {
    let mode: ThemeMode
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        switch mode {
        case .system: content
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        }
    }
}

private extension View {
    func themed(_ mode: ThemeMode) -> some View { modifier(ThemedModifier(mode: mode)) }
}
