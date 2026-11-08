import AppKit
import StockmoteShared
import SwiftUI

/// The engine behind the seismograph (and Map Only's living picture): the
/// map animated through the time range.
///
/// A regular heatmap shows where the day ended. Here you see how it got
/// there — the open, the lunchtime selling, the last hour. With 1D the day
/// plays in 5-minute steps; with 1U in half hours; with 1M, 3M, 6M, ÅTD and
/// 3Å day by day; with 1Å and 5Å week by week; Alt month by month (or by
/// quarter, as Yahoo gives long histories). At most 400 frames.
///
/// The series come from the same Yahoo URL as the quotes, just with
/// `interval` set. Tile sizes stay fixed while it runs; only the colours
/// change, so the map doesn't jump around.
@MainActor
final class ReplayStore: ObservableObject {
    static let shared = ReplayStore()

    @Published private(set) var isActive = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    /// The timestamps being played (Unix seconds).
    @Published private(set) var timeline: [Int] = []
    @Published var frame = 0 {
        didSet { if frame != oldValue { frame = min(max(frame, 0), max(timeline.count - 1, 0)) } }
    }
    /// 1×, 2× or 4×.
    @Published var speed: Double = 1
    @Published private(set) var errorMessage: String?
    /// The index's curve (or the list's average), one value per timestamp.
    @Published private(set) var curve: [Double] = []
    /// The curve is a NAV fund's indicative value from its holdings (1D).
    @Published private(set) var curveIsIndicative = false
    /// The curve is a list's equal-weight average.
    @Published private(set) var curveIsAverage = false

    /// Full screen loops like a living screen; the panel stops at the end.
    var loops = false

    private var changes: [String: [Double]] = [:] {
        didSet { rowCache = nil }
    }
    /// The seismograph's rows for the level on screen, until the data or
    /// the level changes.
    var rowCache: (key: String, rows: [SeismoRow])?
    private var prices: [String: [Double?]] = [:]
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?
    private var player: Task<Void, Never>?
    private var loadedPeriod: Period = .day

    /// A full playthrough takes this long at 1×.
    private let baseDuration: Double = 14

    var isReady: Bool { isActive && !timeline.isEmpty }

    // MARK: Controls

    func toggle() { isActive ? stop() : start() }

    /// Whether the next finished load starts playing. Opening the seismograph
    /// with its button shows it paused on the latest moment; space plays.
    private var playWhenLoaded = false

    func start(playing: Bool = false) {
        playWhenLoaded = playing
        isActive = true
        errorMessage = nil
        reload()
    }

