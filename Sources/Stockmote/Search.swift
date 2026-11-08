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
/// also the way to add things: every row has "+ Liste" (a menu of the lists
/// and a new one), and when a list is on screen also "+ <list>" — Return
/// then adds to that list. "+ Ny watchliste" makes a new list.
///
/// Stocks and indices are found among those the app knows (the indices'
/// members and Nasdaq's US screener); funds through the fund search
/// (Yahoo, iShares, Vanguard, Xtrackers, Amundi, Nordnet …). A fund's
/// holdings are loaded before it goes in a list, so it can be opened as a
/// map; a bond fund goes in too, with its own price and no map.
struct SearchDialog: View {
    let listHeight: CGFloat

    @ObservedObject private var picker = FundPicker.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared
    @State private var selection = 0
    /// The row whose "+ Liste" menu is open.
    @State private var menuFor: String?
    @FocusState private var focused: Bool

    /// The list on screen, if any: every row gets "+ <list>".
    private var watchlist: Watchlist? {
        guard app.screen == .map, app.tab == .watchlists else { return nil }
        return lists.watchlist(app.watchlistID)
    }

    private var query: String { picker.query.trimmingCharacters(in: .whitespaces) }

    private var sections: [(title: String, items: [SearchItem])] {
        var sections: [(String, [SearchItem])] = []
        let text = query.lowercased()
        let indices = universe.indices.filter { index in
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
                Button { app.dialog = .newWatchlist(items: []) } label: {
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
            Text(tr("\(index.symbols.count) aktier", "\(index.symbols.count) stocks"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 6)
        ChangeText(figure: figure)
        addButtons(.index(index.id), label: index.name)
        Button(tr("Åbn", "Open")) { open(.index(index)) }.buttonStyle(SearchButtonStyle())
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
        addButtons(.stock(info.symbol), label: info.displaySymbol)
        Button(tr("Åbn", "Open")) { open(.stock(info)) }.buttonStyle(SearchButtonStyle())
    }

    @ViewBuilder
    private func fundRow(_ result: FundSearchResult) -> some View {
        let isPicked = picker.selected == result
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(result.fund.displaySymbol).font(.system(size: 12.5, weight: .bold))
                Text(result.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            fundDetail(result, isPicked: isPicked)
        }
        Spacer(minLength: 6)
        addButtons(.fund(funds.fund(result.symbol) ?? result.fund), label: result.fund.displaySymbol, fund: result)
        if funds.contains(result.symbol) {
            Button(tr("Åbn", "Open")) { open(.fund(result)) }
                .buttonStyle(SearchButtonStyle())
                .disabled(!funds.canOpen(result.symbol))
                .help(funds.fund(result.symbol)?.mapless?.message(result.fund.displaySymbol) ?? "")
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
                Text(reason ?? tr("Kunne ikke finde beholdningen. Fonden kan stå i en liste med sin egen kurs, men ikke åbnes som kort.",
                                  "Couldn't find the holdings. The fund can be in a list with its own price, but not opened as a map."))
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            case .idle:
                Text(plain).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        } else {
            Text(plain).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    /// "+ Liste" (a menu of every list and a new one) and, with a list on
    /// screen, "+ <list>" / "✓ <list>".
    @ViewBuilder
    private func addButtons(_ item: ListItem, label: String, fund: FundSearchResult? = nil) -> some View {
        let pending = fund.map { picker.isPending($0.symbol) } ?? false
        Button(tr("+ Liste", "+ List")) { menuFor = item.key }
            .buttonStyle(SearchButtonStyle())
            .help(tr("Føj \(label) til en liste", "Add \(label) to a list"))
            .popover(isPresented: Binding(get: { menuFor == item.key }, set: { if !$0 { menuFor = nil } }),
                     arrowEdge: .bottom) {
                ListMenu(item: item, label: label) { list in
                    menuFor = nil
                    toggle(item, fund: fund, in: list)
                } onNew: {
                    menuFor = nil
                    if let fund { picker.keepLoaded(fund.symbol) }
                    app.dialog = .newWatchlist(items: [item])
                }
            }
        if let watchlist {
            let contained = watchlist.contains(item)
            Button((contained ? "✓ " : "+ ") + watchlist.name) { toggle(item, fund: fund, in: watchlist.id) }
                .buttonStyle(SearchButtonStyle(prominent: !contained))
                .disabled(pending)
                .help(contained ? tr("Fjern \(label) fra \(watchlist.name)", "Remove \(label) from \(watchlist.name)")
                                : tr("Føj \(label) til \(watchlist.name)", "Add \(label) to \(watchlist.name)"))
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

    /// Return, or a click on the row: with a list on screen, adds to it
    /// (and never removes by accident); otherwise opens.
    private func primary(_ item: SearchItem) {
        if let watchlist {
            switch item {
            case .index(let index): add(.index(index.id), fund: nil, to: watchlist.id)
            case .stock(let info): add(.stock(info.symbol), fund: nil, to: watchlist.id)
            case .fund(let result): add(.fund(funds.fund(result.symbol) ?? result.fund), fund: result, to: watchlist.id)
            }
            return
        }
        switch item {
        case .fund(let result) where !funds.contains(result.symbol):
            // Not in a list yet: show what it holds.
            picker.select(result)
        default:
            open(item)
        }
    }

    private func open(_ item: SearchItem) {
        switch item {
        case .index(let index):
            app.dialog = nil
            app.openIndex(index.id)
        case .stock(let info):
            app.dialog = nil
            app.openStock(info.symbol)
        case .fund(let result):
            guard let fund = funds.fund(result.symbol) else { return }
            app.dialog = nil
            app.openIndex(fund.id)
        }
    }

    private func toggle(_ item: ListItem, fund: FundSearchResult?, in list: UUID) {
        if lists.contains(item, in: list) {
            lists.remove(item, from: list)
            let name = lists.watchlist(list)?.name ?? ""
            app.show(tr("\(AppState.label(item)) er fjernet fra \(name)", "\(AppState.label(item)) was removed from \(name)"))
        } else {
            add(item, fund: fund, to: list)
        }
    }

    /// A fund's holdings are loaded before it goes in (FundPicker); a stock
    /// or an index goes in at once.
    private func add(_ item: ListItem, fund: FundSearchResult?, to list: UUID) {
        guard !lists.contains(item, in: list) else { return }
        if let fund {
            picker.add(fund, to: list)
            return
        }
        lists.add(item, to: list)
        let name = lists.watchlist(list)?.name ?? ""
        app.show(tr("\(AppState.label(item)) er føjet til \(name)", "\(AppState.label(item)) was added to \(name)"))
    }
}

/// "+ Liste": every list with a tick where the item is, and a new list.
struct ListMenu: View {
    let item: ListItem
    let label: String
    let onToggle: (UUID) -> Void
    let onNew: () -> Void

    @ObservedObject private var lists = ListsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lists.watchlists) { list in
                Button { onToggle(list.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").opacity(list.contains(item) ? 1 : 0)
                        Text(list.name)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !lists.watchlists.isEmpty { Divider() }
            Button(action: onNew) {
                Text(tr("Ny liste med \(label) …", "New list with \(label) …")).padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(minWidth: 200)
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
