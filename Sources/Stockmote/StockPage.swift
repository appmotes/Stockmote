import AppKit
import StockmoteShared
import SwiftUI

// MARK: - Candles from Yahoo

/// One candle: open, high, low and close over one interval, and the volume.
struct Candle: Hashable {
    let time: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
}

/// A stock's candles for one time range, from Yahoo's chart endpoint
/// (`v8/finance/chart`), which unlike the spark endpoint has open, high, low
/// and volume. Only real candles: one with a missing value is left out, and
/// when Yahoo has none the page says so.
struct StockChart {
    let candles: [Candle]
    let currency: String?
    let exchange: String?
}

extension Period {
    /// Candle size per range: 5 minutes for a day, half hours for a week,
    /// days up to the year to date, weeks for one, three and five years,
    /// months for all of it.
    var candleInterval: String {
        switch self {
        case .day: return "5m"
        case .week: return "30m"
        case .month, .quarter, .halfYear, .ytd: return "1d"
        case .year, .threeYears, .fiveYears: return "1wk"
        case .all: return "1mo"
        }
    }
}

@MainActor
final class StockChartStore: ObservableObject {
    static let shared = StockChartStore()

    enum State {
        case loading
        case loaded(StockChart)
        case empty
    }

    @Published private(set) var charts: [String: State] = [:]
    /// The highest and lowest close of the last 52 weeks, from the daily closes.
    @Published private(set) var yearRange: [String: (low: Double, high: Double)] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var fetched: [String: Date] = [:]

    private func key(_ symbol: String, _ period: Period) -> String { "\(symbol)|\(period.rawValue)" }

    func state(_ symbol: String, _ period: Period) -> State { charts[key(symbol, period)] ?? .loading }

    func load(_ symbol: String, period: Period) {
        let key = key(symbol, period)
        if tasks[key] != nil { return }
        if let at = fetched[key], Date().timeIntervalSince(at) < 300 { return }
        if charts[key] == nil { charts[key] = .loading }
        tasks[key] = Task { [weak self] in
            async let chart = Self.fetch(symbol, period: period)
            async let year = Self.fetch(symbol, range: "1y", interval: "1d", period1: nil)
            let (loaded, closes) = await (chart, year)
            guard let self else { return }
            self.charts[key] = loaded.map { $0.candles.isEmpty ? .empty : .loaded($0) } ?? .empty
            if let candles = closes?.candles, let low = candles.map(\.close).min(), let high = candles.map(\.close).max() {
                self.yearRange[symbol] = (low, high)
            }
            self.fetched[key] = Date()
            self.tasks[key] = nil
        }
    }

    /// Snapshot mode: waits until the chart is in.
    func waitForLoad(_ symbol: String, period: Period) async {
        load(symbol, period: period)
        await tasks[key(symbol, period)]?.value
    }

    nonisolated static func fetch(_ symbol: String, period: Period) async -> StockChart? {
        // Yahoo names no three-year range: ask from the day three years ago.
        if period == .threeYears, let start = period.start() {
            return await fetch(symbol, range: nil, interval: period.candleInterval, period1: Int(start.timeIntervalSince1970))
        }
        return await fetch(symbol, range: period.yahooRange, interval: period.candleInterval, period1: nil)
    }

