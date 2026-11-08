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
                        case .search:
                            // The results get what is left of the window's
                            // height, so the dialog fits the smallest window too.
                            SearchDialog(listHeight: max(150, min(420, geometry.size.height - 190)))
                        case .newWatchlist(let symbols):
                            NewWatchlistDialog(symbols: symbols)
                        case .renameWatchlist(let id):
                            RenameWatchlistDialog(id: id)
                        }
                    }
                    .frame(width: min(dialog == .search ? 580 : 440, geometry.size.width - 48))
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
            // From the search the new, empty list is shown; from the map's
            // context menu or a stock page the user stays where they are.
            if symbols.isEmpty {
                app.openWatchlist(id)
            } else {
                app.watchlistID = id
                app.show(tr("\(name) er oprettet", "\(name) was created"))
            }
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

/// The fund half of the search dialog: fund results, the picked fund and its holdings.
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

    /// Picks a result and loads its holdings, unless it has been added already.
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
        let added = !funds.contains(selected.symbol)
        if case .ready(let loaded) = phase { funds.add(selected.fund, holdings: loaded) }
        let app = AppState.shared
        app.dialog = nil
        app.openIndex(selected.fund.id)
        if added {
            app.show(tr("\(selected.fund.displaySymbol) er tilføjet under Mine", "\(selected.fund.displaySymbol) was added under Mine"))
        }
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
