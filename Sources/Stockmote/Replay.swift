import AppKit
import StockmoteShared
import SwiftUI

/// "Afspil dagen": kortet animeret gennem tidsrummet.
///
/// Et almindeligt heatmap viser hvor dagen endte. Her ser man hvordan den kom
/// derhen — åbningen, frokostsalget, den sidste time. Med 1D afspilles dagen i
/// 5-minutters skridt; med 1U i halve timer; med 1M, 3M og ÅTD dag for dag; med
/// 1Å uge for uge.
///
/// Forløbene hentes fra samme Yahoo-adresse som kurserne, bare med
/// `interval` sat. Felternes størrelse står fast mens det kører; kun farverne
/// skifter, så kortet ikke hopper rundt.
@MainActor
final class ReplayStore: ObservableObject {
    static let shared = ReplayStore()

    @Published private(set) var isActive = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    /// Tidspunkterne der afspilles (Unix-sekunder).
    @Published private(set) var timeline: [Int] = []
    @Published var frame = 0 {
        didSet { if frame != oldValue { frame = min(max(frame, 0), max(timeline.count - 1, 0)) } }
    }
    /// 1×, 2× eller 4×.
    @Published var speed: Double = 1
    @Published private(set) var errorMessage: String?
    /// Indeksets kurve (eller listens gennemsnit), én værdi pr. tidspunkt.
    @Published private(set) var curve: [Double] = []

    /// Fuldskærm afspiller i ring som en levende skærm; panelet stopper ved enden.
    var loops = false

    private var changes: [String: [Double]] = [:]
    private var prices: [String: [Double?]] = [:]
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?
    private var player: Task<Void, Never>?
    private var loadedPeriod: Period = .day

    /// En hel gennemspilning varer så længe ved 1×.
    private let baseDuration: Double = 14

    var isReady: Bool { isActive && !timeline.isEmpty }

    // MARK: Styring

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
                    // Et øjeblik på slutbilledet, så forfra.
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

    // MARK: Opslag

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

    /// "11.15" for en dag, "tor. 14.30" for en uge, "3. nov." for længere.
    func timeLabel(_ index: Int? = nil) -> String {
        let i = index ?? frame
        guard i < timeline.count else { return "–" }
        let date = Date(timeIntervalSince1970: TimeInterval(timeline[i]))
        let formatter = DateFormatter()
        formatter.locale = Lang.locale
        switch loadedPeriod {
        case .day: formatter.dateFormat = "HH.mm"
        case .week: formatter.dateFormat = "EEE HH.mm"
        case .year: formatter.dateFormat = Lang.isEnglish ? "MMM d, yyyy" : "d. MMM yyyy"
        default: formatter.dateFormat = Lang.isEnglish ? "MMM d" : "d. MMM"
        }
        return formatter.string(from: date)
    }

    // MARK: Hentning

    /// Henter forløb for det man kigger på — hvis det har ændret sig.
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

    /// Lægger alle forløb på én fælles tidslinje. Et symbol der endnu ikke har
    /// handlet på et tidspunkt (fx en amerikansk aktie før New York åbner),
    /// står på sin forrige lukkekurs — ændring 0.
    private func build(_ series: [String: Yahoo.Series], symbols: [String], benchmark: String?, period: Period) {
        loadedPeriod = period
        var stamps = Set<Int>()
        let source = benchmark.flatMap { series[$0] }.map { [$0] } ?? Array(series.values)
        for s in source { stamps.formUnion(s.timestamps) }
        if stamps.isEmpty { for s in series.values { stamps.formUnion(s.timestamps) } }
        var sorted = stamps.sorted()
        // Højst ~400 billeder; flere ses ikke alligevel.
        if sorted.count > 400 {
            let stride = Double(sorted.count) / 400
            sorted = (0..<400).map { sorted[min(Int(Double($0) * stride), sorted.count - 1)] }
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

        // Kurven: indekset selv, ellers et ligevægtet gennemsnit af listen.
        var curve: [Double]
        if let benchmark, let row = changes[benchmark] {
            curve = row
        } else {
            let rows = symbols.compactMap { changes[$0] }
            curve = (0..<sorted.count).map { i in
                rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1[i] } / Double(rows.count)
            }
        }

        self.changes = changes
        self.prices = prices
        self.curve = curve
        self.timeline = sorted
    }
}

// MARK: - Linjen under kortet

/// ▶ · klokkeslæt · kurve man kan trække i · hastighed · ×
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
                Text(Format.percent(replay.curveValue))
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

/// Kurven over tidsrummet, med det afspillede stykke tydeligt og resten
/// svagt. Klik eller træk for at gå til et tidspunkt.
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
                // Nullinjen: forrige lukkekurs.
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

/// Henter forløb igen når man skifter indeks, liste eller tidsrum mens
/// afspilningen er tændt.
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

/// Mellemrum, ← og → styrer afspilningen — men ikke mens man skriver.
@MainActor
enum ReplayKeys {
    static func handle(_ event: NSEvent) -> Bool {
        let replay = ReplayStore.shared
        guard replay.isActive else { return false }
        if event.window?.firstResponder is NSTextView { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: replay.togglePlay(); return true      // mellemrum
        case 123: replay.step(-1); return true         // ←
        case 124: replay.step(1); return true          // →
        default: return false
        }
    }
}
