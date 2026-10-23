// make-icon.swift — renders the LyricPill app icon with AppKit and writes an .icns.
//
//     swift scripts/make-icon.swift app/AppIcon.icns [--png app/AppIcon-512.png]
//
// AppKit/CoreGraphics/CoreText plus /usr/bin/iconutil only. The generated
// app/AppIcon.icns is committed, so the build never depends on this script.
//
// The icon: Apple's rounded-rect plate (80% of the canvas, corner radius 22.5%)
// in dark charcoal, with the app's pill — a translucent white capsule with a
// crisp white stroke — carrying a ♫ glyph. Flat, no text.

import AppKit
import CoreText

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var pngPath: String? = nil
if let i = arguments.firstIndex(of: "--png"), i + 1 < arguments.count {
    pngPath = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
}
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.icns> [--png <out.png>]\n".utf8))
    exit(2)
}
let icnsURL = URL(fileURLWithPath: arguments[0])

// MARK: - Drawing

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

/// Draws the icon into `canvas` (square); every measure is proportional to its side.
func drawIcon(in canvas: NSRect) {
    let s = canvas.width
    canvas.fill(using: .clear)

    // Plate on the macOS icon grid: 80% of the canvas, radius 22.5% of the side.
    let plate = canvas.insetBy(dx: s * 0.10, dy: s * 0.10)
    let plateRadius = plate.width * 0.225
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

    // Soft drop shadow, like every stock macOS icon.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    rgb(0x1C1C21).setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Charcoal vertical gradient (top → bottom).
    NSGradient(starting: rgb(0x26262C), ending: rgb(0x121216))!.draw(in: platePath, angle: -90)

    // Subtle highlight over the top half.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    let highlight = NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2)
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.09))!
        .draw(in: highlight, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // The pill: translucent white capsule with a crisp stroke — what the app shows on screen.
    let pillSize = NSSize(width: s * 0.60, height: s * 0.26)
    let pill = NSRect(x: canvas.midX - pillSize.width / 2, y: canvas.midY - pillSize.height / 2,
                      width: pillSize.width, height: pillSize.height)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
    NSColor.white.withAlphaComponent(0.55).setFill()
    pillPath.fill()
    pillPath.lineWidth = max(s * 0.011, 1)
    NSColor.white.setStroke()
    pillPath.stroke()

    // ♫ centred on its ink bounds (font metrics centre symbol glyphs poorly).
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    let font = NSFont.systemFont(ofSize: pill.height * 0.72, weight: .bold)
    let glyph = NSAttributedString(string: "♫", attributes: [.font: font, .foregroundColor: rgb(0x121216)])
    let line = CTLineCreateWithAttributedString(glyph)
    let ink = CTLineGetImageBounds(line, cg)
    cg.saveGState()
    cg.textPosition = CGPoint(x: pill.midX - ink.midX, y: pill.midY - ink.midY)
    CTLineDraw(line, cg)
    cg.restoreGState()
}

/// Renders the icon natively at `pixels` × `pixels`.
func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    drawIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

// MARK: - Iconset → icns

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    let fm = FileManager.default
    let iconsetURL = icnsURL.deletingPathExtension().appendingPathExtension("iconset")
    try? fm.removeItem(at: iconsetURL)
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    for entry in sizes {
        try writePNG(render(pixels: entry.pixels), to: iconsetURL.appendingPathComponent(entry.name + ".png"))
    }
    if let pngPath {
        try writePNG(render(pixels: 512), to: URL(fileURLWithPath: pngPath))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
        exit(1)
    }
    try? fm.removeItem(at: iconsetURL)
    print("wrote \(icnsURL.path)")
    if let pngPath { print("wrote \(pngPath)") }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
