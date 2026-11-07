import AppKit
import StockmoteShared
import Foundation

/// An app that can open an https link.
struct Browser: Identifiable {
    /// Bundle ID, e.g. "com.apple.Safari". This is the key we store.
    let id: String
    let name: String
    let appURL: URL
    let isSystemDefault: Bool

    /// The app's own icon, loaded from disk. It's looked up once on refresh and
    /// kept here — not on every render of the menu.
    let icon: NSImage
}

// NSImage isn't Hashable, so identity rests on the bundle ID.
extension Browser: Hashable {
    static func == (lhs: Browser, rhs: Browser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Keeps track of which browser stock pages open in.
///
/// Same approach as in DRmote: some browsers (e.g. Mullvad Browser) don't open
/// every link properly, and if one of them is the system default, clicking a
/// stock would simply fail with nothing you could do about it.
@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    /// Apps that macOS reports as able to open https. The list isn't filtered: it's
    /// the system's own answer, and trying to guess the "real browsers" from
    /// Info.plist misses (Parallels Desktop, for one, registers both http and
    /// https, exactly as browsers do).
    @Published private(set) var available: [Browser] = []

    /// nil means "the system default browser".
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

    /// The chosen browser, or nil if we use the system default — or if the
    /// chosen one has been uninstalled since last time.
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
            // Default browser first, the rest alphabetically.
            .sorted {
                if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Opens the link in the chosen browser. If that fails — say, the app is gone —
    /// we fall back to the system default, so the button never does nothing.
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