    func stop() {
        pause()
        loadTask?.cancel()
        isActive = false
        isLoading = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard isReady else { return }
        if frame >= timeline.count - 1 { frame = 0 }
        isPlaying = true
        player?.cancel()
        player = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = max(self.timeline.count, 1)
                let step = max(self.baseDuration / self.speed / Double(count), 1.0 / 30)
                try? await Task.sleep(for: .seconds(step))
                guard !Task.isCancelled else { return }
                if self.frame < self.timeline.count - 1 {
                    self.frame += 1
                } else if self.loops {
                    // A moment on the final frame, then from the start.
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    self.frame = 0
                } else {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        player?.cancel()
        player = nil
        isPlaying = false
    }

    func step(_ delta: Int) {
        pause()
        frame += delta
    }

    // MARK: Lookup

    func change(_ symbol: String) -> Double? {
        guard isReady, let series = changes[symbol], frame < series.count else { return nil }
        return series[frame]
    }

    /// A symbol's change at every step, for the seismograph.
    func seriesOf(_ symbol: String) -> [Double]? {
        guard isReady, let series = changes[symbol], series.count == timeline.count else { return nil }
        return series
    }

    func price(_ symbol: String) -> Double? {
        guard isReady, let series = prices[symbol], frame < series.count else { return nil }
        return series[frame]
    }

    var curveValue: Double? {
        guard isReady, frame < curve.count else { return nil }
        return curve[frame]
    }

    var progress: Double {
        timeline.count > 1 ? Double(frame) / Double(timeline.count - 1) : 0
    }

    /// "11.15" for a day, "tor. 14.30" for a week, "3. nov." for longer.
    func timeLabel(_ index: Int? = nil) -> String {
        let i = index ?? frame
        guard i < timeline.count else { return "–" }
        let date = Date(timeIntervalSince1970: TimeInterval(timeline[i]))
        let formatter = DateFormatter()
        formatter.locale = Lang.locale
        switch loadedPeriod {
        case .day: formatter.dateFormat = "HH.mm"
        case .week: formatter.dateFormat = "EEE HH.mm"
        case .year, .threeYears, .fiveYears: formatter.dateFormat = Lang.isEnglish ? "MMM d, yyyy" : "d. MMM yyyy"
        case .all: formatter.dateFormat = Lang.isEnglish ? "MMM yyyy" : "MMM yyyy"
        default: formatter.dateFormat = Lang.isEnglish ? "MMM d" : "d. MMM"
        }
        return formatter.string(from: date)
    }

    // MARK: Fetching

    /// Fetches series for what you're looking at — if it has changed.
    func reload(force: Bool = false) {
        guard isActive else { return }
        let current = Items.current()
        let symbols = current.items.map(\.symbol)
        let app = AppState.shared
        let benchmark = app.tab == .map ? UniverseStore.shared.index(withID: app.indexID)?.benchmark : nil
        let period = MarketStore.shared.period
        let key = "\(period.rawValue)|\(benchmark ?? "-")|\(symbols.joined(separator: ","))"
        guard force || key != loadedKey else { return }
        loadedKey = key

        pause()
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            let wanted = symbols + (benchmark.map { [$0] } ?? [])
            let series = await Yahoo.fetchSeries(wanted, period: period)
            guard !Task.isCancelled, let self else { return }
            self.build(series, symbols: symbols, benchmark: benchmark, period: period)
            self.isLoading = false
            if self.timeline.isEmpty {
                self.errorMessage = tr("Yahoo svarede ikke med forløb.", "Yahoo returned no history.")
            } else if self.playWhenLoaded || self.loops {
                // Space on a closed seismograph, or Map Only's living picture.
                self.playWhenLoaded = false
                self.frame = 0
                self.play()
            } else {
                // Paused on the latest moment, so the map shows what the title says.
                self.frame = self.timeline.count - 1
            }
        }
    }

    /// Puts all series on one shared timeline. A symbol that hasn't traded yet
    /// at a given time (e.g. a US stock before New York opens) sits at its
    /// previous close — a change of 0.
    private func build(_ series: [String: Yahoo.Series], symbols: [String], benchmark: String?, period: Period) {
        loadedPeriod = period
        var stamps = Set<Int>()
        let source = benchmark.flatMap { series[$0] }.map { [$0] } ?? Array(series.values)
        for s in source { stamps.formUnion(s.timestamps) }
        if stamps.isEmpty { for s in series.values { stamps.formUnion(s.timestamps) } }
        var sorted = stamps.sorted()
        // At most 400 frames; you can't see more anyway. The first and the last
        // are always kept, so the replay ends on the figure in the title.
        if sorted.count > 400 {
            let stride = Double(sorted.count - 1) / 399
            sorted = (0..<400).map { sorted[Int((Double($0) * stride).rounded())] }
        }

        var changes: [String: [Double]] = [:]
        var prices: [String: [Double?]] = [:]
        for (symbol, s) in series {
            var row = [Double](repeating: 0, count: sorted.count)
            var priceRow = [Double?](repeating: nil, count: sorted.count)
            var pointer = 0
            var last: Double?
            for (i, t) in sorted.enumerated() {
                while pointer < s.timestamps.count, s.timestamps[pointer] <= t {
                    if let close = s.closes[pointer] { last = close }
                    pointer += 1
                }
                let close = last ?? s.previousClose
                row[i] = (close / s.previousClose - 1) * 100
                priceRow[i] = close
            }
            changes[symbol] = row
            prices[symbol] = priceRow
        }

        // The curve: the index's or fund's own series. A list has none, so it
        // gets the equal-weight average of its stocks, labelled as such. A fund
        // priced by its daily NAV has no intraday series: its day is the
        // customary indicative value from the holdings' own prices, weighted as
        // in the fund, and marked "≈ … indicative". Any other missing series
        // gets no curve — an average of the members isn't the index.
        var curve: [Double] = []
        var indicative = false
        func average(_ weight: (String) -> Double?) -> [Double] {
            let rows = symbols.compactMap { symbol in changes[symbol].flatMap { row in weight(symbol).map { (row, $0) } } }
            let total = rows.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return [] }
            return (0..<sorted.count).map { i in rows.reduce(0) { $0 + $1.0[i] * $1.1 } / total }
        }
        if let benchmark, let row = changes[benchmark] {
            curve = row
        } else if let benchmark, FundNAV.isNAV(benchmark), period == .day,
                  let index = UniverseStore.shared.index(withID: AppState.shared.indexID) {
            curve = average { index.weight($0) }
            indicative = true
        } else if benchmark == nil {
            curve = average { _ in 1 }
        }

