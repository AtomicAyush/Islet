// Draws Islet's app icon at 1024 × 1024 and writes the sizes the asset catalog needs.
// Run from the repository root: swift Scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "Islet/Assets.xcassets/AppIcon.appiconset")

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // Apple's macOS icon grid: an 824-point squircle centred on a 1024 canvas.
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 18 * s
        shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A dusk sky: the island reads best as a silhouette against colour.
        NSGradient(colors: [
            NSColor(red: 0.16, green: 0.32, blue: 0.78, alpha: 1),
            NSColor(red: 0.45, green: 0.30, blue: 0.80, alpha: 1),
            NSColor(red: 0.96, green: 0.55, blue: 0.42, alpha: 1),
        ])?.draw(in: squircle, angle: -90)

        // Soft glow behind the island.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])
        glow?.draw(fromCenter: NSPoint(x: 512 * s, y: 610 * s), radius: 0,
                   toCenter: NSPoint(x: 512 * s, y: 610 * s), radius: 360 * s, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // The island: a black pill, with compact content either side of the camera.
        let pill = NSRect(x: 222 * s, y: 540 * s, width: 580 * s, height: 150 * s)
        NSGraphicsContext.saveGraphicsState()
        let pillShadow = NSShadow()
        pillShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        pillShadow.shadowBlurRadius = 30 * s
        pillShadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        pillShadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 75 * s, yRadius: 75 * s).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Leading: artwork tile.
        let art = NSRect(x: 262 * s, y: 575 * s, width: 80 * s, height: 80 * s)
        NSGradient(colors: [
            NSColor(red: 1.0, green: 0.42, blue: 0.35, alpha: 1),
            NSColor(red: 0.98, green: 0.78, blue: 0.30, alpha: 1),
        ])?.draw(in: NSBezierPath(roundedRect: art, xRadius: 20 * s, yRadius: 20 * s), angle: -45)

        // Camera lens.
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 590 * s, y: 598 * s, width: 34 * s, height: 34 * s)).fill()

        // Trailing: waveform bars.
        let heights: [CGFloat] = [40, 72, 54, 86, 46]
        let accent = NSColor(red: 1.0, green: 0.66, blue: 0.40, alpha: 1)
        accent.setFill()
        for (i, h) in heights.enumerated() {
            let x = (672 + CGFloat(i) * 20) * s
            let bar = NSRect(x: x, y: 615 * s - h * s / 2, width: 11 * s, height: h * s)
            NSBezierPath(roundedRect: bar, xRadius: 5.5 * s, yRadius: 5.5 * s).fill()
        }
        return true
    }
}

func write(_ image: NSImage, pixels: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

let master = render(size: 1024)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(master, pixels: points * scale, name: name)
        images.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
    }
}
let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try json.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icon sizes to \(out.path)")
