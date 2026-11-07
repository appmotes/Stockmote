import AppKit
import StockmoteShared
import SwiftUI

/// Kortets tema ud fra det udseende panelet har fået.
struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var heatTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Læser lyst/mørkt fra miljøet og giver det videre som `heatTheme`.
struct ThemeProvider<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.heatTheme, scheme == .dark ? .dark : .light)
    }
}

/// Panelet: sidebjælke til venstre, værktøjslinje og kort til højre.
///
/// Opbygget som en Mac-app — kildeliste, værktøjslinje, statuslinje — og ikke
/// som en telefon med faner i bunden.
struct PanelRoot: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var replay = ReplayStore.shared
    var size: CGSize? = nil

    var body: some View {
        let size = size ?? prefs.panelSize.size
        ThemeProvider {
            HStack(spacing: 0) {
                if prefs.sidebarVisible {
                    Sidebar()
                        .frame(width: 212)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(Palette.separator).frame(width: 1)
                }
                VStack(spacing: 0) {
                    Toolbar()
                        .frame(minWidth: 0, maxWidth: .infinity)
                    Rectangle().fill(Palette.separator).frame(height: 1)
                    Content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if replay.isActive && app.tab != .settings {
                        ReplayBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    StatusLine()
                }
                .background(Palette.background)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Palette.background)
        .animation(.easeInOut(duration: 0.2), value: prefs.sidebarVisible)
        .animation(.easeInOut(duration: 0.2), value: replay.isActive)
        .modifier(ReplayReloader())
        .background { KeyboardShortcuts() }
        // Skifter sproget, bygges alt om, så hver tekst læses igen.
        .id(prefs.language)
    }
}

private struct Content: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        switch app.tab {
        case .map: MapContent()
        case .favorites: FavoritesContent()
        case .watchlists: WatchlistContent()
        case .settings: SettingsTab()
        }
    }
}

// MARK: - Sidebjælke

private struct Sidebar: View {
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text("Stockmote")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                SidebarIconButton(symbol: "sidebar.left", help: tr("Skjul sidebjælke (⌘0)", "Hide sidebar (⌘0)")) {
                    prefs.sidebarVisible = false
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 50)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SectionTitle(text: tr("USA", "United States"))
                    ForEach(universe.indices.filter { !$0.isEuropean }) { IndexRow(index: $0) }

                    SectionTitle(text: tr("Europa", "Europe"))
                    ForEach(universe.indices.filter(\.isEuropean)) { IndexRow(index: $0) }

