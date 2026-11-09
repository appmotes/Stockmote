import AppKit
import StockmoteShared
import SwiftUI

// MARK: - The lines

/// One card's course over the range: the change in percent from the price
/// the range is measured from (the same base as the card's figure), at each
/// of Yahoo's timestamps. nil where Yahoo has no close.
struct OverviewLine {
    let times: [Int]
    let values: [Double?]
    /// A list's line is the equal-weight average of its items, not a price.
    var isAverage = false

    var last: Double? { values.last { $0 != nil } ?? nil }
}

extension OverviewKind {
    /// "index:sp500" or "list:<uuid>", as remembered in the preferences.
    var key: String {
        switch self {
        case .index(let id): return "index:\(id)"
        case .watchlist(let id): return "list:\(id.uuidString)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "index": self = .index(parts[1])
        case "list":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .watchlist(id)
        default: return nil
        }
    }

    @MainActor var name: String {
        switch self {
        case .index(let id): return UniverseStore.shared.index(withID: id)?.title ?? id
        case .watchlist(let id): return ListsStore.shared.watchlist(id)?.name ?? ""
        }
    }

    /// Whether the card is still on the overview (a list may be deleted).
    @MainActor var exists: Bool {
        switch self {
        case .index(let id): return UniverseStore.shared.index(withID: id) != nil
        case .watchlist(let id): return ListsStore.shared.watchlist(id) != nil
        }
    }
}

/// The overview's lines, from the same Yahoo series as the seismograph: an
/// index's own series, and for a list the equal-weight average of its
/// stocks', funds' and indices' series. Loaded only while the overview
/// shows lines.
@MainActor
final class OverviewLinesStore: ObservableObject {
    static let shared = OverviewLinesStore()

    @Published private(set) var lines: [OverviewKind: OverviewLine] = [:]
    /// 1U only: the lines in daily closes, for the comparison. Europe and the
    /// US trade at different hours, so within the day their lines would mostly
    /// be held; a close per trading day lines them up.
    @Published private(set) var dailyLines: [OverviewKind: OverviewLine] = [:]
    /// The range the lines are for; while another is loading, the cards say so.
    @Published private(set) var loadedPeriod: Period?
    @Published private(set) var isLoading = false

    private var loadedKey = ""
    private var loadedAt: Date?
    private var task: Task<Void, Never>?

    func line(_ kind: OverviewKind) -> OverviewLine? {
        loadedPeriod == MarketStore.shared.period ? lines[kind] : nil
    }

    /// A card's line in the comparison: 1U in daily closes.
    func compareLine(_ kind: OverviewKind) -> OverviewLine? {
        let period = MarketStore.shared.period
        guard loadedPeriod == period else { return nil }
        return period == .week ? dailyLines[kind] : lines[kind]
    }