    private struct Payload: Decodable {
        let chart: Chart?
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let meta: Meta?
            let timestamp: [Int]?
            let indicators: Indicators?
        }
        struct Meta: Decodable {
            let currency: String?
            let fullExchangeName: String?
            let exchangeName: String?
        }
        struct Indicators: Decodable { let quote: [Quote]? }
        struct Quote: Decodable {
            let open: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let close: [Double?]?
            let volume: [Double?]?
        }
    }

    nonisolated static func fetch(_ symbol: String, range: String?, interval: String, period1: Int?, attempt: Int = 0) async -> StockChart? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let yahoo = Symbols.yahoo(symbol).addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        let host = attempt % 2 == 0 ? "query1" : "query2"
        let span = period1.map { "period1=\($0)&period2=\(Int(Date().timeIntervalSince1970))" } ?? "range=\(range ?? "1d")"
        guard let url = URL(string: "https://\(host).finance.yahoo.com/v8/finance/chart/\(yahoo)?\(span)&interval=\(interval)&includePrePost=false") else { return nil }
        do {
            let (data, response) = try await Net.session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 3 {
                try? await Task.sleep(for: .seconds(1.2 * Double(attempt + 1)))
                return await fetch(symbol, range: range, interval: interval, period1: period1, attempt: attempt + 1)
            }
            guard status == 200, let result = try JSONDecoder().decode(Payload.self, from: data).chart?.result?.first else { return nil }
            let stamps = result.timestamp ?? []
            let quote = result.indicators?.quote?.first
            var candles: [Candle] = []
            for (i, time) in stamps.enumerated() {
                guard let open = quote?.open?[safe: i] ?? nil, let high = quote?.high?[safe: i] ?? nil,
                      let low = quote?.low?[safe: i] ?? nil, let close = quote?.close?[safe: i] ?? nil,
                      open > 0, high > 0, low > 0, close > 0 else { continue }
                candles.append(Candle(time: time, open: open, high: high, low: low, close: close,
                                      volume: quote?.volume?[safe: i] ?? nil))
            }
            return StockChart(candles: candles, currency: result.meta?.currency,
                              exchange: result.meta?.fullExchangeName ?? result.meta?.exchangeName)
        } catch {
            if attempt < 1 { return await fetch(symbol, range: range, interval: interval, period1: period1, attempt: attempt + 1) }
            return nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Peers

/// The stocks in the same industry: in the map the page was opened from,
/// otherwise in the stock's own index, otherwise among all US stocks the
/// app knows. Fewer than three, and the sector is used instead.
@MainActor
enum StockPeers {
    static func symbols(for symbol: String) -> [String] {
        let market = MarketStore.shared
        let info = market.info(symbol)
        var pool: [String]
        if let index = Source.index, index.symbols.contains(symbol) {
            pool = index.symbols
        } else if let index = UniverseStore.shared.indices.first(where: { $0.symbols.contains(symbol) }) {
            pool = index.symbols
        } else {
            pool = Array(market.quotes.keys)
        }
        var peers = pool.filter { market.info($0).industry == info.industry }
        if peers.count < 3 { peers = pool.filter { market.info($0).sector == info.sector } }
        if !peers.contains(symbol) { peers.append(symbol) }
        let size: (String) -> Double = { market.marketCap($0) ?? 0 }
        var top = Array(peers.sorted { size($0) > size($1) }.prefix(12))
        if !top.contains(symbol) { top[top.count - 1] = symbol }
        return top
    }
}

// MARK: - The page

/// A stock: price and change for the range, candles with open, high, low
/// and close on hover, key figures, its industry as a small map, the maps
/// and lists it is also in, adding it to a list — and one way out to the web.
struct StockPage: View {
    let symbol: String

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var charts = StockChartStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme
    @State private var hovered: Candle?

    var body: some View {
        let period = market.period
        GeometryReader { geometry in
            let narrow = geometry.size.width < 820
            HStack(alignment: .top, spacing: 0) {
                chartColumn(period)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Palette.separator).frame(width: 1)
                ScrollView {
                    StockSide(symbol: symbol, chart: chart(period))
                        .padding(14)
                }
                .frame(width: narrow ? 250 : 300)
                .background(Palette.sidebar)
            }
        }
        .task(id: "\(symbol)|\(period.rawValue)") { charts.load(symbol, period: period) }
    }

    private func chart(_ period: Period) -> StockChart? {
        if case .loaded(let chart) = charts.state(symbol, period) { return chart }
        return nil
    }

    @ViewBuilder
    private func chartColumn(_ period: Period) -> some View {
        let change = market.change(symbol, period)
        let chart = chart(period)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.price(market.price(symbol) ?? chart?.candles.last?.close,
                                  currency: chart?.currency ?? market.currency(symbol)))
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                Text(Format.percent(change))
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(change, style: prefs.colorStyle, theme: theme))
                    .help(Figure(change: change, since: market.since(symbol, period), period: period).help)
                Text(period.longName).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: $prefs.chartAsLine) {
                    Text(tr("Lys", "Candles")).tag(false)
                    Text(tr("Linje", "Line")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tr("Vis som lys (åbning, høj, lav, luk) eller som en linje af lukkekurser",
                         "Show as candles (open, high, low, close) or as a line of closing prices"))
            }
            readout(period, chart: chart)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
            switch charts.state(symbol, period) {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(tr("Yahoo har ingen kurser for \(Symbols.display(symbol)) i \(period.longName.lowercased()).",
                            "Yahoo has no prices for \(Symbols.display(symbol)) over \(period.longName.lowercased())."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let chart):
                CandleChart(candles: chart.candles, period: period, style: prefs.colorStyle, theme: theme,
                            asLine: prefs.chartAsLine, hovered: $hovered)
            }
        }
    }

    @ViewBuilder
    private func readout(_ period: Period, chart: StockChart?) -> some View {
        if let candle = hovered, prefs.chartAsLine {
            HStack(spacing: 8) {
                Text(CandleChart.label(candle.time, period: period, long: true)).fontWeight(.semibold).foregroundStyle(.primary)
                Text(tr("Luk", "Close") + " " + CandleChart.number(candle.close))
            }
        } else if let candle = hovered {
            let move = (candle.close / candle.open - 1) * 100
            HStack(spacing: 8) {
                Text(CandleChart.label(candle.time, period: period, long: true)).fontWeight(.semibold).foregroundStyle(.primary)
                Text(tr("Åbn", "Open") + " " + CandleChart.number(candle.open))
                Text(tr("Høj", "High") + " " + CandleChart.number(candle.high))
                Text(tr("Lav", "Low") + " " + CandleChart.number(candle.low))
                Text(tr("Luk", "Close") + " " + CandleChart.number(candle.close))
                Text(Format.percent(move)).foregroundStyle(Heat.textColor(move, style: prefs.colorStyle, theme: theme))
            }
        } else if let chart, prefs.chartAsLine {
            Text(tr("\(chart.candles.count) lukkekurser à \(CandleChart.intervalName(period)) · peg for kursen",
                    "\(chart.candles.count) closing prices of \(CandleChart.intervalName(period)) · point for the price"))
        } else if let chart {
            Text(tr("\(chart.candles.count) lys à \(CandleChart.intervalName(period)) · peg for åbning, høj, lav og luk",
                    "\(chart.candles.count) candles of \(CandleChart.intervalName(period)) · point for open, high, low and close"))
        }
    }
}

