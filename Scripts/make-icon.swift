#!/usr/bin/env swift
// make-icon.swift — draws the app icon as an .iconset folder.
//
// Run via Scripts/make-icon.sh. The icon is drawn in code rather than kept as
// a binary file, so it can be tweaked and regenerated.
//
// The motif is a small heatmap: one large green tile, a medium red one and a
// row of smaller ones going both ways, on a black squircle — the app's map in
// miniature.

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

/// macOS icons have a squircle silhouette with space around it. Apple uses about
/// 824/1024 for the artwork; the rest is transparent margin.
let contentRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.0 / 824.0

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let green = color(0x30cc5a)
let midGreen = color(0x2f9e4f)
let dimGreen = color(0x35764e)
let neutral = color(0x414554)
let dimRed = color(0x8b444e)
let midRed = color(0xbf4045)
let red = color(0xf63538)

/// Tiles in the unit square (0…1, y pointing down) with a colour.
let tiles: [(CGRect, NSColor)] = [
    (CGRect(x: 0.00, y: 0.00, width: 0.56, height: 0.58), green),
    (CGRect(x: 0.56, y: 0.00, width: 0.44, height: 0.34), midRed),
    (CGRect(x: 0.56, y: 0.34, width: 0.24, height: 0.24), dimGreen),
    (CGRect(x: 0.80, y: 0.34, width: 0.20, height: 0.24), red),
    (CGRect(x: 0.00, y: 0.58, width: 0.34, height: 0.42), dimRed),
    (CGRect(x: 0.34, y: 0.58, width: 0.30, height: 0.24), midGreen),
    (CGRect(x: 0.34, y: 0.82, width: 0.30, height: 0.18), neutral),
    (CGRect(x: 0.64, y: 0.58, width: 0.20, height: 0.42), green),
    (CGRect(x: 0.84, y: 0.58, width: 0.16, height: 0.20), midRed),
    (CGRect(x: 0.84, y: 0.78, width: 0.16, height: 0.22), dimGreen),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current else { return image }
    ctx.imageInterpolation = .high

    let content = size * contentRatio
    let inset = (size - content) / 2
    let rect = NSRect(x: inset, y: inset, width: content, height: content)
    let radius = content * cornerRatio

    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color(0x0b0b0d).setFill()
    squircle.fill()
    squircle.addClip()

    // The tiles fill the squircle with a thin black gap — as in the app.
    let gap = max(content * 0.018, 1)
    for (unit, fill) in tiles {
        let frame = NSRect(
            x: rect.minX + unit.minX * content + gap / 2,
            y: rect.maxY - unit.maxY * content + gap / 2,
            width: unit.width * content - gap,
            height: unit.height * content - gap
        )
        fill.setFill()
        NSBezierPath(rect: frame).fill()
    }

    // Soft light at the top, so the surface doesn't look completely flat.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // Up arrow in the big green tile: numbers going up.
    if size >= 64 {
        let big = tiles[0].0
        let center = NSPoint(x: rect.minX + big.midX * content, y: rect.maxY - big.midY * content)
        let unit = content / 100
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center.x, y: center.y + unit * 15))
        arrow.line(to: NSPoint(x: center.x + unit * 14, y: center.y))
        arrow.line(to: NSPoint(x: center.x + unit * 5, y: center.y))
        arrow.line(to: NSPoint(x: center.x + unit * 5, y: center.y - unit * 14))
        arrow.line(to: NSPoint(x: center.x - unit * 5, y: center.y - unit * 14))
        arrow.line(to: NSPoint(x: center.x - unit * 5, y: center.y))
        arrow.line(to: NSPoint(x: center.x - unit * 14, y: center.y))
        arrow.close()
        NSColor.white.withAlphaComponent(0.95).setFill()
        arrow.fill()
    }
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = png(drawIcon(size: CGFloat(pixels)), pixels: pixels) else { continue }
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
print("Skrev \(iconset.path)")
