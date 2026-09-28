// Draws the DayStack app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("DayStack.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func gray(_ v: CGFloat) -> NSColor { NSColor(white: v, alpha: 1) }

// Calendar card with a black header and a 7x5 grid of heatmap cells (light grey → black).
func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let radius = 185 * s

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        gray(0.98).setFill()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
        gray(0.11).setFill()
        NSRect(x: body.minX, y: body.maxY - 200 * s, width: body.width, height: 200 * s).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Binder rings on the header.
        gray(0.98).setFill()
        for x in [300.0, 700.0] {
            let ring = NSRect(x: (x - 22) * s, y: 790 * s, width: 44 * s, height: 90 * s)
            NSBezierPath(roundedRect: ring, xRadius: 22 * s, yRadius: 22 * s).fill()
        }

        let levels = [
            0, 1, 0, 2, 1, 0, 0,
            1, 3, 2, 0, 1, 2, 0,
            0, 2, 3, 3, 1, 0, 1,
            2, 1, 0, 2, 3, 1, 0,
            0, 3, 2, 1, 0, 0, 0,
        ]
        let fills = [gray(0.9), gray(0.72), gray(0.47), gray(0.17)]
        let cell: CGFloat = 84, gap: CGFloat = 16, left: CGFloat = 170, top: CGFloat = 664
        let today = 30
        for (i, level) in levels.enumerated() {
            let col = CGFloat(i % 7), row = CGFloat(i / 7)
            let rect = NSRect(x: (left + col * (cell + gap)) * s,
                              y: (top - (row + 1) * cell - row * gap) * s,
                              width: cell * s, height: cell * s)
            let path = NSBezierPath(roundedRect: rect, xRadius: 16 * s, yRadius: 16 * s)
            fills[level].setFill()
            path.fill()
            if i == today {
                gray(0.11).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 4 * s, dy: 4 * s), xRadius: 13 * s, yRadius: 13 * s)
                ring.lineWidth = 8 * s
                ring.stroke()
            }
        }
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

for base in [16, 32, 128, 256, 512] {
    try writePNG(draw(size: CGFloat(base)), pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(draw(size: CGFloat(base * 2)), pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(draw(size: 1024), pixels: 1024, to: root.appendingPathComponent("docs/icon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