    /// Fetches the series for every card, unless they are already in and
    /// less than two minutes old.
    func load(force: Bool = false) {
        let period = MarketStore.shared.period
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
            async let fetched = Yahoo.fetchSeries(symbols, period: period)
            async let daily = period == .week ? Yahoo.fetchSeries(symbols, period: period, interval: "1d") : [:]
            let (intraday, closes) = await (fetched, daily)
            guard !Task.isCancelled, let self else { return }
            // Daily, weekly and monthly closes are stamped at each exchange's
            // own opening time; one date is one moment, so markets line up.
            let byDate = !["5m", "30m"].contains(period.replayInterval)
            self.lines = Self.lines(intraday.mapValues { Raw($0, byDate: byDate) }, indices: indices, lists: lists)
            self.dailyLines = Self.lines(closes.mapValues { Raw($0, byDate: true) }, indices: indices, lists: lists)
            self.loadedPeriod = period
            self.loadedAt = Date()
            self.isLoading = false
            self.task = nil
        }
    }

    private static func lines(_ series: [String: Raw], indices: [MarketIndex], lists: [Watchlist]) -> [OverviewKind: OverviewLine] {
        var lines: [OverviewKind: OverviewLine] = [:]
        for index in indices {
            if let s = series[index.benchmark] { lines[.index(index.id)] = line(s) }
        }
        for list in lists {
            let members = list.items.compactMap { MarketStore.quoteSymbol($0).flatMap { series[$0] } }
            if let line = average(members) { lines[.watchlist(list.id)] = line }
        }
        return lines
    }

    /// Snapshot mode: waits until the lines are in.
    func waitForLoad() async {
        load(force: true)
        await task?.value
    }

    /// A series' closes, and the close they are measured from.
    private struct Raw {
        var timestamps: [Int] = []
        var closes: [Double?] = []
        let previousClose: Double

        /// With `byDate`, each close is stamped at the start of its date, the
        /// latest of a date kept. The date is UTC's two hours on, so a NAV
        /// stamped at midnight in Copenhagen (22.00 or 23.00 UTC) falls on its
        /// own day, as do Europe's and the US sessions.
        init(_ s: Yahoo.Series, byDate: Bool) {
            previousClose = s.previousClose
            for (time, close) in zip(s.timestamps, s.closes) {
                let shifted = time + 7_200
                let stamp = byDate ? shifted - ((shifted % 86_400) + 86_400) % 86_400 : time
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

    /// The members' changes, each at its latest close at every moment (its
    /// previous close before it has traded — a change of 0, as in the
    /// seismograph), averaged with equal weight. At most 400 moments.
    private static func average(_ members: [Raw]) -> OverviewLine? {
        guard !members.isEmpty else { return nil }
        var stamps = Array(Set(members.flatMap(\.timestamps))).sorted()
        guard !stamps.isEmpty else { return nil }
        if stamps.count > 400 {
            let stride = Double(stamps.count - 1) / 399
            stamps = (0..<400).map { stamps[Int((Double($0) * stride).rounded())] }
        }
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
}

// MARK: - Colours

/// The compared lines' colours: none of them green, red, blue or orange,
/// which mean up and down in the app.
enum CompareColors {
    static let all: [Color] = [
        Color(red: 0.62, green: 0.45, blue: 0.98),  // violet
        Color(red: 0.13, green: 0.72, blue: 0.82),  // cyan
        Color(red: 0.90, green: 0.72, blue: 0.20),  // gold
        Color(red: 0.86, green: 0.38, blue: 0.80),  // magenta
        Color(red: 0.70, green: 0.50, blue: 0.32),  // brown
        Color(red: 0.58, green: 0.64, blue: 0.74)   // slate
    ]
    static let limit = all.count

    @MainActor static func color(_ kind: OverviewKind) -> Color? {
        let keys = Preferences.shared.compared.filter { OverviewKind(key: $0)?.exists == true }
        return keys.firstIndex(of: kind.key).map { all[$0 % all.count] }
    }

    /// Adds the card to the comparison, or takes it out. At most six.
    @MainActor static func toggle(_ kind: OverviewKind) {
        let prefs = Preferences.shared
        var keys = prefs.compared.filter { OverviewKind(key: $0)?.exists == true }
        if let i = keys.firstIndex(of: kind.key) {
            keys.remove(at: i)
        } else if keys.count < limit {
            keys.append(kind.key)
        } else {
            NSSound.beep()
            return
        }
        prefs.compared = keys
    }
}

// MARK: - A card's line

/// A card's small chart: the line through the closes, coloured up or down
/// by where it ends, and a dashed line at 0 — the price the range starts from.
struct SparkLine: View {
    let line: OverviewLine
    let style: ColorStyle
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let values = line.values.compactMap { $0 }
            guard values.count > 1 else { return }
            let low = min(values.min() ?? 0, 0), high = max(values.max() ?? 0, 0)
            let pad = max((high - low) * 0.08, 0.05)
            let top = high + pad, bottom = low - pad
            let y: (Double) -> CGFloat = { CGFloat((top - $0) / (top - bottom)) * size.height }
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(max(line.values.count - 1, 1)) * size.width }

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            let color = Heat.textColor(line.last, style: style, theme: theme)
            let path = Self.path(line.values, x: x, y: y)
            var area = Path()
            for run in Self.runs(line.values) {
                guard let first = run.first, let lastIndex = run.last else { continue }
                area.move(to: CGPoint(x: x(first), y: y(0)))
                for i in run { area.addLine(to: CGPoint(x: x(i), y: y(line.values[i] ?? 0))) }
                area.addLine(to: CGPoint(x: x(lastIndex), y: y(0)))
                area.closeSubpath()
            }
            context.fill(area, with: .color(color.opacity(0.12)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .padding(.vertical, 4)
    }

    /// A path through the values that breaks where a value is missing.
    static func path(_ values: [Double?], x: (Int) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        var path = Path()
        for run in runs(values) {
            for (n, i) in run.enumerated() {
                let point = CGPoint(x: x(i), y: y(values[i] ?? 0))
                if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        return path
    }

    /// The stretches of indices without a missing value.
    static func runs(_ values: [Double?]) -> [[Int]] {
        var runs: [[Int]] = [], current: [Int] = []
        for (i, value) in values.enumerated() {
            if value != nil { current.append(i) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

// MARK: - The comparison

/// Above the cards when the overview shows lines: the ticked cards' lines on
/// one axis, all measured in percent from the price their range starts from,
/// each in its own currency. Pointing reads every line at that moment.
///
/// The lines share one timeline: every moment any of them has a close. A
/// line without a close at a moment (its market closed while another
/// trades) holds its latest close there: the line goes on, flat and dashed
/// in a lighter shade — a line drawn through, not traded on. Before its first
/// close it isn't drawn. 1U is compared in daily closes, and every range in
/// days or longer starts at 0 %.
struct CompareChart: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var store = OverviewLinesStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @State private var hovered: Int?

    private struct Track {
        let kind: OverviewKind
        let color: Color
        let line: OverviewLine?
        /// Per moment on the shared timeline: the value, and whether the line
        /// has its own close there.
        var values: [Double?] = []
        var own: [Bool] = []
    }

    private var kinds: [OverviewKind] {
        prefs.compared.compactMap(OverviewKind.init(key:)).filter(\.exists)
    }

    var body: some View {
        let kinds = kinds
        let (times, tracks) = Self.align(fromZero: market.period != .day, kinds.enumerated().map { n, kind in
            Track(kind: kind, color: CompareColors.all[n % CompareColors.all.count], line: store.compareLine(kind))
        })
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                if kinds.isEmpty {
                    Text(tr("Sæt flueben i et kort – eller ⌘-klik det – for at sammenligne det med andre.",
                            "Tick a card – or ⌘-click it – to compare it with others."))
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(tracks, id: \.kind) { chip($0) }
                    }
                }
                Spacer(minLength: 8)
                Text(readout(times))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .font(.system(size: 11, weight: .medium))

            if !kinds.isEmpty {
                chart(times: times, tracks: tracks)
                    .frame(height: 210)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.outline))
    }

    private func readout(_ times: [Int]) -> String {
        if let hovered, times.indices.contains(hovered) {
            if hovered == 0, market.period != .day {
                return tr("Start: hvert markeds lukkekurs før tidsrummet", "Start: each market's close before the range")
            }
            return Self.label(times[hovered], times: times, period: market.period, long: true)
        }
        return tr("0 % = kursen ved periodens start · stiplet = markedet lukket, sidste kurs holdt · i hvert markeds valuta",
                  "0 % = the price at the start of the range · dashed = market closed, last price held · in each market's currency")
    }

    private func chip(_ track: Track) -> some View {
        let value: Double? = {
            guard !track.values.isEmpty else { return nil }
            if let hovered, track.values.indices.contains(hovered) { return track.values[hovered] }
            return track.values.last { $0 != nil } ?? nil
        }()
        return HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(track.color).frame(width: 9, height: 9)
            Text(track.kind.name).lineLimit(1)
            if track.line?.isAverage == true {
                Text(tr("gns.", "avg.")).foregroundStyle(.tertiary)
                    .help(tr("Gennemsnit af listens papirer med lige vægt", "Equal-weight average of the list's securities"))
            }
            Text(track.line == nil ? (store.isLoading ? "…" : "–") : (value.map { Format.percent($0) } ?? "–"))
                .monospacedDigit()
                .foregroundStyle(Heat.textColor(value, style: prefs.colorStyle))
            Button { CompareColors.toggle(track.kind) } label: {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(tr("Fjern fra sammenligningen", "Remove from the comparison"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Palette.raised.opacity(0.6)))
    }

    private func chart(times: [Int], tracks: [Track]) -> some View {
        GeometryReader { geometry in
            let axisWidth: CGFloat = 52, dateHeight: CGFloat = 18
            let plot = CGSize(width: max(geometry.size.width - axisWidth, 10), height: geometry.size.height - dateHeight)
            let all = tracks.flatMap { $0.values.compactMap { $0 } }
            let low = min(all.min() ?? -1, 0), high = max(all.max() ?? 1, 0)
            let pad = max((high - low) * 0.08, 0.1)
            let top = high + pad, bottom = low - pad
            let y: (Double) -> CGFloat = { 8 + CGFloat((top - $0) / (top - bottom)) * (plot.height - 12) }
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(max(times.count - 1, 1)) * plot.width }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let ticks = Self.ticks(bottom, top)
                    let whole = ticks.allSatisfy { $0 == $0.rounded() }
                    for value in ticks {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y(value)))
                        line.addLine(to: CGPoint(x: plot.width, y: y(value)))
                        context.stroke(line, with: .color(value == 0 ? Color.secondary.opacity(0.6) : Palette.separator),
                                       lineWidth: 1)
                        context.draw(Text(Format.percent(value, digits: whole ? 0 : 1)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                                     at: CGPoint(x: plot.width + 6, y: y(value)), anchor: .leading)
                    }
                    for track in tracks {
                        var solid = Path(), held = Path()
                        var previous: CGPoint?
                        for (i, value) in track.values.enumerated() {
                            guard let value else { previous = nil; continue }
                            let point = CGPoint(x: x(i), y: y(value))
                            if let previous {
                                if track.own[i] {
                                    solid.move(to: previous); solid.addLine(to: point)
                                } else {
                                    held.move(to: previous); held.addLine(to: point)
                                }
                            }
                            previous = point
                        }
                        context.stroke(held, with: .color(track.color.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        context.stroke(solid, with: .color(track.color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                    // Every moment when there are few (1U's days), else five.
                    let marks = times.count <= 8 ? Array(times.indices)
                        : [0.0, 0.25, 0.5, 0.75, 1.0].map { Int(($0 * Double(times.count - 1)).rounded()) }
                    for i in marks where times.count > 1 {
                        let anchor: UnitPoint = i == 0 ? .topLeading : (i == times.count - 1 ? .topTrailing : .top)
                        // The shared 0 % moment has no one date: each market's
                        // own close before the range is on its own day.
                        let text = i == 0 && market.period != .day ? tr("Start", "Start")
                            : Self.label(times[i], times: times, period: market.period, long: false)
                        context.draw(Text(text)
                                        .font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: x(i), y: plot.height + 4), anchor: anchor)
                    }
                }
                if let hovered, times.indices.contains(hovered) {
                    Rectangle().fill(Color.primary.opacity(0.35))
                        .frame(width: 1, height: plot.height)
                        .offset(x: x(hovered))
                    ForEach(tracks, id: \.kind) { track in
                        if let value = track.values[safe: hovered] ?? nil {
                            Circle().fill(track.color)
                                .frame(width: 7, height: 7)
                                .position(x: x(hovered), y: y(value))
                        }
                    }
                }
                if times.isEmpty {
                    Text(store.isLoading ? tr("Henter forløb …", "Loading history …")
                                         : tr("Yahoo svarede ikke med forløb.", "Yahoo returned no history."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: plot.width, height: plot.height)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where point.x <= plot.width && times.count > 1:
                    hovered = min(max(Int((point.x / plot.width * CGFloat(times.count - 1)).rounded()), 0), times.count - 1)
                default:
                    hovered = nil
                }
            }
        }
    }

    /// Puts the lines on one timeline: every moment any of them has a value
    /// (at most 500). Each line takes its latest value at or before a moment;
    /// `own` says whether it has one of its own since the moment before.
    ///
    /// With `fromZero` (closes by date) every line starts at 0 % at one
    /// shared moment the day before the first close: the close the range is
    /// measured from, so they all leave from the same point.
    private static func align(fromZero: Bool, _ tracks: [Track]) -> ([Int], [Track]) {
        var times = Array(Set(tracks.flatMap { $0.line?.times ?? [] })).sorted()
        if times.count > 500 {
            let stride = Double(times.count - 1) / 499
            times = (0..<500).map { times[Int((Double($0) * stride).rounded())] }
        }
        let base = fromZero ? times.first.map { $0 - 86_400 } : nil
        if let base { times.insert(base, at: 0) }
        let aligned = tracks.map { track -> Track in
            var track = track
            guard let line = track.line else { return track }
            var values = [Double?](repeating: nil, count: times.count)
            var own = [Bool](repeating: false, count: times.count)
            var pointer = 0
            var last: Double? = base == nil ? nil : 0
            for (i, t) in times.enumerated() {
                var fresh = i == 0 && base != nil
                while pointer < line.times.count, line.times[pointer] <= t {
                    if let value = line.values[pointer] { last = value; fresh = true }
                    pointer += 1
                }
                values[i] = last
                own[i] = fresh
            }
            track.values = values
            track.own = own
            return track
        }
        return (times, aligned)
    }

    /// Round steps for the percent axis, 0 always among them.
    private static func ticks(_ bottom: Double, _ top: Double) -> [Double] {
        let span = top - bottom
        let raw = span / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        var values: [Double] = []
        var value = (bottom / step).rounded(.up) * step
        while value <= top {
            values.append(abs(value) < step / 1000 ? 0 : value)
            value += step
        }
        return values
    }

    /// The stock page's date labels; on 1D with more than one calendar day
    /// on the axis (one market's session yesterday, another's today), with
    /// the weekday as well.
    private static func label(_ time: Int, times: [Int], period: Period, long: Bool) -> String {
        if period == .day, let first = times.first, let last = times.last {
            let calendar = Calendar.current
            let day: (Int) -> Date = { Date(timeIntervalSince1970: TimeInterval($0)) }
            if !calendar.isDate(day(first), inSameDayAs: day(last)) {
                return CandleChart.label(time, period: .week, long: long)
            }
        }
        // 1U is compared in daily closes: dates, not times of day.
        return CandleChart.label(time, period: period == .week ? .month : period, long: long)
    }
}
