import AppKit
import StockmoteShared
import Foundation

/// En app der kan åbne et https-link.
struct Browser: Identifiable {
    /// Bundle-id, fx "com.apple.Safari". Det er nøglen vi gemmer.
    let id: String
    let name: String
    let appURL: URL
    let isSystemDefault: Bool

    /// Appens eget ikon, hentet fra disken. Det slås op én gang ved refresh og
    /// gemmes her — ikke i hver render af menuen.
    let icon: NSImage
}

// NSImage er ikke Hashable, så identiteten hænger på bundle-id'et.
extension Browser: Hashable {
    static func == (lhs: Browser, rhs: Browser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Holder styr på hvilken browser aktiesiderne åbnes i.
///
/// Samme løsning som i DRmote: nogle browsere (fx Mullvad Browser) åbner ikke
/// alle links ordentligt, og er de systemets standard, ville et klik på en
/// aktie bare fejle uden at man kunne gøre noget.
@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    /// Apps som macOS rapporterer kan åbne https. Listen filtreres ikke: det er
    /// systemets eget svar, og et forsøg på at gætte "rigtige browsere" fra
    /// Info.plist rammer forbi (Parallels Desktop registrerer fx både http og
    /// https, præcis som browserne gør).
    @Published private(set) var available: [Browser] = []

    /// nil betyder "systemets standardbrowser".
    @Published var selectedID: String? {
        didSet {
            if let selectedID {
                defaults.set(selectedID, forKey: Keys.browser)
            } else {
                defaults.removeObject(forKey: Keys.browser)
            }
        }
    }

    private enum Keys {
        static let browser = "guideBrowserBundleID"
    }

    private let defaults = AppDefaults.store
    private static let probe = URL(string: "https://finance.yahoo.com")!

    private init() {
        selectedID = defaults.string(forKey: Keys.browser)
        refresh()
    }

    /// Den valgte browser, eller nil hvis vi bruger systemets standard — eller
    /// hvis den valgte er blevet afinstalleret siden sidst.
    var selected: Browser? {
        guard let selectedID else { return nil }
        return available.first { $0.id == selectedID }
    }

    var selectedName: String {
        selected?.name ?? available.first(where: \.isSystemDefault)?.name ?? "standardbrowser"
    }

    func refresh() {
        let workspace = NSWorkspace.shared
        let defaultID = workspace.urlForApplication(toOpen: Self.probe)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }

        available = workspace.urlsForApplications(toOpen: Self.probe)
            .compactMap { url -> Browser? in
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let icon = workspace.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                return Browser(
                    id: id, name: name, appURL: url,
                    isSystemDefault: id == defaultID, icon: icon
                )
            }
            // Standardbrowseren først, resten alfabetisk.
            .sorted {
                if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Åbner linket i den valgte browser. Fejler den — fx fordi appen er væk —
    /// falder vi tilbage på systemets standard, så knappen aldrig gør ingenting.
    func open(_ url: URL) {
        guard let browser = selected else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: browser.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    }
}
