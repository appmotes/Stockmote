import AppKit
import StockmoteShared
import SwiftUI

/// One row in the search: an index, a stock or a fund.
enum SearchItem: Identifiable {
    case index(MarketIndex)
    case stock(StockInfo)
    case fund(FundSearchResult)

    var id: String {
        switch self {
        case .index(let index): return "i:" + index.id
        case .stock(let info): return "s:" + info.symbol
        case .fund(let result): return "f:" + result.symbol
        }
    }
}

/// The one search (⌘K or /): indices, stocks and funds in one list. It is
/// also the only way to add things — a stock to favourites or to the
/// watchlist on screen, a fund under Mine — and to make a new watchlist.
///
/// Stocks and indices are found among those the app knows (the indices'
/// members and Nasdaq's US screener); funds through the fund search
/// (Yahoo, iShares, Vanguard, Xtrackers, Amundi, Nordnet …). A fund's
/// holdings are loaded before it is added, so only a fund that can be shown
/// as a map is added.
struct SearchDialog: View {
    let listHeight: CGFloat

    @ObservedObject private var picker = FundPicker.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared
    @State private var selection = 0
    /// The fund whose "Add" was clicked: added as soon as its holdings are in.
    @State private var pendingAdd: String?
    @FocusState private var focused: Bool

    /// The watchlist on screen, if any: stocks get "+ <list>".
    private var watchlist: Watchlist? {
        guard app.screen == .map, app.tab == .watchlists else { return nil }
        return lists.watchlist(app.watchlistID)
    }

    private var query: String { picker.query.trimmingCharacters(in: .whitespaces) }

    private var sections: [(title: String, items: [SearchItem])] {
        var sections: [(String, [SearchItem])] = []
        let text = query.lowercased()
        let indices = (universe.indices + funds.indices).filter { index in
            text.isEmpty || index.name.lowercased().contains(text) || index.id.lowercased().hasPrefix(text)
                || Symbols.display(index.benchmark).lowercased().hasPrefix(text)
        }
        if !indices.isEmpty {
            sections.append((tr("Indeks", "Indices"), Array(indices.prefix(text.isEmpty ? 20 : 4)).map(SearchItem.index)))
        }
        let stocks = market.search(query, limit: 7)
        if !stocks.isEmpty { sections.append((tr("Aktier", "Stocks"), stocks.map(SearchItem.stock))) }
        if !picker.results.isEmpty { sections.append((tr("Fonde", "Funds"), picker.results.map(SearchItem.fund))) }
        return sections
    }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
                TextField(tr("Søg aktie, indeks eller fond — fx novo, SAP eller VWCE",
                             "Search for a stock, index or fund — e.g. novo, SAP or VWCE"), text: $picker.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if items.indices.contains(selection) { primary(items[selection]) } }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                if picker.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Rectangle().fill(Palette.separator).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if items.isEmpty {
                            Text(query.count >= 2 && !picker.searching
                                 ? tr("Ingen resultater", "No results")
                                 : tr("Skriv navn eller symbol", "Type a name or symbol"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(14)
                        }
                        ForEach(sections, id: \.title) { section in
                            Text(section.title.uppercased())
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(section.items) { item in
                                let position = items.firstIndex { $0.id == item.id } ?? 0
                                row(item, isSelected: position == selection)
                                    .id(item.id)
                                    .onHover { if $0 { selection = position } }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: selection) { _, value in
                    if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
                }
            }
            .frame(height: listHeight)

            Rectangle().fill(Palette.separator).frame(height: 1)

            HStack(spacing: 10) {
                Button { app.dialog = .newWatchlist(symbols: []) } label: {
                    Text(tr("+ Ny watchliste", "+ New watchlist"))
                }
                .buttonStyle(SearchButtonStyle())
                Spacer()
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.outline))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        .task(id: picker.query) { await picker.search(debounce: true) }
        .onChange(of: picker.query) { _, _ in selection = 0 }
        .onChange(of: readyKey) { _, _ in addPendingIfReady() }
        .onAppear { focused = true }
        .onDisappear { picker.reset() }
    }

    private var hint: String {
        let enter = watchlist.map { tr("↩ tilføj til \($0.name)", "↩ add to \($0.name)") } ?? tr("↩ åbn", "↩ open")
        return tr("↑↓ vælg · \(enter) · Esc luk", "↑↓ select · \(enter) · Esc close")
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: SearchItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case .index(let index): indexRow(index)
            case .stock(let info): stockRow(info)
            case .fund(let result): fundRow(result)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { primary(item) }
    }

