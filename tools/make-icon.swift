import AppKit

// Renders mutewake's app icon into an .iconset directory for `iconutil`.
// Run by install.sh at build time, so no binary icon is checked in.
//
// The glyph must stay the menu bar's symbol (StatusMenu.symbolOn), so the app
// in Finder, Launchpad, and the About panel reads as the same thing as the icon
// in the menu bar.
let symbol = "speaker.zzz.fill"

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Draws the icon at `px` pixels square, following the macOS app icon grid:
/// an 824/1024 rounded square, centered, with room for its shadow.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Dusk to night: it is the app that acts when the Mac goes to sleep.
    NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.95, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.09, blue: 0.36, alpha: 1))!
        .draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 400 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: tile.midX - g.width / 2, y: tile.midY - g.height / 2,
                              width: g.width, height: g.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The sizes iconutil expects: each point size at 1x and 2x.
for pt in [16, 32, 128, 256, 512] {
    try render(pt).write(to: out.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try render(pt * 2).write(to: out.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