                    SectionTitle(text: tr("Fonde", "Funds"),
                                 addHelp: tr("Tilføj ETF eller fond", "Add ETF or fund"),
                                 isAdding: app.fundSearchOpen) {
                        app.fundSearchOpen.toggle()
                    }
                    ForEach(funds.funds) { FundRow(fund: $0) }
                    if funds.funds.isEmpty && !app.fundSearchOpen {
                        Button { app.fundSearchOpen = true } label: {
                            Text(tr("Tilføj en ETF eller indeksfond …", "Add an ETF or index fund …"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    SectionTitle(text: tr("Mine lister", "My lists")) {
                        let id = lists.createWatchlist(named: tr("Ny liste", "New list"))
                        app.watchlistID = id
                        app.tab = .watchlists
                        app.renamingWatchlist = id
                    }
                    ListRow(
                        symbol: "star.fill", tint: .yellow, title: tr("Favoritter", "Favorites"),
                        symbols: lists.favorites, isSelected: app.tab == .favorites
                    ) { app.tab = .favorites }
                    ForEach(lists.watchlists) { list in
                        WatchlistRow(list: list)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            // Søgefeltet står fast i bunden og ikke under "Fonde", som ligger
            // så langt nede at resultaterne ellers ville være skjult.
            if app.fundSearchOpen {
                Rectangle().fill(Palette.separator).frame(height: 1)
                FundSearchField()
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Rectangle().fill(Palette.separator).frame(height: 1)
            HStack(spacing: 4) {
                SidebarRowButton(
                    symbol: "gearshape", title: tr("Indstillinger", "Settings"),
                    isSelected: app.tab == .settings
                ) { app.toggleSettings() }
                SidebarIconButton(symbol: "power", help: tr("Afslut Stockmote (⌘Q)", "Quit Stockmote (⌘Q)")) {
                    NSApp.terminate(nil)
                }
            }
            .padding(8)
        }
        .background(Palette.sidebar)
    }
}

private struct SectionTitle: View {
    let text: String
    var addHelp = tr("Ny watchliste", "New watchlist")
    /// Plusset bliver et kryds mens der tilføjes.
    var isAdding = false
    var onAdd: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: isAdding ? "xmark" : "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isAdding ? tr("Luk søgning", "Close search") : addHelp)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }
}

/// Fælles række: ikon eller flag, titel, og ændringen til højre.
private struct SidebarRow<Leading: View>: View {
    let title: String
    let change: Double?
    let isSelected: Bool
    var detail: String? = nil
    @ViewBuilder let leading: Leading
    let action: () -> Void

    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading.frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(Format.percent(change))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(change, style: prefs.colorStyle, theme: theme))
            }
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Palette.raised : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct IndexRow: View {
    let index: MarketIndex
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        SidebarRow(
            title: index.name,
            change: market.indexChange(index, market.period),
            isSelected: app.tab == .map && app.indexID == index.id
        ) {
            Text(index.flag ?? "🏳️").font(.system(size: 13))
        } action: {
            app.selectIndex(index.id)
        }
        .help(tr("\(index.name) · \(index.symbols.count) aktier · \(index.hours.statusText)",
                 "\(index.name) · \(index.symbols.count) stocks · \(index.hours.statusText)"))
    }
}

/// En fond i sidebjælken. Højreklik henter beholdningen igen eller fjerner den.
private struct FundRow: View {
    let fund: Fund
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let index = funds.index(for: fund)
        SidebarRow(
            title: fund.shortName,
            change: market.indexChange(index, market.period),
            isSelected: app.tab == .map && app.indexID == fund.id
        ) {
            if funds.progress[fund.symbol] != nil {
                ProgressView().controlSize(.mini)
            } else if funds.errors[fund.symbol] != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                Image(systemName: "chart.pie.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } action: {
            app.selectIndex(fund.id)
        }
        .help(help(index))
        .contextMenu {
            Button(tr("Hent beholdningen igen", "Reload holdings")) { funds.load(fund.symbol, force: true) }
            Button(tr("Kopiér symbol", "Copy symbol")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fund.displaySymbol, forType: .string)
            }
            Divider()
            Button(tr("Fjern \(fund.displaySymbol)", "Remove \(fund.displaySymbol)"), role: .destructive) {
                funds.remove(fund.symbol)
            }
        }
    }

    private func help(_ index: MarketIndex) -> String {
        var lines = ["\(fund.name) · \(fund.displaySymbol) · \(fund.kindLabel)"]
        if let note = funds.sourceNote(fund.symbol) { lines.append(note) }
        lines.append(index.hours.statusText)
        return lines.joined(separator: "\n")
    }
}

/// Søgefeltet for fonde: navn eller ticker på en ETF eller fond. Yahoo's
/// søgning, når man holder en pause i skrivningen. Retur tilføjer og åbner
/// det første resultat; et klik på et resultat gør det samme — eller fjerner
/// fonden igen, hvis den allerede er med (✓).
private struct FundSearchField: View {
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared
    @State private var results: [FundSearchResult] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
                TextField(tr("SPY, MSCI World, C25 …", "SPY, MSCI World, C25 …"), text: $app.fundQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let first = results.first { open(first) }
                    }
                    .onExitCommand { close() }
                if searching {
                    ProgressView().controlSize(.mini)
                }
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Luk (Esc)", "Close (Esc)"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
            .padding(.bottom, 2)

            ForEach(results) { result in
                FundResultRow(result: result, isAdded: funds.contains(result.symbol)) {
                    if funds.contains(result.symbol) {
                        funds.remove(result.symbol)
                    } else {
                        open(result)
                    }
                }
            }
            if !searching, results.isEmpty, app.fundQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text(tr("Ingen ETF'er eller fonde fundet", "No ETFs or funds found"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
            }
        }
        .padding(.bottom, 4)
        .onAppear { focused = true }
        .task(id: app.fundQuery) {
            let query = app.fundQuery
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
                results = []
                return
            }
            // Vent til man holder en pause i skrivningen.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await FundStore.search(query)
            guard !Task.isCancelled else { return }
            results = Array(found.prefix(8))
            searching = false
        }
    }

    private func open(_ result: FundSearchResult) {
        funds.add(result.fund)
        app.indexID = result.fund.id
        app.tab = .map
        close()
    }

    private func close() {
        app.fundQuery = ""
        app.fundSearchOpen = false
    }
}

