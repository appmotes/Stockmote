import AppKit
import StockmoteShared
import ServiceManagement
import SwiftUI

enum PanelSize: String, CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return tr("Lille", "Small")
        case .medium: return tr("Mellem", "Medium")
        case .large: return tr("Stor", "Large")
        case .huge: return tr("Kæmpe", "Huge")
        }
    }

    var size: CGSize {
        switch self {
        // Wider than before: the sidebar takes ~190 pt.
        case .small: return CGSize(width: 720, height: 480)
        case .medium: return CGSize(width: 940, height: 600)
        case .large: return CGSize(width: 1140, height: 720)
        case .huge: return CGSize(width: 1400, height: 860)
        }
    }
}

/// Where a stock opens when you click it.
enum QuoteSite: String, CaseIterable, Identifiable {
    case yahoo, google, nasdaq, finviz
    var id: String { rawValue }

    var label: String {
        switch self {
        case .yahoo: return "Yahoo Finance"
        case .google: return "Google Finance"
        case .nasdaq: return "Nasdaq"
        case .finviz: return "Finviz"
        }
    }

    func url(for symbol: String) -> URL? {
        let dash = Symbols.yahoo(symbol)
        // Nasdaq and Finviz only know US stocks.
        if Symbols.isForeign(symbol), self == .nasdaq || self == .finviz {
            return QuoteSite.yahoo.url(for: symbol)
        }
        switch self {
        case .yahoo: return URL(string: "https://finance.yahoo.com/quote/\(dash)")
        // Google wants the exchange in the URL ("AAPL:NASDAQ"), and we don't
        // know it. The search lands on the same page.
        case .google: return URL(string: "https://www.google.com/finance?q=\(dash)")
        case .nasdaq:
            return URL(string: "https://www.nasdaq.com/market-activity/stocks/\(symbol.lowercased().replacingOccurrences(of: ".", with: "/"))")
        case .finviz: return URL(string: "https://finviz.com/quote.ashx?t=\(dash)")
        }
    }
}

/// Settings. Everything is stored in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var panelSize: PanelSize { didSet { defaults.set(panelSize.rawValue, forKey: "panelSize") } }
    @Published var quoteSite: QuoteSite { didSet { defaults.set(quoteSite.rawValue, forKey: "quoteSite") } }
    @Published var colorStyle: ColorStyle { didSet { defaults.set(colorStyle.rawValue, forKey: "colorStyle") } }
    @Published var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            Lang.isEnglish = language.isEnglish
        }
    }
    @Published var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "sidebarVisible") } }
    /// The index whose figure is shown in the menu bar. nil = icon only.
    @Published var menuBarIndexID: String? {
        didSet { defaults.set(menuBarIndexID ?? "none", forKey: "menuBarIndex") }
    }
    /// Seconds between refreshes while the panel is open and the market is open.
    @Published var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    /// Favourites and watchlists: equal tiles, or sized by market cap.
    @Published var listsByMarketCap: Bool { didSet { defaults.set(listsByMarketCap, forKey: "listsByMarketCap") } }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults = AppDefaults.store

    private init() {
        panelSize = PanelSize(rawValue: defaults.string(forKey: "panelSize") ?? "") ?? .medium
        quoteSite = QuoteSite(rawValue: defaults.string(forKey: "quoteSite") ?? "") ?? .yahoo
        colorStyle = ColorStyle(rawValue: defaults.string(forKey: "colorStyle") ?? "") ?? .redGreen
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .danish
        sidebarVisible = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
        let menuBar = defaults.string(forKey: "menuBarIndex") ?? "sp500"
        menuBarIndexID = menuBar == "none" ? nil : menuBar
        let seconds = defaults.integer(forKey: "refreshSeconds")
        refreshSeconds = seconds > 0 ? seconds : 60
        listsByMarketCap = defaults.bool(forKey: "listsByMarketCap")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Lang.isEnglish = language.isEnglish
    }

    /// Appearance for the panel's NSHostingView. nil follows the system.
    var appearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Requires the app to run from an .app bundle — not from `swift run`.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = Bundle.main.bundleURL.pathExtension == "app"
                ? error.localizedDescription
                : tr("Virker kun fra Stockmote.app — ikke fra swift run.", "Only works from Stockmote.app — not from swift run.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openQuote(_ symbol: String) {
        guard let url = quoteSite.url(for: symbol) else { return }
        BrowserStore.shared.open(url)
    }
}

/// Where settings are stored. In snapshot mode (`--snapshot`) a separate
/// domain is used, so a picture of "Nasdaq 100, 1M, small panel" doesn't
/// change what the app itself shows next time.
enum AppDefaults {
    static let store: UserDefaults = {
        guard CommandLine.arguments.contains("--snapshot") else { return .standard }
        let name = "dk.stockmote.snapshot"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
}
