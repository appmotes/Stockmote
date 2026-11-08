import StockmoteShared
import SwiftUI

/// The stock page (placeholder until the full page lands).
struct StockPage: View {
    let symbol: String
    var body: some View {
        Button("Open") { Preferences.shared.openQuote(symbol) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum StockPeers {
    static func symbols(for symbol: String) -> [String] { [] }
}

@MainActor
final class StockChartStore {
    static let shared = StockChartStore()
    func waitForLoad(_ symbol: String, period: Period) async {}
}
