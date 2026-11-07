import AppIntents
import StockmoteShared
import SwiftUI
import WidgetKit

@main
struct StockmoteWidgets: WidgetBundle {
    init() {
        // Sproget skal være sat før widget'ens navn og beskrivelse læses.
        Lang.isEnglish = WidgetShare.read()?.english ?? false
    }

    var body: some Widget {
        StockmoteWidget()
    }
}

struct StockmoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "StockmoteHeatmap", intent: HeatmapIntent.self, provider: Provider()) { entry in
            // Appens temavalg (Som systemet / Lyst / Mørkt) gælder også her.
            HeatmapWidgetView(entry: entry)
                .themed(entry.themeMode)
                .containerBackground(for: .widget) { WidgetBackground().themed(entry.themeMode) }
        }
        .configurationDisplayName("Stockmote")
        .description(tr("Heatmap over dine favoritter, en watchliste, et indeks eller en sektor.",
                        "Heatmap of your favorites, a watchlist, an index or a sector."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Konfiguration

enum WidgetSource: String, AppEnum {
    case favorites, watchlist, index

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Indhold"
    static var caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .favorites: "Favoritter",
        .watchlist: "Watchliste",
        .index: "Indeks eller sektor"
    ]
}

/// Et indeks fra appen. Listen læses fra den delte fil, så nye indekser
/// (fx når update-indices.sh har tilføjet et) dukker op af sig selv.
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
    case day, week, month, quarter, ytd, year

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tidsrum"
    static var caseDisplayRepresentations: [PeriodChoice: DisplayRepresentation] = [
        .day: "1 dag", .week: "1 uge", .month: "1 måned",
        .quarter: "3 måneder", .ytd: "År til dato", .year: "1 år"
    ]

    var period: Period {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .ytd: return .ytd
        case .year: return .year
        }
    }
}

/// En watchliste fra appen. Listen læses fra den delte fil, så den følger med
/// når man laver nye i Stockmote.
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

    @Parameter(title: "Indhold", default: .favorites)
    var source: WidgetSource

    @Parameter(title: "Watchliste")
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
            When(\.$source, .equalTo, .watchlist) {
                Summary("\(\.$source)") {
                    \.$watchlist
                    \.$period
                }
            } otherwise: {
                Summary("\(\.$source)") {
                    \.$period
                }
            }
        }
    }
}

// MARK: - Data

struct Entry: TimelineEntry {
    let date: Date
    let title: String
    let change: Double?
    let period: Period
    let style: ColorStyle
    let items: [HeatItem]
    let grouping: Grouping
    let link: URL
    let message: String?
    var marketOpen = false
    var themeMode: ThemeMode = .system

