import AppKit
import StockmoteShared
import SwiftUI

/// Indstillinger som Systemindstillinger: én kolonne, grupper af rækker,
/// teksten til venstre og kontrollen til højre. Ingen forklaringer under hver
/// række — det der kræver en forklaring, har den i en tooltip på ⓘ.
struct SettingsTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var universe = UniverseStore.shared
    @ObservedObject private var browsers = BrowserStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: tr("Udseende", "Appearance")) {
                    Row(tr("Tema", "Theme")) {
                        Picker("", selection: $prefs.theme) {
                            ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Farver", "Colors"), help: tr("Orange / blå er lettere at skelne ved rød-grøn farveblindhed.",
                                                          "Orange / blue is easier to tell apart with red–green colour blindness.")) {
                        HStack(spacing: 10) {
                            Swatches(style: prefs.colorStyle)
                            Picker("", selection: $prefs.colorStyle) {
                                ForEach(ColorStyle.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Panelstørrelse", "Panel size")) {
                        Picker("", selection: $prefs.panelSize) {
                            ForEach(PanelSize.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Sprog", "Language")) {
                        Picker("", selection: $prefs.language) {
                            ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                    }
                }

                SettingsGroup(title: tr("Menubar", "Menu bar")) {
                    Row(tr("Vis ved ikonet", "Show next to icon")) {
                        Picker("", selection: $prefs.menuBarIndexID) {
                            Text(tr("Kun ikon", "Icon only")).tag(String?.none)
                            ForEach(universe.indices) { Text($0.title).tag(String?.some($0.id)) }
                            ForEach(FundStore.shared.indices) { Text($0.title).tag(String?.some($0.id)) }
                        }
                        .fixedSize()
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Start ved login", "Open at login"), help: prefs.launchAtLoginError) {
                        Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                    }
                }

                SettingsGroup(title: tr("Kort og lister", "Map and lists")) {
                    Row(tr("Store selskaber fylder mest i lister", "Size list tiles by market value"),
                        help: tr("Favoritter og watchlister. Slået fra er alle felter lige store.",
                                 "Favorites and watchlists. Off makes every tile the same size.")) {
                        Toggle("", isOn: $prefs.listsByMarketCap)
                            .toggleStyle(.switch)
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Opdatér mens panelet er åbent", "Refresh while open"),
                        help: tr("Når børsen er åben. Ellers hvert 5. minut, og hver halve time når alt er lukket.",
                                 "While the market is open. Otherwise every 5 minutes, and every 30 when all are closed.")) {
                        Picker("", selection: $prefs.refreshSeconds) {
                            Text(tr("Hvert 30. sek.", "Every 30 s")).tag(30)
                            Text(tr("Hvert minut", "Every minute")).tag(60)
                            Text(tr("Hvert 2. min.", "Every 2 min")).tag(120)
                            Text(tr("Hvert 5. min.", "Every 5 min")).tag(300)
                        }
                        .fixedSize()
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Åbn aktier på", "Open stocks on")) {
                        Picker("", selection: $prefs.quoteSite) {
                            ForEach(QuoteSite.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                    }
                    Divider().padding(.leading, 12)
                    Row(tr("Browser", "Browser"), help: tr("Ikke alle browsere kan åbne alle links.", "Not every browser opens every link.")) {
                        Picker("", selection: $browsers.selectedID) {
                            Text(tr("Systemets standard", "System default")).tag(String?.none)
                            ForEach(browsers.available) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .fixedSize()
                    }
                }

                Footer()
            }
            .labelsHidden()
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .onAppear { browsers.refresh() }
    }
}

/// En gruppe rækker med en lille overskrift over.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.outline, lineWidth: 0.5))
        }
    }
}

private struct Row<Control: View>: View {
    let title: String
    let help: String?
    @ViewBuilder let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let help {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .help(help)
                }
            }
            Spacer(minLength: 8)
            control
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }
}

/// Fem små felter der viser skalaen i den valgte farve.
private struct Swatches: View {
    let style: ColorStyle
    @Environment(\.heatTheme) private var theme

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach([-3.0, -1.5, 0, 1.5, 3.0], id: \.self) { value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Heat.color(value, scale: 3, style: style, theme: theme))
                    .frame(width: 9, height: 14)
            }
        }
    }
}

private struct Footer: View {
    @ObservedObject private var universe = UniverseStore.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(tr("Kurser fra Yahoo Finance og Nasdaq, kan være forsinkede. Ikke investeringsrådgivning.",
                    "Quotes from Yahoo Finance and Nasdaq, may be delayed. Not investment advice."))
                .multilineTextAlignment(.center)
            Text(tr("Indekslister fra \(universe.updated ?? "–") · \(universe.indices.count) indekser",
                    "Index lists from \(universe.updated ?? "–") · \(universe.indices.count) indices"))
                .foregroundStyle(.tertiary)
            HStack(spacing: 14) {
                Button(tr("Om Stockmote", "About Stockmote")) { showAbout() }
                Button(tr("Genindlæs lister", "Reload lists")) { universe.load() }
                Button(tr("Vis data i Finder", "Show data in Finder")) { revealOverride() }
                    .help(tr("Læg din egen Indices.json her for at overstyre den indbyggede.",
                             "Put your own Indices.json here to override the built-in one."))
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func revealOverride() {
        let url = UniverseStore.userOverrideURL
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}

@MainActor
func showAbout() {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let alert = NSAlert()
    alert.messageText = version.map { "Stockmote \($0)" } ?? "Stockmote"
    alert.informativeText = tr("""
        Heatmap over amerikanske og europæiske aktieindekser i menubaren.

        Feltets størrelse er markedsværdien, farven er ændringen i det valgte \
        tidsrum. Klik på en sektor eller branche for at gå ind i den; klik på \
        en aktie for at åbne den i browseren. Knib for at zoome, ⌃⌘F for fuld skærm.

        Kurser fra Yahoo Finance og Nasdaq, hentet uden API-nøgle. De kan være \
        forsinkede, og de kan holde op med at virke uden varsel.

        Ikke investeringsrådgivning. Ingen analytics og ingen sporing.
        """, """
        A heatmap of US and European stock indices in the menu bar.

        Tile size is market value, colour is the change over the chosen \
        range. Click a sector or industry to go into it; click a stock to \
        open it in the browser. Pinch to zoom, ⌃⌘F for full screen.

        Quotes from Yahoo Finance and Nasdaq, fetched without an API key. They \
        can be delayed and can stop working without notice.

        Not investment advice. No analytics and no tracking.
        """)
    alert.alertStyle = .informational
    alert.addButton(withTitle: tr("Luk", "Close"))
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