/// The candles (or a line through their closes), with volume underneath,
/// price labels on the right and dates below. Hover picks a candle; its
/// values are shown above the chart.
struct CandleChart: View {
    let candles: [Candle]
    let period: Period
    let style: ColorStyle
    let theme: Theme
    var asLine = false
    @Binding var hovered: Candle?
    @State private var hoverX: CGFloat?

    private let axisWidth: CGFloat = 58
    private let dateHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plot = CGSize(width: max(size.width - axisWidth, 10), height: size.height - dateHeight)
            let volumeHeight = min(46, plot.height * 0.16)
            let priceHeight = plot.height - volumeHeight - 6
            // A line only shows closes, so it is scaled to them.
            let low = (asLine ? candles.map(\.close) : candles.map(\.low)).min() ?? 0
            let high = (asLine ? candles.map(\.close) : candles.map(\.high)).max() ?? 1
            let pad = max((high - low) * 0.06, high * 0.001)
            let top = high + pad, bottom = low - pad
            // The top grid line sits low enough for its price label to fit above the plot's edge.
            let y: (Double) -> CGFloat = { 14 + CGFloat((top - $0) / (top - bottom)) * (priceHeight - 14) }
            let step = plot.width / CGFloat(max(candles.count, 1))
            let up = Heat.textColor(1, style: style, theme: theme)
            let down = Heat.textColor(-1, style: style, theme: theme)
            let maxVolume = candles.compactMap(\.volume).max() ?? 0
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for i in 0...4 {
                        let value = bottom + (top - bottom) * Double(i) / 4
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y(value)))
                        line.addLine(to: CGPoint(x: plot.width, y: y(value)))
                        context.stroke(line, with: .color(Palette.separator), lineWidth: 1)
                        context.draw(Text(Self.number(value)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                                     at: CGPoint(x: plot.width + 6, y: y(value)), anchor: .leading)
                    }
                    if asLine, let first = candles.first, let last = candles.last {
                        // One colour for the whole line: up or down over the range.
                        let color = last.close >= first.open ? up : down
                        var line = Path()
                        for (i, candle) in candles.enumerated() {
                            let point = CGPoint(x: (CGFloat(i) + 0.5) * step, y: y(candle.close))
                            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                        }
                        var area = line
                        area.addLine(to: CGPoint(x: (CGFloat(candles.count) - 0.5) * step, y: priceHeight))
                        area.addLine(to: CGPoint(x: 0.5 * step, y: priceHeight))
                        area.closeSubpath()
                        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                                                                 startPoint: CGPoint(x: 0, y: 0),
                                                                 endPoint: CGPoint(x: 0, y: priceHeight)))
                        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    }
                    for (i, candle) in candles.enumerated() {
                        let x = (CGFloat(i) + 0.5) * step
                        let color = candle.close >= candle.open ? up : down
                        let bodyWidth = max(1, step * 0.62)
                        if asLine {
                            if let volume = candle.volume, maxVolume > 0 {
                                let h = CGFloat(volume / maxVolume) * volumeHeight
                                context.fill(Path(CGRect(x: x - bodyWidth / 2, y: plot.height - h, width: bodyWidth, height: h)),
                                             with: .color(color.opacity(0.35)))
                            }
                            continue
                        }
                        var wick = Path()
                        wick.move(to: CGPoint(x: x, y: y(candle.high)))
                        wick.addLine(to: CGPoint(x: x, y: y(candle.low)))
                        context.stroke(wick, with: .color(color), lineWidth: 1)
                        let bodyTop = y(max(candle.open, candle.close))
                        let bodyHeight = max(1, abs(y(candle.open) - y(candle.close)))
                        context.fill(Path(CGRect(x: x - bodyWidth / 2, y: bodyTop, width: bodyWidth, height: bodyHeight)), with: .color(color))
                        if let volume = candle.volume, maxVolume > 0 {
                            let h = CGFloat(volume / maxVolume) * volumeHeight
                            context.fill(Path(CGRect(x: x - bodyWidth / 2, y: plot.height - h, width: bodyWidth, height: h)),
                                         with: .color(color.opacity(0.35)))
                        }
                    }
                    for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] where !candles.isEmpty {
                        let i = Int((fraction * Double(candles.count - 1)).rounded())
                        let x = (CGFloat(i) + 0.5) * step
                        let anchor: UnitPoint = fraction == 0 ? .topLeading : (fraction == 1 ? .topTrailing : .top)
                        context.draw(Text(Self.label(candles[i].time, period: period, long: false))
                                        .font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: x, y: plot.height + 4), anchor: anchor)
                    }
                }
                if hoverX != nil, let candle = hovered, let i = candles.firstIndex(of: candle) {
                    Rectangle().fill(Color.primary.opacity(0.35))
                        .frame(width: 1, height: plot.height)
                        .offset(x: (CGFloat(i) + 0.5) * step)
                    if asLine {
                        Circle().fill(Color.primary)
                            .frame(width: 7, height: 7)
                            .position(x: (CGFloat(i) + 0.5) * step, y: y(candle.close))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where point.x < plot.width && !candles.isEmpty:
                    hoverX = point.x
                    hovered = candles[min(max(Int(point.x / step), 0), candles.count - 1)]
                default:
                    hoverX = nil
                    hovered = nil
                }
            }
        }
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Lang.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func intervalName(_ period: Period) -> String {
        switch period.candleInterval {
        case "5m": return tr("5 minutter", "5 minutes")
        case "30m": return tr("en halv time", "half an hour")
        case "1d": return tr("en dag", "a day")
        case "1wk": return tr("en uge", "a week")
        default: return tr("en måned", "a month")
        }
    }

    static func label(_ time: Int, period: Period, long: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Lang.locale
        switch period {
        case .day: formatter.dateFormat = "HH.mm"
        case .week: formatter.dateFormat = long ? "EEE d. MMM HH.mm" : "EEE HH.mm"
        case .all, .fiveYears, .threeYears: formatter.dateFormat = long ? (Lang.isEnglish ? "MMM d, yyyy" : "d. MMM yyyy") : "MMM yyyy"
        default: formatter.dateFormat = Lang.isEnglish ? (long ? "MMM d, yyyy" : "MMM d") : (long ? "d. MMM yyyy" : "d. MMM")
        }
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
    }
}