        self.changes = changes
        self.prices = prices
        self.curve = curve
        self.curveIsIndicative = indicative && !curve.isEmpty
        self.curveIsAverage = benchmark == nil && !curve.isEmpty
        self.timeline = sorted
    }
}

// MARK: - The seismograph

/// One row of the seismograph: a name and its change at every step.
struct SeismoRow: Identifiable {
    enum Kind {
        /// The index's or fund's own series (or a list's average).
        case total
        /// A sector or industry: the members' changes weighted by market value
        /// (by the fund's weights in a fund).
        case group(Focus)
        /// One tile's own series: a stock, or a list's fund or index.
        case stock(HeatItem)
    }

    let id: String
    let name: String
    let kind: Kind
    /// Empty when there is no series: the row shows "–".
    let values: [Double]
    var isAverage: Bool {
        if case .group = kind { return true }
        return false
    }
}

extension ReplayStore {
    /// The total row and one row per child of the level on screen: sectors
    /// in an index, industries in a sector, stocks in an industry or a list.
    /// The children are ranked by size; at most `limit`.
    func seismoRows(limit: Int) -> [SeismoRow] {
        let app = AppState.shared
        let key = "\(timeline.first ?? 0)|\(timeline.count)|\(app.tab)|\(app.indexID)|\(String(describing: app.watchlistID))|\(app.focus)|\(limit)"
        if let cached = rowCache, cached.key == key { return cached.rows }

        let current = Items.current()
        let items = current.items.filter { $0.matches(app.focus) }
        var rows: [SeismoRow] = []
        let source = Source.title
        // The total: the index's or fund's own series, never a stand-in.
        rows.append(SeismoRow(id: "total", name: source, kind: .total, values: curve))

        func average(_ members: [HeatItem]) -> [Double] {
            let series = members.compactMap { item in seriesOf(item.symbol).map { ($0, item.weight) } }
            let total = series.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return [] }
            return (0..<timeline.count).map { i in series.reduce(0) { $0 + $1.0[i] * $1.1 } / total }
        }

        if let title = app.focus.title, current.grouping == .sectors {
            rows.append(SeismoRow(id: "level", name: title, kind: .group(app.focus), values: average(items)))
        }

