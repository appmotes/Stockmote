import AppKit
import StockmoteShared
import SwiftUI

// MARK: - The dialog

/// The open dialog (`AppState.dialog`), centred over the whole window on a
/// dimmed backdrop.
///
/// A plain SwiftUI overlay inside PanelRoot rather than a sheet, so it
/// looks the same in the window and in snapshots. Esc is caught by the
/// window's key monitor (PanelKeys), which closes the dialog before
/// anything else.
struct DialogHost: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let dialog = app.dialog {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(scheme == .dark ? 0.55 : 0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { app.dialog = nil }
                    Group {
                        switch dialog {
                        case .addFund:
                            // The result list gets what is left of the window's
                            // height, so the dialog fits the smallest window too.
                            AddFundDialog(listHeight: max(110, min(250, geometry.size.height - 300)))
                        case .newWatchlist(let symbols):
                            NewWatchlistDialog(symbols: symbols)
                        case .renameWatchlist(let id):
                            RenameWatchlistDialog(id: id)
                        }
                    }
                    .frame(width: min(440, geometry.size.width - 48))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .transition(.opacity)
        }
    }
}

/// The card itself: title, an optional explanation, the content, and
/// Cancel / a primary button. Return presses the primary button.
struct DialogCard<Content: View>: View {
    let title: String
    var message: String? = nil
    let primary: String
    var primaryEnabled = true
    let onPrimary: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 8) {
                Spacer()
                Button(tr("Annullér", "Cancel"), action: onCancel)
                    .buttonStyle(DialogButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(primary, action: onPrimary)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryEnabled)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.outline))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
    }
}

/// Drawn by hand like the rest of the window's buttons, so it looks the same
/// whether or not the window is key (and in snapshots).
private struct DialogButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minWidth: 76, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Color.accentColor : Palette.raised)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// The text field used in the dialogs.
private struct DialogField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var busy = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if busy {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.outline))
        .onAppear { focused = true }
    }
}

// MARK: - Watchlists

/// Asks for a name, for a new or a renamed watchlist.
private struct NameDialog: View {
    let title: String
    var message: String? = nil
    let primary: String
    let initial: String
    let onCommit: (String) -> Void

    @ObservedObject private var app = AppState.shared
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogCard(title: title, message: message, primary: primary, primaryEnabled: !trimmed.isEmpty,
                   onPrimary: commit, onCancel: { app.dialog = nil }) {
            DialogField(placeholder: tr("Navn", "Name"), text: $name)
        }
        .onAppear { name = initial }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        app.dialog = nil
    }
}

private struct NewWatchlistDialog: View {
    let symbols: [String]
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let shown = symbols.map(Symbols.display).joined(separator: ", ")
        NameDialog(
            title: tr("Ny watchliste", "New watchlist"),
            message: symbols.isEmpty ? nil : tr("Listen starter med \(shown).", "The list starts with \(shown)."),
            primary: tr("Opret", "Create"),
            initial: ""
        ) { name in
            let id = ListsStore.shared.createWatchlist(named: name, with: symbols)
            app.watchlistID = id
            // From the sidebar the new, empty list is shown; from the map's
            // context menu the user stays on the map.
            if symbols.isEmpty { app.tab = .watchlists }
        }
    }
}

private struct RenameWatchlistDialog: View {
    let id: UUID
    @ObservedObject private var lists = ListsStore.shared

    var body: some View {
        NameDialog(
            title: tr("Omdøb watchliste", "Rename watchlist"),
            primary: tr("Omdøb", "Rename"),
            initial: lists.watchlist(id)?.name ?? ""
        ) { name in
            lists.rename(id, to: name)
        }
    }
}

// MARK: - Funds

