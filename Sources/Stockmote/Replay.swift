import AppKit
import StockmoteShared
import SwiftUI

/// "Afspil dagen" (Replay the day): the map animated through the time range.
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

    private var changes: [String: [Double]] = [:]
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

    func start() {
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
            } else {
                self.frame = 0
                self.play()
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

// MARK: - The bar below the map

/// ▶ · time · draggable curve · speed · ×
struct ReplayBar: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Button {
                replay.togglePlay()
            } label: {
                Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!replay.isReady)
            .help(tr("Afspil / pause (mellemrum)", "Play / pause (space)"))

            VStack(alignment: .leading, spacing: 0) {
                Text(replay.isReady ? replay.timeLabel() : "–")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                Text((replay.curveIsIndicative && replay.curveValue != nil ? "≈ " : "") + Format.percent(replay.curveValue))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(replay.curveValue, style: prefs.colorStyle, theme: theme))
            }
            .frame(width: 92, alignment: .leading)

            ZStack {
                if replay.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(tr("Henter forløb…", "Loading history…"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if let error = replay.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                } else {
                    Scrubber(curve: replay.curve, frame: replay.frame, style: prefs.colorStyle, theme: theme) { replay.pause(); replay.frame = $0 }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)

            Menu {
                ForEach([1.0, 2.0, 4.0], id: \.self) { speed in
                    Toggle("\(Int(speed))×", isOn: Binding(get: { replay.speed == speed }, set: { _ in replay.speed = speed }))
                }
            } label: {
                Text("\(Int(replay.speed))×")
                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                    .frame(width: 34, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Hastighed", "Speed"))

            ToolbarButton(symbol: "xmark", help: tr("Luk afspilning (Esc)", "Close replay (Esc)")) {
                replay.stop()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

/// The curve over the time range, with the played part solid and the rest
/// faint. Click or drag to jump to a point in time.
private struct Scrubber: View {
    let curve: [Double]
    let frame: Int
    let style: ColorStyle
    let theme: Theme
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let x = curve.count > 1 ? size.width * CGFloat(frame) / CGFloat(curve.count - 1) : 0
            let color = Heat.textColor(curve.last, style: style, theme: theme)
            ZStack(alignment: .topLeading) {
                // The zero line: the previous close.
                Path { p in
                    let y = yPosition(0, in: size)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                line(in: size).stroke(color.opacity(0.28), lineWidth: 1.5)
                line(in: size).stroke(color, lineWidth: 2)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(x, 0)) }

                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: size.height)
                    .offset(x: x - 1)
                Circle()
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
                    .offset(x: x - 4, y: yPosition(curve.indices.contains(frame) ? curve[frame] : 0, in: size) - 4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard curve.count > 1 else { return }
                let fraction = min(max(value.location.x / size.width, 0), 1)
                onSeek(Int((fraction * CGFloat(curve.count - 1)).rounded()))
            })
        }
    }

    private var range: (min: Double, max: Double) {
        let low = min(curve.min() ?? 0, 0)
        let high = max(curve.max() ?? 0, 0)
        return high - low < 0.01 ? (low - 0.5, high + 0.5) : (low, high)
    }

    private func yPosition(_ value: Double, in size: CGSize) -> CGFloat {
        let r = range
        return size.height - 3 - CGFloat((value - r.min) / (r.max - r.min)) * (size.height - 6)
    }

    private func line(in size: CGSize) -> Path {
        Path { p in
            guard curve.count > 1 else { return }
            for (i, value) in curve.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(curve.count - 1), y: yPosition(value, in: size))
                i == 0 ? p.move(to: point) : p.addLine(to: point)
            }
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
        "\(replay.isActive)|\(market.period.rawValue)|\(app.tab.rawValue)|\(app.indexID)|\(app.watchlistID?.uuidString ?? "")|\(lists.favorites.count)|\(market.quotes.isEmpty)"
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
        guard replay.isActive else { return false }
        if event.window?.firstResponder is NSTextView { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: replay.togglePlay(); return true      // space
        case 123: replay.step(-1); return true         // ←
        case 124: replay.step(1); return true          // →
        default: return false
        }
    }
}