/// The right-hand column: actions, key figures, peers and where else the
/// stock is.
private struct StockSide: View {
    let symbol: String
    let chart: StockChart?

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var charts = StockChartStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme
    @State private var showLists = false

    private var shown: String { Symbols.display(symbol) }

    var body: some View {
        let info = market.info(symbol)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button { showLists.toggle() } label: { Label(tr("Liste", "List"), systemImage: "plus") }
                    .buttonStyle(SearchButtonStyle())
                    .help(tr("Føj \(shown) til en liste", "Add \(shown) to a list"))
                    .popover(isPresented: $showLists, arrowEdge: .bottom) {
                        ListMenu(item: .stock(symbol), label: shown) { list in
                            lists.toggle(.stock(symbol), in: list)
                        } onNew: {
                            showLists = false
                            app.dialog = .newWatchlist(items: [.stock(symbol)])
                        }
                    }
            }
            Button { prefs.openQuote(symbol) } label: {
                Label(tr("Åbn på \(prefs.quoteSite.label)", "Open on \(prefs.quoteSite.label)"), systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SearchButtonStyle(prominent: true))

            section(tr("Nøgletal", "Key figures")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row(tr("Markedsværdi", "Market value"), Format.marketCap(market.marketCap(symbol)))
                    if let index = Source.index, index.isFund, let weight = funds.weight(of: symbol, inIndex: index.id) {
                        row(tr("Vægt i \(index.name)", "Weight in \(index.name)"), Format.weight(weight))
                    }
                    if let range = charts.yearRange[symbol] {
                        row(tr("52 uger (luk)", "52 weeks (closes)"), "\(CandleChart.number(range.low)) – \(CandleChart.number(range.high))")
                    }
                    if market.period != .day {
                        let day = market.change(symbol, .day)
                        GridRow {
                            Text(Period.day.longName).foregroundStyle(.secondary)
                            Text(Format.percent(day)).foregroundStyle(Heat.textColor(day, style: prefs.colorStyle, theme: theme))
                        }
                    }
                    row(tr("Sektor", "Sector"), info.sector)
                    row(tr("Industri", "Industry"), info.industry)
                    if let exchange = chart?.exchange { row(tr("Børs", "Exchange"), exchange) }
                    row(tr("Symbol", "Symbol"), symbol)
                }
                .font(.system(size: 11.5).monospacedDigit())
            }

