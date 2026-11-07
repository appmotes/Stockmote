import SwiftUI

// MARK: - Tegning

/// Felterne tegnet i én Canvas — bruges af både panelet, fuldskærm og widget'en.
///
/// Equatable, så hover — som ændrer sig ved hver musebevægelse — ikke tegner
/// alle felter igen. Kun layout, panorering, farver og tema gør.
public struct HeatmapCanvas: View, Equatable {
    let layout: HeatmapLayout
    let offset: CGPoint
    let period: Period
    let style: ColorStyle
    let theme: Theme

    public init(layout: HeatmapLayout, offset: CGPoint = .zero, period: Period, style: ColorStyle, theme: Theme) {
        self.layout = layout
        self.offset = offset
        self.period = period
        self.style = style
        self.theme = theme
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.gap))
            context.translateBy(x: -offset.x, y: -offset.y)
            let visible = CGRect(origin: offset, size: size)
            let scale = period.colorScale

            for tile in layout.tiles where tile.rect.intersects(visible) {
                let rect = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                guard rect.width > 0, rect.height > 0 else { continue }
                context.fill(Path(rect), with: .color(Heat.color(tile.item.change, scale: scale, style: style, theme: theme)))
                // Når der er zoomet ind, centreres teksten i den synlige del af
                // feltet, så et stort felt ikke kun viser halve bogstaver.
                let ink = Heat.label(on: tile.item.change, scale: scale, style: style, theme: theme)
                Self.drawLabel(in: &context, tile: tile, rect: rect.intersection(visible), ink: ink)
            }

            for sector in layout.sectors {
                guard let header = sector.header, header.intersects(visible) else { continue }
                context.fill(Path(header), with: .color(theme.sectorHeader))
                let size = min(12.5, header.height * 0.72)
                Self.drawHeaderText(sector.name, in: header.intersection(visible), size: size, weight: .bold,
                                    color: theme.sectorText, context: &context)
            }

            for industry in layout.industries {
                guard let header = industry.header, header.intersects(visible) else { continue }
                context.fill(Path(header), with: .color(theme.industryHeader))
                let size = min(header.height > 14 ? 11 : 9.5, header.height * 0.72)
                Self.drawHeaderText(industry.name, in: header.intersection(visible), size: size, weight: .semibold,
                                    color: theme.industryText, context: &context)
            }
        }
    }

    public static func drawHeaderText(_ text: String, in rect: CGRect, size: CGFloat, weight: Font.Weight,
                                      color: Color, context: inout GraphicsContext) {
        guard rect.width > 24 else { return }
        let capacity = Int((rect.width - 8) / (size * 0.57))
        guard capacity >= 3 else { return }
        let label = text.count > capacity ? String(text.prefix(max(capacity - 1, 1))) + "…" : text
        context.draw(
            Text(label).font(.system(size: size, weight: weight)).foregroundColor(color),
            at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center
        )
    }

    /// Symbol og procent, skaleret efter feltet — store felter får store bogstaver.
    public static func drawLabel(in context: inout GraphicsContext, tile: Tile, rect: CGRect, ink: Color = .white) {
        let symbol = Symbols.display(tile.item.symbol)
        let chars = CGFloat(max(symbol.count, 3))
        let symbolSize = min(rect.width / (chars * 0.68 + 0.9), rect.height * 0.34, 60)
        guard symbolSize >= 6.5 else { return }

        let percentSize = symbolSize * 0.6
        let percent = Format.percent(tile.item.change)
        let showPercent = percentSize >= 6
            && rect.height >= symbolSize * 1.15 + percentSize * 1.3 + 2
            && rect.width >= percentSize * CGFloat(percent.count) * 0.62
        let nameSize = symbolSize * 0.3
        let showName = showPercent && nameSize >= 9 && rect.height >= symbolSize * 1.15 + percentSize * 1.3 + nameSize * 2.2

        var total = symbolSize * 1.05
        if showPercent { total += percentSize * 1.25 }
        if showName { total += nameSize * 1.6 }
        var y = rect.midY - total / 2

        context.draw(
            Text(symbol).font(.system(size: symbolSize, weight: .bold)).foregroundColor(ink),
            at: CGPoint(x: rect.midX, y: y + symbolSize * 0.55), anchor: .center
        )
        y += symbolSize * 1.05
        if showPercent {
            context.draw(
                Text(percent).font(.system(size: percentSize, weight: .medium).monospacedDigit())
                    .foregroundColor(ink.opacity(0.93)),
                at: CGPoint(x: rect.midX, y: y + percentSize * 0.62), anchor: .center
            )
            y += percentSize * 1.25
        }
        if showName {
            let capacity = Int((rect.width - 10) / (nameSize * 0.55))
            let name = tile.item.name.count > capacity ? String(tile.item.name.prefix(max(capacity - 1, 1))) + "…" : tile.item.name
            context.draw(
                Text(name).font(.system(size: nameSize, weight: .medium)).foregroundColor(ink.opacity(0.7)),
                at: CGPoint(x: rect.midX, y: y + nameSize * 1.0), anchor: .center
            )
        }

        if tile.item.isFavorite, rect.width > 34, rect.height > 26 {
            let starSize = min(max(symbolSize * 0.32, 7), 13)
            context.draw(
                Text(Image(systemName: "star.fill")).font(.system(size: starSize)).foregroundColor(.yellow),
                at: CGPoint(x: rect.maxX - starSize * 0.6 - 2, y: rect.minY + starSize * 0.6 + 2), anchor: .center
            )
        }
    }
}