    static var placeholder: Entry { Entry(
        date: Date(), title: "Favoritter", change: 0.42, period: .day, style: .redGreen,
        items: ["AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META"].enumerated().map { index, symbol in
            HeatItem(symbol: symbol, name: symbol, sector: "", industry: "",
                     weight: 1, change: Double(index % 3) - 1, isFavorite: true)
        },
        grouping: .flat, link: URL(string: "stockmote://open?tab=favorites")!, message: nil,
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
        // Hvert kvarter mens børsen er åben, ellers hver time. WidgetKit
        // bestemmer selv det endelige tidspunkt ud fra sit budget.
        let next = Date().addingTimeInterval(entry.marketOpen ? 15 * 60 : 60 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// Hvor mange felter der er plads til at læse.
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
        let favorites = Set(share?.favorites ?? [])

        var symbols: [String]
        var title: String
        var benchmark: String?
        var grouping = Grouping.flat
        var link = "stockmote://open"
        var hours: MarketHours?
        var message: String?

        switch config.source {
        case .favorites:
            title = tr("Favoritter", "Favorites")
            symbols = share?.favorites ?? ["AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META"]
            link += "?tab=favorites"
            if symbols.isEmpty { message = tr("Ingen favoritter endnu", "No favorites yet") }
        case .watchlist:
            let name = config.watchlist?.id
            let list = share?.watchlists.first { $0.name == name } ?? share?.watchlists.first
            title = list?.name ?? tr("Watchliste", "Watchlist")
            symbols = list?.symbols ?? []
            link += "?tab=watchlists"
            if list == nil { message = tr("Lav en watchliste i Stockmote", "Make a watchlist in Stockmote") }
        case .index:
            let indexID = config.index?.id ?? share?.indexList?.first?.id ?? "sp500"
            let meta = share?.indexList?.first { $0.id == indexID }
            let members = share?.indices[indexID] ?? []
            let industry = config.industry?.trimmingCharacters(in: .whitespaces).lowercased()
            symbols = members.filter { symbol in
                guard let stock = share?.stocks[symbol] else { return false }
                if config.sector != .all, stock.sector != config.sector.rawValue { return false }
                if let industry, !industry.isEmpty, !stock.industry.lowercased().contains(industry) { return false }
                return true
            }
            if let industry = config.industry, !industry.isEmpty {
                title = industry
            } else if config.sector != .all {
                title = config.sector.rawValue
            } else {
                title = meta.map { "\($0.flag ?? "") \($0.name)" } ?? indexID
                benchmark = meta?.benchmark
                if family == .systemLarge || family == .systemExtraLarge { grouping = .sectors }
            }
            link += "?tab=map&index=\(indexID)"
            hours = meta?.hours
            if share == nil { message = tr("Åbn Stockmote én gang", "Open Stockmote once") }
            else if symbols.isEmpty { message = tr("Ingen aktier matcher", "No stocks match") }
        }

        // De største selskaber først, så det er dem der kommer med. En fond
        // har sine egne vægte; et indeks bruger markedsværdien.
        let fundWeights = config.source == .index ? share?.weights?[config.index?.id ?? share?.indexList?.first?.id ?? ""] : nil
        let cap: (String) -> Double = { fundWeights?[$0] ?? share?.stocks[$0]?.cap ?? 0 }
        if config.source == .index {
            symbols = Array(symbols.sorted { cap($0) > cap($1) }.prefix(limit(for: family)))
        } else {
            symbols = Array(symbols.prefix(limit(for: family)))
        }

        let values = await Yahoo.fetch(symbols + (benchmark.map { [$0] } ?? []), period: period, concurrency: 3)
        if values.isEmpty, !symbols.isEmpty, message == nil { message = tr("Ingen forbindelse til Yahoo", "No connection to Yahoo") }

        let byCap = config.source == .index
        let items = symbols.map { symbol -> HeatItem in
            let stock = share?.stocks[symbol]
            return HeatItem(
                symbol: symbol, name: stock?.name ?? symbol,
                sector: stock?.sector ?? tr("Øvrige", "Other"), industry: stock?.industry ?? tr("Øvrige", "Other"),
                weight: byCap ? (fundWeights?[symbol] ?? max(stock?.cap ?? 1, 1)) : 1,
                change: values[symbol]?.change,
                isFavorite: favorites.contains(symbol) && config.source != .favorites
            )
        }

        let change: Double?
        if let benchmark {
            change = values[benchmark]?.change
        } else {
            // Gennemsnit — vægtet hvis felterne er det.
            let known = items.filter { $0.change != nil }
            let weight = known.reduce(0) { $0 + $1.weight }
            change = weight > 0 ? known.reduce(0) { $0 + $1.change! * $1.weight } / weight : nil
        }

        return Entry(date: Date(), title: title, change: change, period: period, style: style,
                     items: items, grouping: grouping, link: URL(string: link)!, message: message,
                     marketOpen: (hours ?? .newYork).isOpen() || MarketHours.newYork.isOpen(),
                     themeMode: ThemeMode(rawValue: share?.theme ?? "") ?? .system)
    }
}

// MARK: - Visning

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

/// Sort i mørk tilstand, næsten hvid i lys — samme fuger som i panelet.
private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Theme.dark : Theme.light).gap
    }
}

/// Tvinger lyst eller mørkt, når appen er sat til det; ellers følger widget'en
/// systemet. Alt nedenunder — tekst, kortets tema, baggrund — læser
/// colorScheme og følger derfor med.
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