        var children: [(row: SeismoRow, size: Double)] = []
        switch (current.grouping, app.focus) {
        case (.sectors, .all):
            for (sector, members) in Dictionary(grouping: items, by: \.sector) {
                children.append((SeismoRow(id: "s:" + sector, name: sector, kind: .group(.sector(sector)), values: average(members)),
                                 members.reduce(0) { $0 + $1.weight }))
            }
        case (.sectors, .sector(let sector)):
            for (industry, members) in Dictionary(grouping: items, by: \.industry) {
                let focus = Focus.industry(sector: sector, industry: industry)
                children.append((SeismoRow(id: "i:" + industry, name: industry, kind: .group(focus), values: average(members)),
                                 members.reduce(0) { $0 + $1.weight }))
            }
        default:
            // A list's fund or index row is its own series; a NAV fund has
            // none for the day, so its row is empty rather than estimated.
            for item in items {
                children.append((SeismoRow(id: "t:" + item.symbol, name: item.title, kind: .stock(item),
                                           values: seriesOf(item.symbol) ?? []), item.weight))
            }
        }
        // A list's rows keep the list's order (every tile is the same size).
        let ranked = current.grouping == .flat ? children : children.sorted { $0.size > $1.size }
        rows += ranked.prefix(limit).map(\.row)
        rowCache = (key, rows)
        return rows
    }
}

/// The drawer under the map: one stripe per sector, industry or stock,
/// each step of the range coloured by that row's change — like a
/// seismograph of the market. Drag the cursor (or press ← →) and the map
/// shows that moment; space plays.
struct SeismographDrawer: View {
    let maxRows: Int

    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme

    private let rowHeight: CGFloat = 15
    private let labelWidth: CGFloat = 150
    private let valueWidth: CGFloat = 62

