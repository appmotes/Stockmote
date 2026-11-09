import AppKit
import StockmoteShared
import SwiftUI

/// How the overview shows the indices and lists.
enum OverviewMode: String, CaseIterable {
    /// Each card with a small map of its stocks.
    case maps
    /// One row per index and list, one column per range, coloured as the map.
    case table
    /// Each card as its difference to a chosen index over the range.
    case relative

    var symbol: String {
        switch self {
        case .maps: return "square.grid.2x2"
        case .table: return "tablecells"
        case .relative: return "plusminus"
        }
    }

    var help: String {
        switch self {
        case .maps: return tr("Kort (⌘L skifter)", "Maps (⌘L switches)")
        case .table: return tr("Tabel: hvert tidsrum (⌘L skifter)", "Table: every range (⌘L switches)")
        case .relative: return tr("Mod indeks (⌘L skifter)", "Against an index (⌘L switches)")
        }
    }

    var next: OverviewMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension OverviewKind {
    @MainActor var name: String {
        switch self {
        case .index(let id): return UniverseStore.shared.index(withID: id)?.title ?? id
        case .watchlist(let id): return ListsStore.shared.watchlist(id)?.name ?? ""
        }
    }

    /// The card's own figure: the index's, or the list's average.
    @MainActor func figure(_ period: Period) -> Figure {
        let market = MarketStore.shared
        switch self {
        case .index(let id):
            guard let index = UniverseStore.shared.index(withID: id) else { return Figure(period: period) }
            return market.indexFigure(index, period)
        case .watchlist(let id):
            return market.listFigure(ListsStore.shared.watchlist(id)?.items ?? [], period)
        }
    }

    @MainActor func open() {
        switch self {
        case .watchlist(let id): AppState.shared.openWatchlist(id)
        case .index(let id): AppState.shared.openIndex(id)
        }
    }
}

// MARK: - Daily lines

/// One card's course over the range in closes by date: the change in percent
/// from the close the range is measured from (the base of the card's figure).
struct OverviewLine {
    let times: [Int]
    let values: [Double?]
    var isAverage = false
}

/// The overview's lines for "Mod indeks", from the same Yahoo series as the
/// seismograph: an index's own series, and for a list the equal-weight
/// average of its items' series. Always in closes by date — a day, a week or
/// a month — so a European and a US close on the same date are one moment:
/// within the day the two markets share only two hours. 1D has no line.
@MainActor
final class DailyLinesStore: ObservableObject {
    static let shared = DailyLinesStore()

    @Published private(set) var lines: [OverviewKind: OverviewLine] = [:]
    /// The range the lines are for; while another is loading, the cards say so.
    @Published private(set) var loadedPeriod: Period?
    @Published private(set) var isLoading = false

    private var loadedKey = ""
    private var loadedAt: Date?
    private var task: Task<Void, Never>?

    func line(_ kind: OverviewKind) -> OverviewLine? {
        loadedPeriod == MarketStore.shared.period ? lines[kind] : nil
    }

    /// Fetches the series for every card, unless they are already in and
    /// less than two minutes old.
    func load(force: Bool = false) {
        let period = MarketStore.shared.period
        guard period != .day else {
            task?.cancel()
            task = nil
            lines = [:]
            loadedPeriod = .day
            isLoading = false
            return
        }
        let indices = UniverseStore.shared.indices.filter { !$0.isFund }
        let lists = ListsStore.shared.watchlists
        let listSymbols = lists.flatMap { $0.items.compactMap(MarketStore.quoteSymbol) }
        let symbols = Array(Set(indices.map(\.benchmark) + listSymbols)).sorted()
        let key = "\(period.rawValue)|\(symbols.joined(separator: ","))|\(lists.map { "\($0.id)" }.joined())"
        if !force, key == loadedKey, let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        if !force, key == loadedKey, task != nil { return }
        loadedKey = key
        task?.cancel()
        isLoading = true
        task = Task { [weak self] in
            // A week in daily closes; longer ranges in the replay's days, weeks or months.
            let fetched = await Yahoo.fetchSeries(symbols, period: period, interval: period == .week ? "1d" : nil)
            guard !Task.isCancelled, let self else { return }
            let series = fetched.mapValues(Raw.init)
            var lines: [OverviewKind: OverviewLine] = [:]
            for index in indices {
                if let s = series[index.benchmark] { lines[.index(index.id)] = Self.line(s) }
            }
            for list in lists {
                let members = list.items.compactMap { MarketStore.quoteSymbol($0).flatMap { series[$0] } }
                if let line = Self.average(members) { lines[.watchlist(list.id)] = line }
            }
            self.lines = lines
            self.loadedPeriod = period
            self.loadedAt = Date()
            self.isLoading = false
            self.task = nil
        }
    }

    /// Snapshot mode: waits until the lines are in.
    func waitForLoad() async {
        load(force: true)
        await task?.value
    }

    /// A series' closes by date, and the close they are measured from.
    private struct Raw {
        var timestamps: [Int] = []
        var closes: [Double?] = []
        let previousClose: Double

