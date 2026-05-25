// Generator ikony aplikacji (1024x1024 PNG). Uruchom: swift tools/make_icon.swift <out.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Nie udało się utworzyć bitmapy") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.set()
canvas.fill()

// Squircle (kształt ikony macOS) z marginesem i delikatnym cieniem.
let inset: CGFloat = 100
let rect = canvas.insetBy(dx: inset, dy: inset)
let radius: CGFloat = rect.width * 0.2237
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()

// Gradient tła.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.92, alpha: 1.0),
    NSColor(calibratedRed: 0.20, green: 0.46, blue: 0.96, alpha: 1.0),
])!
gradient.draw(in: shape, angle: -90)

// Wyłącz cień przed rysowaniem glifu.
NSShadow().set()

// Glif waveform (SF Symbol) wyśrodkowany, w bieli.
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    if let glyph = symbol.withSymbolConfiguration(config) {
        glyph.isTemplate = true
        let gsize = glyph.size
        let origin = NSPoint(x: (CGFloat(size) - gsize.width) / 2,
                             y: (CGFloat(size) - gsize.height) / 2)
        let drawRect = NSRect(origin: origin, size: gsize)

        let tinted = NSImage(size: gsize)
        tinted.lockFocus()
        glyph.draw(in: NSRect(origin: .zero, size: gsize))
        NSColor.white.set()
        NSRect(origin: .zero, size: gsize).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: drawRect)
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("Nie udało się wyeksportować PNG")
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("Zapisano: \(outPath)")
