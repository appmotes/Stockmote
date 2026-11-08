import CoreGraphics
import Foundation

/// What the map shows: the whole index, one sector or one industry.
public enum Focus: Hashable {
    case all
    case sector(String)
    case industry(sector: String, industry: String)

    public var parent: Focus? {
        switch self {
        case .all: return nil
        case .sector: return .all
        case .industry(let sector, _): return .sector(sector)
        }
    }

    public var title: String? {
        switch self {
        case .all: return nil
        case .sector(let name): return name
        case .industry(_, let name): return name
        }
    }
}

/// One tile, ready for the map: a stock — or, in a list, a fund or an index
/// shown with its own change.
public struct HeatItem {
    /// The symbol whose price the tile shows: a stock, a fund's own symbol
    /// or an index's benchmark ("^GSPC").
    public let symbol: String
    public let name: String
    public let sector: String
    public let industry: String
    public let weight: Double
    public let change: Double?
    /// What the tile says instead of the symbol ("S&P 500", "VWCE").
    public let label: String?
    /// A list's fund or index: "fund:VWCE.DE" or "index:sp500". Nil for a stock.
    public let ref: String?
    /// The change is the customary indicative value of a NAV fund (≈).
    public let isEstimate: Bool

    public init(symbol: String, name: String, sector: String, industry: String,
                weight: Double, change: Double?, label: String? = nil, ref: String? = nil,
                isEstimate: Bool = false) {
        self.symbol = symbol
        self.name = name
        self.sector = sector
        self.industry = industry
        self.weight = weight
        self.change = change
        self.label = label
        self.ref = ref
        self.isEstimate = isEstimate
    }

    /// The text on the tile: the label, or the symbol as people write it.
    public var title: String { label ?? Symbols.display(symbol) }

    /// "+1.23%", "≈ +1.23%" or "–".
    public var percentText: String {
        (isEstimate && change != nil ? "≈ " : "") + Format.percent(change)
    }
}

public struct Tile {
    public let item: HeatItem
    public let rect: CGRect
}

/// A sector or industry box. `header` is the strip with the name, which is also
/// what you click to drill into it.
public struct HeatGroup {
    public let name: String
    public let rect: CGRect
    public let header: CGRect?
    public let focus: Focus
    public let change: Double?
}

public struct HeatmapLayout: Equatable {
    public let id = UUID()
    public let size: CGSize
    public var tiles: [Tile] = []
    public var sectors: [HeatGroup] = []
    public var industries: [HeatGroup] = []

    public init(size: CGSize) { self.size = size }

    public static func == (lhs: HeatmapLayout, rhs: HeatmapLayout) -> Bool { lhs.id == rhs.id }

    public static let empty = HeatmapLayout(size: .zero)

    public func tile(at point: CGPoint) -> Tile? {
        tiles.first { $0.rect.contains(point) }
    }

    public func header(at point: CGPoint) -> HeatGroup? {
        industries.first { $0.header?.contains(point) == true }
            ?? sectors.first { $0.header?.contains(point) == true }
    }
}

public enum Grouping {
    /// Sector → industry → stock, like the index map.
    case sectors
    /// Just the tiles, all side by side, like a list.
    case flat
}

/// Builds the map as a squarified treemap (Bruls, Huizing & van Wijk): tiles
/// are laid out in rows kept as close to square as possible, so both large and
/// small stocks are readable.
public enum TreemapBuilder {
    public static func build(items: [HeatItem], grouping: Grouping, focus: Focus, size: CGSize) -> HeatmapLayout {
        var layout = HeatmapLayout(size: size)
        let rect = CGRect(origin: .zero, size: size)
        guard size.width > 4, size.height > 4 else { return layout }

        let visible = items.filter { item in
            switch focus {
            case .all: return true
            case .sector(let sector): return item.sector == sector
            case .industry(let sector, let industry): return item.sector == sector && item.industry == industry
            }
        }.filter { $0.weight > 0 }

        switch (grouping, focus) {
        case (.flat, _), (.sectors, .industry):
            layoutStocks(visible, in: rect, into: &layout)
        case (.sectors, .sector(let sector)):
            layoutIndustries(visible, sector: sector, in: rect, headerHeight: 16, into: &layout)
        case (.sectors, .all):
            layoutSectors(visible, in: rect, into: &layout)
        }
        return layout
    }