    @ViewBuilder
    private func indexRow(_ index: MarketIndex) -> some View {
        let figure = market.indexFigure(index, market.period)
        VStack(alignment: .leading, spacing: 1) {
            Text(index.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text(index.isFund ? Symbols.display(index.benchmark) : tr("\(index.symbols.count) aktier", "\(index.symbols.count) stocks"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 6)
        ChangeText(figure: figure)
        Button(tr("Åbn", "Open")) { primary(.index(index)) }.buttonStyle(SearchButtonStyle())
    }

    @ViewBuilder
    private func stockRow(_ info: StockInfo) -> some View {
        let figure = Figure(change: market.change(info.symbol, market.period), period: market.period)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(info.displaySymbol).font(.system(size: 12.5, weight: .bold))
                Text(info.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(home(info)).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        Spacer(minLength: 6)
        ChangeText(figure: figure)
        let isFavorite = lists.isFavorite(info.symbol)
        Button { toggleFavorite(info.symbol) } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.yellow : .secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? tr("Fjern fra favoritter", "Remove from favorites") : tr("Føj til favoritter", "Add to favorites"))
        if let watchlist {
            let contained = lists.contains(info.symbol, in: watchlist.id)
            Button((contained ? "✓ " : "+ ") + watchlist.name) { lists.toggle(info.symbol, in: watchlist.id) }
                .buttonStyle(SearchButtonStyle(prominent: !contained))
                .help(contained ? tr("Fjern fra \(watchlist.name)", "Remove from \(watchlist.name)")
                                : tr("Føj til \(watchlist.name)", "Add to \(watchlist.name)"))
        }
        Button(tr("Åbn", "Open")) { open(info.symbol) }.buttonStyle(SearchButtonStyle())
    }

    @ViewBuilder
    private func fundRow(_ result: FundSearchResult) -> some View {
        let added = funds.contains(result.symbol)
        let isPicked = picker.selected == result
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(Symbols.display(result.symbol)).font(.system(size: 12.5, weight: .bold))
                Text(result.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            fundDetail(result, isPicked: isPicked)
        }
        Spacer(minLength: 6)
        if added {
            // Everything that switches on also switches off: a click removes it.
            Button(tr("Tilføjet ✓", "Added ✓")) { app.removeFund(result.symbol) }
                .buttonStyle(SearchButtonStyle())
                .help(tr("Klik for at fjerne \(Symbols.display(result.symbol))", "Click to remove \(Symbols.display(result.symbol))"))
        } else if isPicked, case .failed = picker.phase {
            EmptyView()
        } else {
            Button(tr("Tilføj", "Add")) { add(result) }
                .buttonStyle(SearchButtonStyle(prominent: true))
                .disabled(isPicked && pendingAdd == result.symbol)
        }
    }

    @ViewBuilder
    private func fundDetail(_ result: FundSearchResult, isPicked: Bool) -> some View {
        let plain = result.fund.kindLabel + (result.exchange.isEmpty ? "" : " · \(result.exchange)")
        if isPicked {
            switch picker.phase {
            case .loading(let text):
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(text)
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            case .ready(let loaded):
                Text(funds.preview(loaded)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            case .failed(let reason):
                Text(reason ?? tr("Kunne ikke finde beholdningen. Fonden kan ikke vises.",
                                  "Couldn't find the holdings. The fund can't be shown."))
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            case .idle:
                Text(plain).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        } else {
            Text(plain).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    /// "Novo Nordisk · 🇩🇰 C25 · Health Care" — where the stock is from.
    private func home(_ info: StockInfo) -> String {
        var parts: [String] = []
        if let index = universe.indices.first(where: { $0.symbols.contains(info.symbol) }) { parts.append(index.title) }
        parts.append(info.industry)
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Return, or a click on the row.
    private func primary(_ item: SearchItem) {
        switch item {
        case .index(let index):
            app.dialog = nil
            app.openIndex(index.id)
        case .stock(let info):
            if let watchlist {
                // Return adds to the list on screen (and never removes by accident).
                if !lists.contains(info.symbol, in: watchlist.id) { lists.toggle(info.symbol, in: watchlist.id) }
                app.show(tr("\(info.displaySymbol) er føjet til \(watchlist.name)", "\(info.displaySymbol) was added to \(watchlist.name)"))
            } else {
                open(info.symbol)
            }
        case .fund(let result):
            if funds.contains(result.symbol) {
                app.dialog = nil
                app.openIndex(FundStore.id(result.symbol))
            } else {
                add(result)
            }
        }
    }

    private func open(_ symbol: String) {
        app.dialog = nil
        app.openStock(symbol)
    }

    private func toggleFavorite(_ symbol: String) {
        let was = lists.isFavorite(symbol)
        lists.toggleFavorite(symbol)
        let shown = Symbols.display(symbol)
        app.show(was ? tr("\(shown) er fjernet fra favoritter", "\(shown) was removed from favorites")
                     : tr("\(shown) er føjet til favoritter", "\(shown) was added to favorites"))
    }

    /// Picks the fund and loads its holdings; it is added (and opened) as
    /// soon as they are in. A bond fund, or one whose holdings can't be
    /// found, says so and is not added.
    private func add(_ result: FundSearchResult) {
        pendingAdd = result.symbol
        if picker.selected != result { picker.select(result) }
        addPendingIfReady()
    }

    private var readyKey: String {
        switch picker.phase {
        case .ready: return "ready:" + (picker.selected?.symbol ?? "")
        case .failed: return "failed"
        case .loading: return "loading"
        case .idle: return "idle"
        }
    }

    private func addPendingIfReady() {
        guard let pendingAdd, picker.selected?.symbol == pendingAdd else { return }
        switch picker.phase {
        case .ready:
            self.pendingAdd = nil
            picker.commit()
        case .failed:
            self.pendingAdd = nil
        default:
            break
        }
    }
}

/// The change in a search row.
private struct ChangeText: View {
    let figure: Figure
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme

    var body: some View {
        Text(figure.text)
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Heat.textColor(figure.change, style: prefs.colorStyle, theme: theme))
            .help(figure.help)
            .frame(minWidth: 58, alignment: .trailing)
    }
}

/// Small buttons drawn by hand, so they look the same whether or not the
/// window is key (and in snapshots).
struct SearchButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Color.accentColor : Palette.raised))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}
