import AppKit
import ImageIO
import SwiftUI

/// Cover art, decoded once at the size the island draws it, with the colour the
/// waveform borrows from it.
///
/// Unchecked `Sendable`: it is built off the main thread and handed over whole; the
/// image is never mutated after that.
struct NowPlayingArtwork: Equatable, @unchecked Sendable {
    let id = UUID()
    let image: NSImage
    /// The cover's most characteristic colour, brightened to read on black.
    let tint: Color
    /// Width over height: square for a cover, landscape for a video's thumbnail.
    let aspectRatio: CGFloat

    /// The largest artwork is a 60 pt cover or a 110 pt wide video thumbnail; this
    /// covers both at 2x.
    private static let maxPixelSize = 256

    init(_ image: CGImage) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        tint = Self.tint(of: image)
        aspectRatio = image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// Decodes the adapter's base64 image data. Slow: call it off the main thread.
    static func decode(base64: String) -> NowPlayingArtwork? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this thread, rather than on first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NowPlayingArtwork(image)
    }

    // MARK: Tint

    /// The most prominent vivid hue in a tiny rendering of the cover, or its plain
    /// average when nothing in it is really colourful, lifted to a brightness that
    /// stays visible on the island's black.
    private static func tint(of image: CGImage) -> Color {
        let side = 24
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return .white }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return .white }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var hues = [ColourSum](repeating: ColourSum(), count: 12)
        var overall = ColourSum()
        for i in 0..<(side * side) {
            let alpha = Double(pixels[i * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }
            let rgb = RGB(
                r: min(1, Double(pixels[i * 4]) / 255 / alpha),
                g: min(1, Double(pixels[i * 4 + 1]) / 255 / alpha),
                b: min(1, Double(pixels[i * 4 + 2]) / 255 / alpha)
            )
            overall.add(rgb, weight: alpha)
            let hsb = HSB(rgb)
            // Vivid, bright pixels say the most about a cover; greys say nothing.
            guard hsb.s > 0.2, hsb.b > 0.15 else { continue }
            hues[min(11, Int(hsb.h * 12))].add(rgb, weight: hsb.s * hsb.b * alpha)
        }

        let strongest = hues.max { $0.weight < $1.weight } ?? ColourSum()
        var hsb = HSB(strongest.weight > overall.weight * 0.05 ? strongest.mean : overall.mean)
        hsb.b = max(hsb.b, 0.82)
        hsb.s = min(hsb.s, 0.85)
        let rgb = hsb.rgb
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    // MARK: Samples

    /// A synthwave sunset for the previews, drawn in code so they need no bundled
    /// images.
    static let sampleSunset: NowPlayingArtwork? = drawSample(
        sky: [(0.16, 0.06, 0.34), (0.55, 0.12, 0.47), (0.95, 0.35, 0.45)],
        sun: [(1.0, 0.86, 0.35), (1.0, 0.36, 0.55)],
        sunCentre: CGPoint(x: 128, y: 120), sunRadius: 70,
        ground: (0.09, 0.04, 0.18), grid: (1.0, 0.3, 0.7)
    )

    /// A bay at dusk, for the song-change preview.
    static let sampleBay: NowPlayingArtwork? = drawSample(
        sky: [(0.03, 0.62, 0.66), (0.10, 0.36, 0.55), (0.08, 0.17, 0.35)],
        sun: [(1.0, 0.93, 0.62), (1.0, 0.62, 0.04)],
        sunCentre: CGPoint(x: 138, y: 132), sunRadius: 40,
        ground: (0.04, 0.12, 0.24), grid: nil
    )

    /// Mountains over a lake at first light, 16:9, for the video preview.
    static let sampleVideo: NowPlayingArtwork? = drawSampleVideo()

    private typealias Triple = (CGFloat, CGFloat, CGFloat)

    private static func drawSampleVideo() -> NowPlayingArtwork? {
        func colour(_ c: Triple, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        }
        let width = 256, height = 144
        let w = CGFloat(width), h = CGFloat(height)
        let shore: CGFloat = 52
        let sky: [Triple] = [(0.98, 0.72, 0.52), (0.62, 0.55, 0.72), (0.18, 0.27, 0.48)]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let skyGradient = CGGradient(colorsSpace: space, colors: sky.map { colour($0) } as CFArray, locations: nil)
        else { return nil }

        context.drawLinearGradient(
            skyGradient, start: CGPoint(x: 0, y: shore), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation]
        )
        context.setFillColor(colour((1.0, 0.9, 0.7), 0.9))
        context.fillEllipse(in: CGRect(x: 168, y: shore + 30, width: 26, height: 26))

        // Three ridges, fading with distance, as (x, height) peaks.
        let ridges: [(Triple, [(CGFloat, CGFloat)])] = [
            ((0.42, 0.40, 0.58), [(0, 70), (40, 104), (78, 80), (122, 118), (170, 86), (214, 108), (256, 78)]),
            ((0.25, 0.26, 0.42), [(0, 60), (30, 84), (66, 66), (104, 96), (150, 62), (196, 90), (236, 64), (256, 72)]),
            ((0.11, 0.14, 0.25), [(0, 52), (22, 66), (58, 56), (92, 74), (128, 54), (172, 70), (212, 56), (256, 64)]),
        ]
        for (tone, peaks) in ridges {
            context.move(to: CGPoint(x: 0, y: shore))
            for (x, y) in peaks { context.addLine(to: CGPoint(x: x, y: y)) }
            context.addLine(to: CGPoint(x: w, y: shore))
            context.closePath()
            context.setFillColor(colour(tone))
            context.fillPath()
        }

        // The lake: the sky again, darker, with streaks of the sun on it.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: shore))
        context.drawLinearGradient(
            skyGradient, start: CGPoint(x: 0, y: shore), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation]
        )
        context.setFillColor(colour((0.05, 0.07, 0.16), 0.55))
        context.fill(CGRect(x: 0, y: 0, width: w, height: shore))
        for i in 0..<5 {
            let length = CGFloat(40 - 7 * i)
            context.setFillColor(colour((1.0, 0.86, 0.66), 0.65 - 0.1 * CGFloat(i)))
            context.fill(CGRect(x: 181 - length / 2, y: shore - 6 - CGFloat(i) * 9, width: length, height: 2))
        }
        context.restoreGState()

        return context.makeImage().map(NowPlayingArtwork.init)
    }

    private static func drawSample(
        sky: [Triple], sun: [Triple], sunCentre: CGPoint, sunRadius: CGFloat, ground: Triple, grid: Triple?
    ) -> NowPlayingArtwork? {
        func colour(_ c: Triple, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        }
        let side = 256
        let size = CGFloat(side)
        let horizon: CGFloat = 78
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let skyGradient = CGGradient(colorsSpace: space, colors: sky.map { colour($0) } as CFArray, locations: nil),
              let sunGradient = CGGradient(colorsSpace: space, colors: sun.map { colour($0) } as CFArray, locations: nil)
        else { return nil }

        let top = CGPoint(x: 0, y: size)
        let bottom = CGPoint(x: 0, y: horizon)
        context.drawLinearGradient(skyGradient, start: top, end: bottom, options: [.drawsAfterEndLocation])

        let disc = CGRect(
            x: sunCentre.x - sunRadius, y: sunCentre.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius
        )
        context.saveGState()
        context.addEllipse(in: disc)
        context.clip()
        context.drawLinearGradient(
            sunGradient, start: CGPoint(x: 0, y: disc.maxY), end: CGPoint(x: 0, y: disc.minY), options: []
        )
        context.restoreGState()

        if grid != nil {
            // Bands across the lower half of the sun, thickening towards the horizon.
            context.saveGState()
            for i in 0..<5 {
                let height = CGFloat(2 + 2 * i)
                context.addRect(CGRect(x: 0, y: sunCentre.y - 6 - CGFloat(i) * 11, width: size, height: height))
            }
            context.clip()
            context.drawLinearGradient(skyGradient, start: top, end: bottom, options: [.drawsAfterEndLocation])
            context.restoreGState()
        }

        context.setFillColor(colour(ground))
        context.fill(CGRect(x: 0, y: 0, width: size, height: horizon))

        if let grid {
            context.setStrokeColor(colour(grid, 0.7))
            context.setLineWidth(1.5)
            for k in 1...5 {
                let y = horizon - CGFloat(k * k) * 3
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size, y: y))
            }
            for k in -4...4 {
                context.move(to: CGPoint(x: size / 2, y: horizon))
                context.addLine(to: CGPoint(x: size / 2 + CGFloat(k) * 70, y: 0))
            }
            context.strokePath()
        } else if let glow = sun.last {
            // The sun's reflection on the water, then a headland either side.
            for i in 0..<5 {
                let width = CGFloat(70 - 12 * i)
                context.setFillColor(colour(glow, 0.7 - 0.12 * CGFloat(i)))
                context.fill(CGRect(x: sunCentre.x - width / 2, y: horizon - 8 - CGFloat(i) * 11, width: width, height: 3))
            }
            context.setFillColor(colour((ground.0 * 0.5, ground.1 * 0.5, ground.2 * 0.5)))
            context.fillEllipse(in: CGRect(x: -90, y: horizon - 45, width: 200, height: 90))
            context.fillEllipse(in: CGRect(x: 170, y: horizon - 35, width: 200, height: 70))
        }

        return context.makeImage().map(NowPlayingArtwork.init)
    }
}

