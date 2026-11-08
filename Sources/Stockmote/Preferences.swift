import AppKit
import StockmoteShared
import ServiceManagement
import SwiftUI

/// Where Stockmote shows up: in the Dock (with a window and a main menu), in
/// the menu bar, or both. There is no "neither" — the app would be
/// unreachable.
enum AppPresence: String, CaseIterable, Identifiable {
    case both, menuBarOnly, dockOnly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return tr("Dock og menubar", "Dock and menu bar")
        case .menuBarOnly: return tr("Kun menubar", "Menu bar only")
        case .dockOnly: return tr("Kun Dock", "Dock only")
        }
    }

    var showsStatusItem: Bool { self != .dockOnly }
    var showsDockIcon: Bool { self != .menuBarOnly }
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

    @Published var quoteSite: QuoteSite { didSet { defaults.set(quoteSite.rawValue, forKey: "quoteSite") } }
    @Published var colorStyle: ColorStyle { didSet { defaults.set(colorStyle.rawValue, forKey: "colorStyle") } }
    @Published var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            Lang.isEnglish = language.isEnglish
        }
    }
    /// The index whose figure is shown in the menu bar. nil = icon only.
    @Published var menuBarIndexID: String? {
        didSet { defaults.set(menuBarIndexID ?? "none", forKey: "menuBarIndex") }
    }
    /// Seconds between refreshes while the map is on screen and the market is open.
    @Published var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }

    /// Dock, menu bar or both. Applied by AppDelegate.
    @Published var presence: AppPresence { didSet { defaults.set(presence.rawValue, forKey: "presence") } }
    /// Open the main window when the app is launched by hand (not at login).
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
    /// The trading-hours band on the overview. Off unless asked for: it takes room.
    @Published var showTradingHours: Bool { didSet { defaults.set(showTradingHours, forKey: "showTradingHours") } }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults = AppDefaults.store

    private init() {
        quoteSite = QuoteSite(rawValue: defaults.string(forKey: "quoteSite") ?? "") ?? .yahoo
        colorStyle = ColorStyle(rawValue: defaults.string(forKey: "colorStyle") ?? "") ?? .redGreen
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .danish
        let menuBar = defaults.string(forKey: "menuBarIndex") ?? "sp500"
        menuBarIndexID = menuBar == "none" ? nil : menuBar
        let seconds = defaults.integer(forKey: "refreshSeconds")
        refreshSeconds = seconds > 0 ? seconds : 60
        presence = AppPresence(rawValue: defaults.string(forKey: "presence") ?? "") ?? .both
        openWindowAtLaunch = defaults.object(forKey: "openWindowAtLaunch") as? Bool ?? true
        showTradingHours = defaults.bool(forKey: "showTradingHours")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Lang.isEnglish = language.isEnglish
    }

    /// Appearance for the windows. nil follows the system.
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
/// domain is used, so a picture of "Nasdaq 100, 1M, light theme" doesn't
/// change what the app itself shows next time.
enum AppDefaults {
    /// Snapshot mode: separate settings and a separate fund cache.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    static let store: UserDefaults = {
        guard isSnapshot else { return .standard }
        let name = "dk.stockmote.snapshot"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
}