private struct FundResultRow: View {
    let result: FundSearchResult
    let isAdded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(Symbols.display(result.symbol)).font(.system(size: 11.5, weight: .bold))
                        Text(result.fund.kindLabel + (result.exchange.isEmpty ? "" : " · \(result.exchange)"))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    Text(result.name).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isAdded ? .green : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isAdded ? tr("Allerede tilføjet — klik for at fjerne", "Already added — click to remove") : result.name)
    }
}

/// Ligevægtet gennemsnit af en listes aktier.
@MainActor
private func averageChange(_ symbols: [String]) -> Double? {
    let market = MarketStore.shared
    let changes = symbols.compactMap { market.change($0, market.period) }
    return changes.isEmpty ? nil : changes.reduce(0, +) / Double(changes.count)
}

private struct ListRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let symbols: [String]
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        SidebarRow(title: title, change: averageChange(symbols), isSelected: isSelected,
                   detail: "\(symbols.count)") {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
        } action: { action() }
    }
}

private struct WatchlistRow: View {
    let list: Watchlist
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var app = AppState.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if app.renamingWatchlist == list.id {
            TextField(tr("Navn", "Name"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focused)
                .onAppear {
                    draft = list.name
                    focused = true
                }
                .onSubmit {
                    lists.rename(list.id, to: draft)
                    app.renamingWatchlist = nil
                }
                .onExitCommand { app.renamingWatchlist = nil }
                .padding(.vertical, 2)
        } else {
            ListRow(symbol: "list.bullet", tint: .secondary, title: list.name, symbols: list.symbols,
                    isSelected: app.tab == .watchlists && app.watchlistID == list.id) {
                app.watchlistID = list.id
                app.tab = .watchlists
            }
            .contextMenu {
                Button(tr("Omdøb", "Rename")) { app.renamingWatchlist = list.id }
                Button(tr("Slet \(list.name)", "Delete \(list.name)"), role: .destructive) {
                    lists.delete(list.id)
                    if app.watchlistID == list.id {
                        app.watchlistID = lists.watchlists.first?.id
                        if app.watchlistID == nil { app.tab = .favorites }
                    }
                }
            }
        }
    }
}

private struct SidebarRowButton: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                Text(title).font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Palette.raised : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SidebarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 27)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Værktøjslinje

private struct Toolbar: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        HStack(spacing: 10) {
            if !prefs.sidebarVisible {
                ToolbarButton(symbol: "sidebar.left", help: tr("Vis sidebjælke (⌘0)", "Show sidebar (⌘0)")) {
                    prefs.sidebarVisible = true
                }
            }
            // Titlen giver sig først: den forkortes med … frem for at skubbe
            // resten. Før var den låst til sin fulde bredde, og et langt navn
            // som "Euro Stoxx 50" i den lille panelstørrelse gjorde hele
            // indholdet bredere end vinduet — så sidebjælken røg ud over
            // venstre kant.
            TitleBlock()
                .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            if app.tab != .settings {
                // Er der ikke plads til hele tidsvælgeren, bliver den en menu.
                ViewThatFits(in: .horizontal) {
                    controls(compact: false)
                    controls(compact: true)
                }
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if compact { PeriodMenu() } else { PeriodPicker() }
            ReplayButton()
            ViewModePicker()
            ToolbarButton(symbol: "arrow.up.left.and.arrow.down.right",
                          help: tr("Fuld skærm (⌃⌘F)", "Full screen (⌃⌘F)")) {
                FullscreenController.shared.toggle()
            }
            RefreshButton()
        }
        .fixedSize()
    }
}