            section(tr("Samme industri", "Same industry")) {
                PeerMap(symbol: symbol)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            let also = alsoIn
            if !also.isEmpty {
                section(tr("Også i", "Also in")) {
                    FlowLayout(spacing: 6) {
                        ForEach(also, id: \.label) { chip in
                            Button(chip.label, action: chip.open).buttonStyle(SearchButtonStyle())
                        }
                    }
                }
            }
        }
    }

    /// The indices the stock is in, the lists that hold it, and the funds
    /// in the lists that hold it — other than the one on screen.
    private var alsoIn: [(label: String, open: () -> Void)] {
        var chips: [(String, () -> Void)] = []
        let current = app.tab == .map ? app.indexID : nil
        for index in universe.indices where index.symbols.contains(symbol) && index.id != current {
            chips.append((index.title, { app.openIndex(index.id) }))
        }
        for list in lists.watchlists where list.symbols.contains(symbol) && !(app.tab == .watchlists && app.watchlistID == list.id) {
            chips.append((list.name, { app.openWatchlist(list.id) }))
        }
        // A fund in a list opens with that list as the way back.
        for fund in funds.funds where fund.id != current
            && funds.holdings[fund.symbol]?.holdings.contains(where: { $0.symbol == symbol }) == true {
            let list = lists.lists(containing: .fund(fund)).first?.id
            chips.append((fund.displaySymbol, { app.openIndex(fund.id, from: list) }))
        }
        return chips
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }
}

/// The industry's stocks as a small map, sized by market value and coloured
/// by their own change. The stock itself has a frame; a click opens another.
private struct PeerMap: View {
    let symbol: String
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme
    @State private var hover: String?

    var body: some View {
        let peers = StockPeers.symbols(for: symbol)
        let sizes = peers.map { max(market.marketCap($0) ?? 0, 1) }
        GeometryReader { geometry in
            let rects = TreemapBuilder.squarify(sizes.map { $0.squareRoot() }, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for (i, rect) in rects.enumerated() where i < peers.count {
                        let change = market.change(peers[i], market.period)
                        let fill = Heat.color(change, scale: market.period.colorScale, style: prefs.colorStyle, theme: theme)
                        context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(fill))
                        if rect.width > 34, rect.height > 18 {
                            let label = Heat.label(on: change, scale: market.period.colorScale, style: prefs.colorStyle, theme: theme)
                            context.draw(Text(Symbols.display(peers[i])).font(.system(size: min(13, rect.height / 2.6), weight: .bold))
                                            .foregroundStyle(label),
                                         at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                        if peers[i] == symbol || peers[i] == hover {
                            context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(theme.highlight), lineWidth: 2)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase, let i = rects.firstIndex(where: { $0.contains(point) }), i < peers.count {
                        hover = peers[i]
                    } else {
                        hover = nil
                    }
                }
                .onTapGesture { point in
                    if let i = rects.firstIndex(where: { $0.contains(point) }), i < peers.count, peers[i] != symbol {
                        app.openStock(peers[i])
                    }
                }
            }
            .help(hover.map { "\(market.info($0).name) · \(Format.percent(market.change($0, market.period)))" } ?? "")
        }
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