/// Search, pick and check a fund before it is added. The picked fund's
/// holdings are loaded right here, and only a fund whose holdings could be
/// loaded can be added — the sidebar never gets a fund that can't be shown.
private struct AddFundDialog: View {
    let listHeight: CGFloat
    @ObservedObject private var picker = FundPicker.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        DialogCard(
            title: tr("Tilføj ETF eller fond", "Add ETF or fund"),
            message: tr("Søg på navn eller ticker. Beholdningen hentes, før fonden tilføjes.",
                        "Search by name or ticker. The holdings are loaded before the fund is added."),
            primary: picker.isAdded ? tr("Vis", "Show") : tr("Tilføj", "Add"),
            primaryEnabled: picker.canCommit,
            onPrimary: { picker.commit() },
            onCancel: { app.dialog = nil }
        ) {
            DialogField(placeholder: tr("SPY, MSCI World, SEC0, C25 …", "SPY, MSCI World, SEC0, C25 …"),
                        text: $picker.query, icon: "magnifyingglass", busy: picker.searching) {
                // The focused field gets Return before the Add button's
                // default-action shortcut does, so Return is handled here:
                // it picks the first result, and once the holdings are
                // loaded, adds the fund.
                Task { await picker.submit() }
            }
            results
            FundPickerStatus()
        }
        .task(id: picker.query) { await picker.search(debounce: true) }
        .onDisappear { picker.reset() }
    }

    @ViewBuilder private var results: some View {
        if !picker.results.isEmpty {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(picker.results) { result in
                        FundResultRow(result: result, isSelected: picker.selected == result,
                                      isAdded: FundStore.shared.contains(result.symbol)) {
                            picker.select(result)
                        }
                    }
                }
            }
            .frame(height: min(listHeight, CGFloat(picker.results.count) * 37))
        } else if !picker.searching, picker.hasSearched {
            Text(tr("Ingen ETF'er eller fonde fundet", "No ETFs or funds found"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }
}

/// What happened to the picked fund: loading, ready (with a preview of the
/// holdings) or failed.
private struct FundPickerStatus: View {
    @ObservedObject private var picker = FundPicker.shared
    @ObservedObject private var funds = FundStore.shared

    var body: some View {
        if let selected = picker.selected {
            HStack(alignment: .top, spacing: 8) {
                switch picker.phase {
                case .loading(let text):
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    lines(text, selected.name)
                case .ready(let loaded):
                    icon("checkmark.circle.fill", .green)
                    lines(funds.preview(loaded), funds.sourceNote(for: loaded))
                case .failed(let reason):
                    icon("exclamationmark.triangle.fill", .orange)
                    lines(reason ?? tr("Kunne ikke finde beholdningen for \(selected.name). Fonden kan ikke vises.",
                                       "Couldn't find the holdings for \(selected.name). The fund can't be shown."), nil)
                case .idle:
                    if picker.isAdded {
                        icon("checkmark.circle", .secondary)
                        lines(tr("\(selected.name) er allerede i sidebjælken.", "\(selected.name) is already in the sidebar."), nil)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised.opacity(0.6)))
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 14)).foregroundStyle(color).frame(width: 16, height: 16)
    }

    private func lines(_ first: String, _ second: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(first).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let second {
                Text(second).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct FundResultRow: View {
    let result: FundSearchResult
    let isSelected: Bool
    let isAdded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(Symbols.display(result.symbol)).font(.system(size: 10.5, weight: .bold))
                        Text(result.fund.kindLabel + (result.exchange.isEmpty ? "" : " · \(result.exchange)"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                        .help(tr("Allerede i sidebjælken", "Already in the sidebar"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Palette.raised : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The add-fund dialog's state: search, the picked result and its holdings.
/// A model rather than view state, so snapshot mode can drive it and wait
/// for the holdings (`--fund-search`, `--fund-pick`).
@MainActor
final class FundPicker: ObservableObject {
    static let shared = FundPicker()

    enum Phase {
        case idle
        case loading(String)
        case ready(FundHoldings)
        /// With a message when the fund is known but can't be shown (a bond fund).
        case failed(String?)
    }

    @Published var query = ""
    @Published private(set) var results: [FundSearchResult] = []
    @Published private(set) var searching = false
    @Published private(set) var selected: FundSearchResult?
    @Published private(set) var phase: Phase = .idle
    /// The query the results are for.
    private var searched: String?
    private var resolving: Task<Void, Never>?

    private init() {}

    var hasSearched: Bool { searched != nil && query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var isAdded: Bool { selected.map { FundStore.shared.contains($0.symbol) } ?? false }

    var canCommit: Bool {
        if isAdded { return true }
        if case .ready = phase { return true }
        return false
    }

    /// Yahoo's search, after a pause in the typing when `debounce`.
    func search(debounce: Bool) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            searched = nil
            searching = false
            return
        }
        guard text != searched else { return }
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        searching = true
        let found = await FundStore.search(text)
        searching = false
        guard !Task.isCancelled else { return }
        results = Array(found.prefix(8))
        searched = text
    }

    /// Picks a result and loads its holdings, unless it is in the sidebar already.
    func select(_ result: FundSearchResult) {
        guard selected != result else { return }
        selected = result
        resolving?.cancel()
        guard !FundStore.shared.contains(result.symbol) else {
            phase = .idle
            return
        }
        phase = .loading(tr("Henter beholdning…", "Loading holdings…"))
        resolving = Task { [weak self] in
            do {
                let loaded = try await FundStore.shared.resolve(result.fund) { text in
                    guard let self, self.selected == result, !Task.isCancelled else { return }
                    self.phase = .loading(text)
                }
                guard let self, !Task.isCancelled, self.selected == result else { return }
                self.phase = .ready(loaded)
            } catch {
                guard let self, !Task.isCancelled, self.selected == result else { return }
                switch error {
                case FundError.notEquity, FundError.swap: self.phase = .failed(error.localizedDescription)
                default: self.phase = .failed(nil)
                }
            }
        }
    }

    /// Return in the search field. With a fund picked and its holdings
    /// loaded it adds the fund. With nothing picked it picks the first
    /// result — searching at once, without the typing pause, if the results
    /// for what was typed are not in yet, so a quick Return is not lost.
    /// While the holdings are loading it does nothing: the fund isn't ready.
    func submit() async {
        if canCommit {
            commit()
            return
        }
        guard selected == nil else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        if text != searched { await search(debounce: false) }
        guard selected == nil, query.trimmingCharacters(in: .whitespaces) == text,
              let first = results.first else { return }
        select(first)
    }

    /// Waits for the picked fund's holdings (snapshot mode).
    func waitForHoldings() async {
        await resolving?.value
    }

    /// Adds the picked fund with the holdings just loaded, and opens it.
    func commit() {
        guard let selected, canCommit else { return }
        let funds = FundStore.shared
        if case .ready(let loaded) = phase { funds.add(selected.fund, holdings: loaded) }
        let app = AppState.shared
        app.indexID = selected.fund.id
        app.tab = .map
        app.dialog = nil
        reset()
    }

    /// Back to an empty dialog. A load still running finishes in the
    /// background (its name lookups are cached) but is ignored.
    func reset() {
        resolving?.cancel()
        resolving = nil
        query = ""
        results = []
        searching = false
        selected = nil
        phase = .idle
        searched = nil
    }
}