        /// Each close is stamped at the start of its date, the latest of a
        /// date kept. The date is UTC's two hours on, so a NAV stamped at
        /// midnight in Copenhagen (22.00 or 23.00 UTC) falls on its own day,
        /// as do Europe's and the US sessions.
        init(_ s: Yahoo.Series) {
            previousClose = s.previousClose
            for (time, close) in zip(s.timestamps, s.closes) {
                let shifted = time + 7_200
                let stamp = shifted - ((shifted % 86_400) + 86_400) % 86_400
                if stamp == timestamps.last {
                    if close != nil { closes[closes.count - 1] = close }
                } else {
                    timestamps.append(stamp)
                    closes.append(close)
                }
            }
        }
    }

    private static func line(_ s: Raw) -> OverviewLine {
        OverviewLine(times: s.timestamps, values: s.closes.map { $0.map { ($0 / s.previousClose - 1) * 100 } })
    }

    /// The members' changes, each at its latest close on every date (its
    /// previous close before it has traded — a change of 0, as in the
    /// seismograph), averaged with equal weight.
    private static func average(_ members: [Raw]) -> OverviewLine? {
        guard !members.isEmpty else { return nil }
        let stamps = Array(Set(members.flatMap(\.timestamps))).sorted()
        guard !stamps.isEmpty else { return nil }
        var sums = [Double](repeating: 0, count: stamps.count)
        for s in members {
            var pointer = 0
            var last: Double?
            for (i, t) in stamps.enumerated() {
                while pointer < s.timestamps.count, s.timestamps[pointer] <= t {
                    if let close = s.closes[pointer] { last = close }
                    pointer += 1
                }
                sums[i] += ((last ?? s.previousClose) / s.previousClose - 1) * 100
            }
        }
        return OverviewLine(times: stamps, values: sums.map { $0 / Double(members.count) }, isAverage: true)
    }

    /// A line minus the benchmark's, in percentage points, on every date
    /// either has a close: each holds its latest close between its own, and
    /// both start at 0 at the close the range is measured from.
    static func difference(_ line: OverviewLine, _ benchmark: OverviewLine) -> [Double] {
        let times = Array(Set(line.times + benchmark.times)).sorted()
        func held(_ l: OverviewLine) -> [Double] {
            var pointer = 0
            var last = 0.0
            return times.map { t in
                while pointer < l.times.count, l.times[pointer] <= t {
                    if let value = l.values[pointer] { last = value }
                    pointer += 1
                }
                return last
            }
        }
        let a = held(line), b = held(benchmark)
        return [0] + zip(a, b).map { $0 - $1 }
    }
}

// MARK: - Against an index

/// "Mod indeks": the card's figure minus the chosen index's, in percentage
/// points — both read from their own prices over the same range.
enum Relative {
    @MainActor static var benchmark: MarketIndex? {
        let universe = UniverseStore.shared
        return universe.index(withID: Preferences.shared.benchmarkID)
            ?? universe.index(withID: "sp500") ?? universe.indices.first
    }

    /// The difference in percentage points, or nil without both figures.
    @MainActor static func difference(_ kind: OverviewKind, _ period: Period) -> Double? {
        guard let benchmark, let own = kind.figure(period).change,
              let theirs = MarketStore.shared.indexFigure(benchmark, period).change else { return nil }
        return own - theirs
    }

    /// "+2,7" — Format.percent's sign and decimal comma, without its "%".
    static func number(_ value: Double?) -> String {
        guard let value else { return "–" }
        let text = Format.percent(value, digits: 1)
        return String(text.dropLast(text.hasSuffix("%") ? 1 : 0))
    }

    /// Percentage points.
    static var unit: String { tr("%-point", "pp") }
}

/// A card's line against the chosen index: above 0 the card did better since
/// the range began, below it worse. One neutral line, the area green or red.
struct RelativeChart: View {
    let kind: OverviewKind

    @ObservedObject private var store = DailyLinesStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme

    var body: some View {
        let benchmark = Relative.benchmark
        if market.period == .day {
            note(tr("Linjen tegnes fra 1U: én dag har kun dagens kurs.", "The line is drawn from 1W: a day has only today's price."))
        } else if case .index(let id) = kind, id == benchmark?.id {
            note(tr("Det indeks, de andre måles mod", "The index the others are measured against"))
        } else if let line = store.line(kind), let benchmark, let base = store.line(.index(benchmark.id)) {
            chart(DailyLinesStore.difference(line, base))
        } else {
            note(store.isLoading || store.loadedPeriod != market.period ? tr("Henter forløb …", "Loading history …")
                 : tr("Intet forløb fra Yahoo", "No history from Yahoo"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.raised.opacity(0.5))
    }

    private func chart(_ values: [Double]) -> some View {
        let up = Heat.textColor(1, style: prefs.colorStyle, theme: theme)
        let down = Heat.textColor(-1, style: prefs.colorStyle, theme: theme)
        return Canvas { context, size in
            guard values.count > 1 else { return }
            let low = min(values.min() ?? 0, 0), high = max(values.max() ?? 0, 0)
            let pad = max((high - low) * 0.1, 0.2)
            let top = high + pad, bottom = low - pad
            let y: (Double) -> CGFloat = { CGFloat((top - $0) / (top - bottom)) * size.height }
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(values.count - 1) * size.width }
            var line = Path()
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: x(i), y: y(value))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: y(0)))
            area.addLine(to: CGPoint(x: 0, y: y(0)))
            area.closeSubpath()
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: y(0))))
                layer.fill(area, with: .color(up.opacity(0.28)))
            }
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: 0, y: y(0), width: size.width, height: size.height - y(0))))
                layer.fill(area, with: .color(down.opacity(0.28)))
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            context.stroke(line, with: .color(.primary.opacity(0.75)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
        .padding(.vertical, 4)
    }
}