    private static func layoutSectors(_ items: [HeatItem], in rect: CGRect, into layout: inout HeatmapLayout) {
        let groups = grouped(items, by: \.sector)
        let rects = squarify(groups.map(\.weight), in: rect)
        for (group, frame) in zip(groups, rects) {
            // 2 pt of black space between sectors.
            let box = frame.insetBy(dx: 1, dy: 1)
            guard box.width > 1, box.height > 1 else { continue }
            var inner = box
            var header: CGRect?
            if box.height > 40, box.width > 50 {
                let height = min(18, max(13, box.height * 0.06))
                header = CGRect(x: box.minX, y: box.minY, width: box.width, height: height)
                inner = CGRect(x: box.minX, y: box.minY + height, width: box.width, height: box.height - height)
            }
            layout.sectors.append(HeatGroup(name: group.name, rect: box, header: header,
                                           focus: .sector(group.name), change: group.change))
            layoutIndustries(group.items, sector: group.name, in: inner, headerHeight: 13, into: &layout)
        }
    }

    private static func layoutIndustries(_ items: [HeatItem], sector: String, in rect: CGRect,
                                         headerHeight: CGFloat, into layout: inout HeatmapLayout) {
        let groups = grouped(items, by: \.industry)
        let rects = squarify(groups.map(\.weight), in: rect)
        for (group, frame) in zip(groups, rects) {
            let box = frame.insetBy(dx: 0.5, dy: 0.5)
            guard box.width > 1, box.height > 1 else { continue }
            var inner = box
            var header: CGRect?
            if box.width > 46, box.height > headerHeight * 2.8 {
                header = CGRect(x: box.minX, y: box.minY, width: box.width, height: headerHeight)
                inner = CGRect(x: box.minX, y: box.minY + headerHeight, width: box.width, height: box.height - headerHeight)
            }
            layout.industries.append(HeatGroup(name: group.name, rect: box, header: header,
                                              focus: .industry(sector: sector, industry: group.name),
                                              change: group.change))
            layoutStocks(group.items, in: inner, into: &layout)
        }
    }

    private static func layoutStocks(_ items: [HeatItem], in rect: CGRect, into layout: inout HeatmapLayout) {
        let sorted = items.sorted { $0.weight > $1.weight }
        let rects = squarify(sorted.map(\.weight), in: rect)
        for (item, frame) in zip(sorted, rects) where frame.width > 0.5 && frame.height > 0.5 {
            layout.tiles.append(Tile(item: item, rect: frame))
        }
    }

    private struct Group {
        let name: String
        let items: [HeatItem]
        let weight: Double
        /// Weighted average — shown in the tooltip for sector and industry.
        let change: Double?
    }

    private static func grouped(_ items: [HeatItem], by key: KeyPath<HeatItem, String>) -> [Group] {
        Dictionary(grouping: items, by: { $0[keyPath: key] })
            .map { name, items in
                let weight = items.reduce(0) { $0 + $1.weight }
                let known = items.filter { $0.change != nil }
                let knownWeight = known.reduce(0) { $0 + $1.weight }
                let change = knownWeight > 0
                    ? known.reduce(0) { $0 + $1.change! * $1.weight } / knownWeight : nil
                return Group(name: name, items: items, weight: weight, change: change)
            }
            .sorted { $0.weight > $1.weight }
    }

    /// Squarified treemap. Values must be sorted in descending order.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = areas[start]
            var current = worst(sum: rowSum, max: areas[start], min: areas[start], side: side)
            while end < areas.count {
                let sum = rowSum + areas[end]
                let rowMax = areas[start]                 // sorted descending
                let candidate = worst(sum: sum, max: rowMax, min: areas[end], side: side)
                guard candidate <= current else { break }
                current = candidate
                rowSum = sum
                end += 1
            }

            // The last row takes the rest, so rounding errors don't leave a
            // thin black stripe at the edge.
            let isLast = end == areas.count
            if remaining.width >= remaining.height {
                let width = isLast ? remaining.width : CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for index in start..<end {
                    let height = isLast && index == end - 1
                        ? remaining.maxY - y
                        : CGFloat(areas[index] / Double(width))
                    result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = isLast ? remaining.height : CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for index in start..<end {
                    let width = isLast && index == end - 1
                        ? remaining.maxX - x
                        : CGFloat(areas[index] / Double(height))
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
            start = end
        }
        return result
    }

    private static func worst(sum: Double, max: Double, min: Double, side: Double) -> Double {
        guard sum > 0, min > 0, side > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }
}