// MARK: - Colour maths

private struct RGB {
    var r: Double, g: Double, b: Double
}

private struct HSB {
    /// Hue in 0..<1.
    var h: Double, s: Double, b: Double

    init(_ c: RGB) {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b), range = high - low
        b = high
        s = high > 0 ? range / high : 0
        guard range > 0 else { h = 0; return }
        let sector: Double
        if high == c.r {
            sector = (c.g - c.b) / range
        } else if high == c.g {
            sector = 2 + (c.b - c.r) / range
        } else {
            sector = 4 + (c.r - c.g) / range
        }
        h = (sector / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
    }

    var rgb: RGB {
        let sector = h * 6
        let i = Int(sector) % 6
        let f = sector - Double(Int(sector))
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: b, g: t, b: p)
        case 1: return RGB(r: q, g: b, b: p)
        case 2: return RGB(r: p, g: b, b: t)
        case 3: return RGB(r: p, g: q, b: b)
        case 4: return RGB(r: t, g: p, b: b)
        default: return RGB(r: b, g: p, b: q)
        }
    }
}

/// A weighted running total of colours.
private struct ColourSum {
    var weight = 0.0
    var r = 0.0, g = 0.0, b = 0.0

    mutating func add(_ c: RGB, weight w: Double) {
        weight += w
        r += c.r * w
        g += c.g * w
        b += c.b * w
    }

    var mean: RGB {
        guard weight > 0 else { return RGB(r: 1, g: 1, b: 1) }
        return RGB(r: r / weight, g: g / weight, b: b / weight)
    }
}