/// Tidsvælgeren som menu, når panelet er for smalt til hele rækken.
private struct PeriodMenu: View {
    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        Menu {
            ForEach(Period.allCases) { period in
                Toggle("\(period.label)  ·  \(period.longName)", isOn: Binding(
                    get: { market.period == period },
                    set: { _ in market.period = period }
                ))
            }
        } label: {
            HStack(spacing: 5) {
                Text(market.period.label).font(.system(size: 11.5, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(market.period.longName)
    }
}

/// Titlen: det man kigger på, stort, og ændringen under.
///
/// Er man gået ind i en sektor eller branche, står det niveau som titel med en
/// tilbagepil foran, og vejen derop ("🇩🇰 C25 › Health Care") står småt under.
/// Hele stien på én linje kunne ikke være der i den lille panelstørrelse.
private struct TitleBlock: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.heatTheme) private var theme

    private var index: MarketIndex? { universe.index(withID: app.indexID) }
    private var isDrilled: Bool { app.tab == .map && app.focus != .all }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if isDrilled {
                    Button {
                        if let parent = app.focus.parent { app.focus = parent }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Tilbage (Esc)", "Back (Esc)"))
                }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if app.tab != .settings {
                HStack(spacing: 5) {
                    Text(Format.percent(change))
                        .foregroundStyle(Heat.textColor(change, style: prefs.colorStyle, theme: theme))
                    if isDrilled {
                        Button {
                            app.focus = .all
                        } label: {
                            Text(path).lineLimit(1).truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(tr("Tilbage til \(index?.name ?? "")", "Back to \(index?.name ?? "")"))
                    } else if replay.isReady {
                        // Under afspilning står tidspunktet der hvor tidsrummet plejer.
                        Text("▶ \(replay.timeLabel())").foregroundStyle(.secondary)
                    } else if app.tab == .map, let index, index.isFund {
                        // En fond: tickeren ved siden af tidsrummet, så man kan se hvilken.
                        Text("\(Symbols.display(index.benchmark)) · \(market.period.longName)").foregroundStyle(.tertiary)
                    } else {
                        Text(market.period.longName).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            }
        }
    }

    private var title: String {
        switch app.tab {
        case .map:
            if let focus = app.focus.title { return focus }
            return index?.title ?? ""
        case .favorites: return tr("Favoritter", "Favorites")
        case .watchlists: return lists.watchlist(app.watchlistID)?.name ?? tr("Watchliste", "Watchlist")
        case .settings: return tr("Indstillinger", "Settings")
        }
    }

    /// Vejen op: "🇪🇺 Euro Stoxx 50" eller "🇪🇺 Euro Stoxx 50 › Information Technology".
    private var path: String {
        let root = index?.title ?? ""
        if case .industry(let sector, _) = app.focus { return "\(root) › \(sector)" }
        return root
    }

    private var change: Double? {
        switch app.tab {
        case .map:
            guard let index else { return nil }
            if app.focus == .all, let value = replay.curveValue { return value }
            guard app.focus != .all else { return market.indexChange(index, market.period) }
            // Sektorens eller branchens egen ændring, vægtet efter markedsværdi.
            let items = Items.make(index.symbols, weights: index.weights).filter { item in
                switch app.focus {
                case .all: return true
                case .sector(let s): return item.sector == s
                case .industry(let s, let i): return item.sector == s && item.industry == i
                }
            }
            let known = items.filter { $0.change != nil }
            let weight = known.reduce(0) { $0 + $1.weight }
            return weight > 0 ? known.reduce(0) { $0 + $1.change! * $1.weight } / weight : nil
        case .favorites: return averageChange(lists.favorites)
        case .watchlists: return averageChange(lists.watchlist(app.watchlistID)?.symbols ?? [])
        case .settings: return nil
        }
    }
}

/// 1D · 1U · 1M · 3M · ÅTD · 1Å som en segmenteret kontrol, hvor markeringen
/// glider over til det valgte.
private struct PeriodPicker: View {
    @ObservedObject private var market = MarketStore.shared
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { period in
                let isSelected = market.period == period
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { market.period = period }
                } label: {
                    Text(period.label)
                        .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(minWidth: 30)
                        .padding(.horizontal, 3)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "period", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(period.longName)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        .fixedSize()
    }
}

private struct ViewModePicker: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            segment("square.grid.2x2", selected: !app.showList, help: tr("Kort (⌘L)", "Map (⌘L)")) { app.showList = false }
            segment("list.bullet", selected: app.showList, help: tr("Liste (⌘L)", "List (⌘L)")) { app.showList = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        .fixedSize()
    }

    private func segment(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 28, height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.surface)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RefreshButton: View {
    @ObservedObject private var market = MarketStore.shared
    @State private var spin = false

    var body: some View {
        ToolbarButton(symbol: "arrow.clockwise", help: tr("Opdatér (⌘R)", "Refresh (⌘R)")) {
            Task { await market.refresh() }
        }
        .rotationEffect(.degrees(spin ? 360 : 0))
        .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
        .onChange(of: market.isLoading || market.loadingPeriod != nil) { _, loading in spin = loading }
        .onAppear { spin = market.isLoading }
    }
}

struct ToolbarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Statuslinje

private struct StatusLine: View {
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared

    /// For en fond: hvor beholdningen kommer fra, og om den er beskåret.
    private var fundNote: String? {
        guard app.tab == .map, let symbol = FundStore.symbol(fromID: app.indexID) else { return nil }
        return funds.progress[symbol] ?? funds.sourceNote(symbol)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let hours = MarketClock.current
            HStack(spacing: 6) {
                Circle()
                    .fill(hours.isOpen() ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(hours.statusText)
                Text("·").foregroundStyle(.tertiary)
                Text(tr("Opdateret \(Format.time(market.lastUpdated))", "Updated \(Format.time(market.lastUpdated))"))
                if let period = market.loadingPeriod, period != .day {
                    ProgressView().controlSize(.mini)
                    Text(tr("Henter \(period.longName)…", "Loading \(period.longName)…"))
                }
                if let fundNote, market.errorMessage == nil {
                    Text("·").foregroundStyle(.tertiary)
                    Text(fundNote).lineLimit(1).truncationMode(.tail).help(fundNote)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if let error = market.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 22)
        }
    }
}

/// Usynlige knapper der bærer tastaturgenvejene.
private struct KeyboardShortcuts: View {
    var body: some View {
        ZStack {
            Button("") { Task { await MarketStore.shared.refresh() } }.keyboardShortcut("r")
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
            Button("") { AppState.shared.showList.toggle() }.keyboardShortcut("l")
            Button("") { ReplayStore.shared.toggle() }.keyboardShortcut("p")
            Button("") { Preferences.shared.sidebarVisible.toggle() }.keyboardShortcut("0")
            Button("") { AppState.shared.toggleSettings() }.keyboardShortcut(",")
            Button("") { FullscreenController.shared.toggle() }.keyboardShortcut("f", modifiers: [.command, .control])
            // ⌘1 … ⌘9: indekserne i sidebjælkens rækkefølge.
            ForEach(1..<10) { number in
                Button("") {
                    let indices = UniverseStore.shared.indices
                    guard number <= indices.count else { return }
                    AppState.shared.selectIndex(indices[number - 1].id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

// MARK: - Indhold

/// Fælles: kort eller liste over nogle aktier.
struct StocksView: View {
    let items: [HeatItem]
    let grouping: Grouping
    let contentKey: Int
    var allowsDrillDown = true
    var extraMenu: ((HeatItem) -> AnyView)? = nil
    /// En fonds vægte: listen viser dem i stedet for markedsværdi.
    var weights: [String: Double]? = nil

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if market.quotes.isEmpty && market.snapshots.isEmpty {
            LoadingView()
        } else if app.showList {
            StockList(items: items, period: market.period, style: prefs.colorStyle,
                      showDrillDown: allowsDrillDown, extraMenu: extraMenu, weights: weights)
        } else {
            HeatmapView(
                items: items, grouping: grouping, focus: allowsDrillDown ? app.focus : .all,
                period: market.period, style: prefs.colorStyle, contentKey: contentKey,
                allowsDrillDown: allowsDrillDown,
                onFocus: { app.focus = $0; app.tab = .map },
                extraMenu: extraMenu
            )
        }
    }
}

private struct LoadingView: View {
    @ObservedObject private var market = MarketStore.shared

    var body: some View {
        VStack(spacing: 10) {
            if let error = market.errorMessage, !market.isLoading {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(tr("Prøv igen", "Try again")) { Task { await market.refresh() } }
            } else {
                ProgressView()
                Text(tr("Henter kurser…", "Loading quotes…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bygger kortets elementer ud fra symboler.
@MainActor
enum Items {
    /// `weights`: en fonds vægte. Så er feltets størrelse aktiens andel af
    /// fonden og ikke dens markedsværdi.
    static func make(_ symbols: [String], byMarketCap: Bool = true, weights: [String: Double]? = nil) -> [HeatItem] {
        let market = MarketStore.shared
        let lists = ListsStore.shared
        let replay = ReplayStore.shared
        let size: (String) -> Double? = { symbol in weights.map { $0[symbol] } ?? market.marketCap(symbol) }
        let caps = symbols.compactMap(size)
        // BF.B o.l. har ingen markedsværdi. De får det mindste felt frem for
        // at forsvinde.
        let fallback = caps.min() ?? 1
        return symbols.map { symbol in
            let info = market.info(symbol)
            let cap = size(symbol) ?? fallback
            return HeatItem(
                symbol: symbol, name: info.name, sector: info.sector, industry: info.industry,
                weight: byMarketCap ? cap : 1,
                // Under afspilning: ændringen på det valgte tidspunkt.
                change: replay.isReady ? (replay.change(symbol) ?? 0) : market.change(symbol, market.period),
                isFavorite: lists.isFavorite(symbol)
            )
        }
    }

    static func key(_ parts: AnyHashable...) -> Int {
        var hasher = Hasher()
        hasher.combine(MarketStore.shared.version)
        hasher.combine(MarketStore.shared.period)
        hasher.combine(ListsStore.shared.favorites)
        let replay = ReplayStore.shared
        hasher.combine(replay.isReady ? replay.frame : -1)
        hasher.combine(replay.timeline.count)
        for part in parts { hasher.combine(part) }
        return hasher.finalize()
    }

    /// Hvad der vises lige nu — bruges også af fuldskærm.
    static func current() -> (items: [HeatItem], grouping: Grouping, key: Int, drillDown: Bool) {
        let app = AppState.shared
        let lists = ListsStore.shared
        let prefs = Preferences.shared
        switch app.tab {
        case .favorites:
            return (make(lists.favorites, byMarketCap: prefs.listsByMarketCap), .flat,
                    key("favorites", prefs.listsByMarketCap), false)
        case .watchlists:
            let list = lists.watchlist(app.watchlistID)
            return (make(list?.symbols ?? [], byMarketCap: prefs.listsByMarketCap), .flat,
                    key("watchlist", list, prefs.listsByMarketCap), false)
        case .map, .settings:
            let universe = UniverseStore.shared
            let index = universe.index(withID: app.indexID) ?? universe.indices.first
            return (make(index?.symbols ?? [], weights: index?.weights), .sectors,
                    key(index?.id ?? "", index?.symbols.count ?? 0), true)
        }
    }
}

private struct MapContent: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var funds = FundStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        if let symbol = FundStore.symbol(fromID: app.indexID), funds.holdings[symbol] == nil,
           let fund = funds.fund(symbol) {
            FundStatusView(fund: fund)
        } else if let error = universe.loadError {
            VStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(tr("Genindlæs indekslister", "Reload index lists")) { universe.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let current = Items.current()
            StocksView(
                items: current.items.filter { item in
                    guard app.showList else { return true }
                    switch app.focus {
                    case .all: return true
                    case .sector(let s): return item.sector == s
                    case .industry(let s, let i): return item.sector == s && item.industry == i
                    }
                },
                grouping: .sectors,
                contentKey: current.key,
                weights: universe.index(withID: app.indexID)?.weights
            )
        }
    }
}

/// En fond hvis beholdning ikke er hentet: hvor langt det er nået, eller
/// hvorfor det ikke lykkedes.
private struct FundStatusView: View {
    let fund: Fund
    @ObservedObject private var funds = FundStore.shared

    var body: some View {
        VStack(spacing: 10) {
            if let error = funds.errors[fund.symbol] {
                Image(systemName: "chart.pie").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button(tr("Prøv igen", "Try again")) { funds.load(fund.symbol, force: true) }
                    Button(tr("Fjern \(fund.displaySymbol)", "Remove \(fund.displaySymbol)")) { funds.remove(fund.symbol) }
                }
            } else {
                ProgressView()
                Text(funds.progress[fund.symbol] ?? tr("Henter beholdningen…", "Loading holdings…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(fund.name).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if funds.errors[fund.symbol] == nil { funds.load(fund.symbol, force: false) }
        }
    }
}

private struct FavoritesContent: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            AddSymbolBar(placeholder: tr("Tilføj favorit — symbol eller navn", "Add favorite — symbol or name"),
                         contains: { lists.isFavorite($0) },
                         onAdd: { if !lists.isFavorite($0) { lists.toggleFavorite($0) } },
                         onToggle: { lists.toggleFavorite($0) })
            if lists.favorites.isEmpty {
                EmptyListView(text: tr("Ingen favoritter endnu", "No favorites yet"),
                              detail: tr("Søg ovenfor, eller højreklik på en aktie på kortet og vælg “Føj til favoritter”.",
                                         "Search above, or right-click a stock on the map and choose “Add to favorites”."))
            } else {
                let current = Items.current()
                StocksView(items: current.items, grouping: .flat, contentKey: current.key, allowsDrillDown: false)
            }
        }
    }
}

private struct WatchlistContent: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var lists = ListsStore.shared
    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            if let list = lists.watchlist(app.watchlistID) ?? lists.watchlists.first {
                AddSymbolBar(placeholder: tr("Tilføj til \(list.name) — symbol eller navn", "Add to \(list.name) — symbol or name"),
                             contains: { lists.contains($0, in: list.id) },
                             onAdd: { if !lists.contains($0, in: list.id) { lists.toggle($0, in: list.id) } },
                             onToggle: { lists.toggle($0, in: list.id) })
                if list.symbols.isEmpty {
                    EmptyListView(text: tr("\(list.name) er tom", "\(list.name) is empty"),
                                  detail: tr("Søg ovenfor, eller højreklik på en aktie på kortet og vælg Watchlister.",
                                             "Search above, or right-click a stock on the map and choose Watchlists."))
                } else {
                    let current = Items.current()
                    StocksView(
                        items: current.items, grouping: .flat, contentKey: current.key, allowsDrillDown: false,
                        extraMenu: { item in
                            AnyView(Button(tr("Fjern \(Symbols.display(item.symbol)) fra \(list.name)",
                                              "Remove \(Symbols.display(item.symbol)) from \(list.name)")) {
                                lists.remove(item.symbol, from: list.id)
                            })
                        }
                    )
                }
            } else {
                EmptyListView(text: tr("Ingen watchlister", "No watchlists"),
                              detail: tr("Lav en med + i sidebjælken.", "Make one with + in the sidebar."))
            }
        }
        .onAppear {
            if app.watchlistID == nil { app.watchlistID = lists.watchlists.first?.id }
        }
    }
}

private struct EmptyListView: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "star.square.on.square").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Søgefelt der foreslår aktier mens man skriver. Retur tilføjer det første
/// forslag.
private struct AddSymbolBar: View {
    let placeholder: String
    let contains: (String) -> Bool
    /// Retur: tilføjer det første forslag (aldrig fjern ved et uheld).
    let onAdd: (String) -> Void
    /// Klik på et forslag: tilføjer, eller fjerner hvis den allerede er med (✓).
    let onToggle: (String) -> Void

    @ObservedObject private var market = MarketStore.shared
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = market.search(text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        if let first = matches.first { add(first.symbol) }
                    }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { match in
                        SuggestionRow(info: match, isAdded: contains(match.symbol)) { onToggle(match.symbol) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.outline))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    private func add(_ symbol: String) {
        onAdd(symbol)
        text = ""
    }
}

private struct SuggestionRow: View {
    let info: StockInfo
    let isAdded: Bool
    let action: () -> Void

    @ObservedObject private var market = MarketStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        let dayChange = market.change(info.symbol, .day)
        Button(action: action) {
            HStack(spacing: 10) {
                Text(info.displaySymbol).font(.system(size: 12, weight: .bold)).frame(width: 72, alignment: .leading)
                Text(info.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(Format.percent(dayChange))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Heat.textColor(dayChange, style: prefs.colorStyle, theme: theme))
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isAdded ? .green : .secondary)
                    .frame(width: 16)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isHovering ? Palette.raised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Liste

enum SortKey: String, CaseIterable, Identifiable {
    case changeDown, changeUp, marketCap, symbol
    var id: String { rawValue }
    var label: String {
        switch self {
        case .changeDown: return tr("Største stigning", "Biggest gain")
        case .changeUp: return tr("Største fald", "Biggest loss")
        case .marketCap: return tr("Markedsværdi", "Market value")
        case .symbol: return tr("Symbol", "Symbol")
        }
    }
}

struct StockList: View {
    let items: [HeatItem]
    let period: Period
    let style: ColorStyle
    var showDrillDown = true
    var extraMenu: ((HeatItem) -> AnyView)? = nil
    var weights: [String: Double]? = nil

    @ObservedObject private var market = MarketStore.shared
    @AppStorage("listSort", store: AppDefaults.store) private var sort: SortKey = .changeDown

    /// Markedsværdi — eller vægten i fonden, når det er en fond.
    private func size(_ symbol: String) -> Double {
        (weights.map { $0[symbol] } ?? market.marketCap(symbol)) ?? 0
    }

    private var sorted: [HeatItem] {
        switch sort {
        case .changeDown: return items.sorted { ($0.change ?? -.infinity) > ($1.change ?? -.infinity) }
        case .changeUp: return items.sorted { ($0.change ?? .infinity) < ($1.change ?? .infinity) }
        case .marketCap: return items.sorted { size($0.symbol) > size($1.symbol) }
        case .symbol: return items.sorted { $0.symbol < $1.symbol }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(tr("\(items.count) aktier", "\(items.count) stocks")).foregroundStyle(.secondary)
                Spacer()
                Picker(tr("Sortér", "Sort"), selection: $sort) {
                    ForEach(SortKey.allCases) { key in
                        Text(key == .marketCap && weights != nil ? tr("Vægt i fonden", "Weight in fund") : key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Text(tr("Symbol", "Symbol")).frame(width: 78, alignment: .leading)
                Text(tr("Navn", "Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(tr("Kurs", "Price")).frame(width: 96, alignment: .trailing)
                Text(weights != nil ? tr("Vægt", "Weight") : tr("Markedsværdi", "Market value"))
                    .frame(width: 100, alignment: .trailing)
                Text(period.label).frame(width: 82, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            Rectangle().fill(Palette.separator).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted, id: \.symbol) { item in
                        StockRow(item: item, price: market.price(item.symbol), currency: market.currency(item.symbol),
                                 marketCap: market.marketCap(item.symbol), weight: weights?[item.symbol],
                                 isFund: weights != nil, period: period, style: style)
                            .contextMenu {
                                StockMenu(item: item, showDrillDown: showDrillDown,
                                          onFocus: { AppState.shared.focus = $0; AppState.shared.showList = false })
                                if let extraMenu {
                                    Divider()
                                    extraMenu(item)
                                }
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct StockRow: View {
    let item: HeatItem
    let price: Double?
    let currency: String
    let marketCap: Double?
    var weight: Double? = nil
    var isFund = false
    let period: Period
    let style: ColorStyle

    @Environment(\.heatTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button {
            Preferences.shared.openQuote(item.symbol)
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(Symbols.display(item.symbol)).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                }
                .frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    Text(item.industry).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.price(price, currency: currency))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 96, alignment: .trailing)
                Text(isFund ? Format.weight(weight) : Format.marketCap(marketCap))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text(Format.percent(item.change))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Heat.label(on: item.change, scale: period.colorScale, style: style, theme: theme))
                    .frame(width: 74, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Heat.color(item.change, scale: period.colorScale, style: style, theme: theme)))
                    .frame(width: 82, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.raised : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// ▶ i værktøjslinjen: tænder og slukker "Afspil dagen" (⌘P).
private struct ReplayButton: View {
    @ObservedObject private var replay = ReplayStore.shared
    @ObservedObject private var market = MarketStore.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            replay.toggle()
        } label: {
            Image(systemName: replay.isActive ? "play.circle.fill" : "play.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(replay.isActive ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(market.period == .day
              ? tr("Afspil dagen (⌘P)", "Replay the day (⌘P)")
              : tr("Afspil \(market.period.longName) (⌘P)", "Replay \(market.period.longName) (⌘P)"))
        .onHover { isHovering = $0 }
    }
}