/// Above the cards in "Mod indeks": which index they are measured against.
struct BenchmarkBar: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("Hvert kort mod", "Each card against"))
                .foregroundStyle(.secondary)
            Picker("", selection: $prefs.benchmarkID) {
                ForEach(universe.indices.filter { !$0.isFund }) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            if let benchmark = Relative.benchmark {
                Text(tr("\(Format.percent(market.indexFigure(benchmark, market.period).change)) over \(market.period.longName.lowercased())",
                        "\(Format.percent(market.indexFigure(benchmark, market.period).change)) over \(market.period.longName.lowercased())"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(tr("Forskel i procentpoint · over 0 = bedre end indekset · hver i sin egen valuta",
                    "Difference in percentage points · above 0 = better than the index · each in its own currency"))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.top, 4)
    }
}

// MARK: - The table

/// "Tabel": every index and list as a row, every range as a column, each
/// cell its own figure coloured as on the map. A click on a range sorts by
/// it (best first); another click puts the rows back in their sections. A
/// click on a row opens it.
struct OverviewTable: View {
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme
    @State private var sortBy: Period?

    private let nameWidth: CGFloat = 200

    private var sections: [(title: String, kinds: [OverviewKind])] {
        [(tr("Mine", "Mine"), lists.watchlists.map { .watchlist($0.id) }),
         (tr("USA", "United States"), universe.indices.filter { !$0.isEuropean && !$0.isFund }.map { .index($0.id) }),
         (tr("Europa", "Europe"), universe.indices.filter { $0.isEuropean && !$0.isFund }.map { .index($0.id) })]
    }

    var body: some View {
        let _ = market.version
        VStack(alignment: .leading, spacing: 3) {
            header
            if let sortBy {
                let kinds = sections.flatMap(\.kinds).sorted {
                    ($0.figure(sortBy).change ?? -.infinity) > ($1.figure(sortBy).change ?? -.infinity)
                }
                ForEach(kinds, id: \.self) { TableRow(kind: $0, nameWidth: nameWidth, sortBy: sortBy) }
            } else {
                ForEach(sections, id: \.title) { section in
                    if !section.kinds.isEmpty {
                        Text(section.title.uppercased())
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                            .padding(.leading, 2)
                        ForEach(section.kinds, id: \.self) { TableRow(kind: $0, nameWidth: nameWidth, sortBy: nil) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Text(sortBy == nil ? "" : tr("Sorteret efter \(sortBy!.label) · klik igen for afsnit", "Sorted by \(sortBy!.label) · click again for sections"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            ForEach(Period.allCases) { period in
                Button { sortBy = sortBy == period ? nil : period } label: {
                    HStack(spacing: 2) {
                        Text(period.label)
                        if sortBy == period { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                    }
                    .font(.system(size: 11.5, weight: period == market.period || sortBy == period ? .bold : .medium))
                    .foregroundStyle(period == market.period || sortBy == period ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Sortér efter \(period.longName.lowercased()), bedst først", "Sort by \(period.longName.lowercased()), best first"))
            }
        }
        .padding(.horizontal, 6)
    }
}

/// One row of the table: the name, then one cell per range.
private struct TableRow: View {
    let kind: OverviewKind
    let nameWidth: CGFloat
    let sortBy: Period?

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 6) {
                if case .watchlist = kind {
                    Text(tr("LISTE", "LIST"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.raised))
                        .fixedSize()
                }
                Text(kind.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if case .watchlist = kind {
                    Text(tr("gns.", "avg."))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: nameWidth, alignment: .leading)
            ForEach(Period.allCases) { period in
                cell(kind.figure(period), period: period)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Palette.raised.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { kind.open() }
        .help(tr("Åbn \(kind.name)", "Open \(kind.name)"))
    }

    private func cell(_ figure: Figure, period: Period) -> some View {
        let change = figure.change
        let fill = change == nil ? Palette.raised.opacity(0.5)
            : Heat.color(change, scale: period.colorScale, style: prefs.colorStyle, theme: theme)
        let ink = change == nil ? Color.secondary
            : Heat.label(on: change, scale: period.colorScale, style: prefs.colorStyle, theme: theme)
        return Text(change == nil ? "–" : (figure.isIndicative ? "≈ " : "") + Format.percent(change, digits: 1))
            .font(.system(size: 11.5, weight: period == market.period || period == sortBy ? .bold : .semibold).monospacedDigit())
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill))
            .overlay {
                if period == market.period {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                }
            }
            .help(figure.help)
    }
}