    var body: some View {
        VStack(spacing: 6) {
            header
            if replay.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Henter forløb…", "Loading history…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else if let error = replay.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, minHeight: 40)
            } else if replay.isReady {
                strips(replay.seismoRows(limit: maxRows))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { replay.togglePlay() } label: {
                Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!replay.isReady)
            .help(tr("Afspil / pause (mellemrum)", "Play / pause (space)"))

            Text(replay.isReady ? replay.timeLabel() : "–")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
            let total = replay.curveValue
            Text((replay.curveIsIndicative && total != nil ? "≈ " : "") + Format.percent(total))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Heat.textColor(total, style: prefs.colorStyle, theme: theme))
            if replay.curveIsAverage, total != nil {
                Text(tr("gennemsnit", "average")).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                ForEach([1.0, 2.0, 4.0], id: \.self) { speed in
                    Button { replay.speed = speed } label: {
                        Text("\(Int(speed))×")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(replay.speed == speed ? .primary : .secondary)
                            .frame(width: 28, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(replay.speed == speed ? Palette.surface : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
            .help(tr("Hastighed", "Speed"))

            Text(hint)
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ToolbarButton(symbol: "xmark", help: tr("Luk seismografen (Esc)", "Close the seismograph (Esc)")) { replay.stop() }
        }
    }

    private var hint: String {
        let step: String
        switch market.period.replayInterval {
        case "5m": step = tr("5 min.", "5 min")
        case "30m": step = tr("½ time", "½ hour")
        case "1d": step = tr("en dag", "a day")
        case "1wk": step = tr("en uge", "a week")
        default: step = tr("en måned", "a month")
        }
        return tr("\(market.period.label): \(step) pr. kolonne · træk i striberne · klik på en række for at gå ind",
                  "\(market.period.label): \(step) per column · drag across the stripes · click a row to go in")
    }

    @ViewBuilder
    private func strips(_ rows: [SeismoRow]) -> some View {
        let count = replay.timeline.count
        let frame = replay.frame
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    label(row).frame(width: labelWidth, height: rowHeight, alignment: .leading)
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let column = width / CGFloat(max(count, 1))
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let scale = market.period.colorScale
                        for (r, row) in rows.enumerated() {
                            let y = CGFloat(r) * rowHeight
                            guard row.values.count == count else {
                                context.fill(Path(CGRect(x: 0, y: y, width: width, height: rowHeight - 1)),
                                             with: .color(Palette.raised.opacity(0.5)))
                                continue
                            }
                            for (i, value) in row.values.enumerated() {
                                let color = Heat.color(value, scale: scale, style: prefs.colorStyle, theme: theme)
                                context.fill(Path(CGRect(x: CGFloat(i) * column, y: y, width: column + 0.6, height: rowHeight - 1)),
                                             with: .color(color))
                            }
                        }
                    }
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: CGFloat(rows.count) * rowHeight + 4)
                        .offset(x: (CGFloat(frame) + 0.5) * column - 1, y: -2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard count > 0 else { return }
                    replay.pause()
                    replay.frame = min(max(Int(value.location.x / column), 0), count - 1)
                })
            }
            .frame(height: CGFloat(rows.count) * rowHeight)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(rows) { row in
                    let value = row.values.indices.contains(frame) ? row.values[frame] : nil
                    Text((row.isAverage ? "" : (replay.curveIsIndicative && row.id == "total" && value != nil ? "≈ " : "")) + Format.percent(value))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Heat.textColor(value, style: prefs.colorStyle, theme: theme))
                        .frame(width: valueWidth, height: rowHeight, alignment: .trailing)
                }
            }
        }
        HStack(spacing: 8) {
            Spacer().frame(width: labelWidth)
            GeometryReader { geometry in
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    let i = Int((fraction * Double(max(count - 1, 0))).rounded())
                    Text(replay.timeLabel(i))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(max((CGFloat(i) + 0.5) * geometry.size.width / CGFloat(max(count, 1)), 24),
                                         geometry.size.width - 24),
                                  y: 6)
                }
            }
            .frame(height: 12)
            Spacer().frame(width: valueWidth)
        }
    }

    @ViewBuilder
    private func label(_ row: SeismoRow) -> some View {
        switch row.kind {
        case .total:
            Text(row.name)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1).truncationMode(.tail)
                .help(row.values.isEmpty
                      ? tr("Ingen kursforløb for \(row.name) selv — derfor ingen række.", "No price history for \(row.name) itself — so no row.")
                      : (replay.curveIsAverage ? tr("Gennemsnit med lige vægt af listens egne kursforløb", "Equal-weight average of the list's own price histories")
                                               : tr("\(row.name)s eget kursforløb", "\(row.name)'s own prices")))
        case .group(let focus):
            Button {
                app.focus = focus
            } label: {
                HStack(spacing: 4) {
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    Text(tr("gns.", "avg.")).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(focus == app.focus)
            .help(tr("Gennemsnit vægtet efter markedsværdi (i en fond: fondens vægte) · klik for at gå ind",
                     "Average weighted by market value (in a fund: the fund's weights) · click to go in"))
        case .stock(let item):
            Button { app.open(item) } label: {
                Text(row.name).font(.system(size: 11, weight: .medium)).lineLimit(1).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.values.isEmpty
                  ? tr("\(item.name) · intet eget kursforløb for perioden", "\(item.name) · no price history of its own for the range")
                  : item.name)
        }
    }
}

/// Refetches series when you switch index, list or time range while
/// playback is on.
struct ReplayReloader: ViewModifier {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var lists = ListsStore.shared

    private var key: String {
        "\(replay.isActive)|\(market.period.rawValue)|\(app.tab.rawValue)|\(app.indexID)|\(app.watchlistID?.uuidString ?? "")|\(lists.watchlist(app.watchlistID)?.items.count ?? 0)|\(market.quotes.isEmpty)"
    }

    func body(content: Content) -> some View {
        content.onChange(of: key) { _, _ in replay.reload() }
    }
}

/// Space, ← and → control playback — but not while you're typing.
@MainActor
enum ReplayKeys {
    static func handle(_ event: NSEvent) -> Bool {
        let replay = ReplayStore.shared
        if event.window?.firstResponder is NSTextView { return false }
        guard replay.isActive else {
            // Space on a map opens the seismograph, which then plays.
            guard event.keyCode == 49, AppState.shared.isMap, AppState.shared.dialog == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            replay.start(playing: true)
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: replay.togglePlay(); return true      // space
        case 123: replay.step(-1); return true         // ←
        case 124: replay.step(1); return true          // →
        default: return false
        }
    }
}
