import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Made-up screenshots for the previews, drawn in code into the temporary folder beside
/// the other samples, so the card can be seen without a real screenshot, and nothing of
/// the person's screen is ever shown or touched.
enum ScreenshotSamples {
    enum Kind {
        /// The whole screen: a desktop with a window on it.
        case screen
        /// One window, taller than it is wide, on a clear background as macOS saves one.
        case window

        var fileName: String {
            switch self {
            case .screen: "Screenshot (sample).png"
            case .window: "Screenshot of a window (sample).png"
            }
        }

        var pixelSize: (width: Int, height: Int) {
            switch self {
            case .screen: (1512, 982)
            case .window: (860, 1080)
            }
        }
    }

    static func make(_ kind: Kind) async -> Screenshot? {
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Islet Samples", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(kind.fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            guard let data = png(kind), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            return url
        }.value
        guard let url else { return nil }
        var shot = await ScreenshotFiles.load(url, place: "Sample", attempts: 1)
        shot?.isSample = true
        return shot
    }

    static func png(_ kind: Kind) -> Data? {
        let (width, height) = kind.pixelSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let size = CGSize(width: width, height: height)
        switch kind {
        case .screen:
            drawDesktop(in: context, size: size, space: space)
            drawWindow(in: context, frame: CGRect(x: 250, y: 150, width: 1010, height: 640))
        case .window:
            drawWindow(in: context, frame: CGRect(x: 40, y: 50, width: 780, height: 990))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A dusk wallpaper and the menu bar across its top. Core Graphics puts the origin
    /// at the bottom left.
    private static func drawDesktop(in context: CGContext, size: CGSize, space: CGColorSpace) {
        if let sky = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(srgbRed: 0.18, green: 0.2, blue: 0.45, alpha: 1),
                CGColor(srgbRed: 0.62, green: 0.34, blue: 0.62, alpha: 1),
                CGColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1),
            ] as CFArray,
            locations: [0, 0.55, 1]
        ) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        context.fill(CGRect(x: 0, y: size.height - 34, width: size.width, height: 34))
    }

    /// A window: a title bar with its three buttons, a sidebar, and lines of text.
    private static func drawWindow(in context: CGContext, frame: CGRect) {
        let window = CGPath(roundedRect: frame, cornerWidth: 20, cornerHeight: 20, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(window)
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(window)
        context.clip()
        // The sidebar.
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.91, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width * 0.28, height: frame.height))
        for (index, color) in [
            CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
            CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
        ].enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: frame.minX + 22 + CGFloat(index) * 28, y: frame.maxY - 38, width: 18, height: 18))
        }
        context.setFillColor(CGColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1))
        for row in 0..<6 {
            context.fill(CGRect(x: frame.minX + 24, y: frame.maxY - 100 - CGFloat(row) * 40, width: frame.width * 0.2, height: 14))
        }
        // A picture and a column of text.
        let content = frame.minX + frame.width * 0.28 + 36
        let contentWidth = frame.width * 0.72 - 72
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.85))
        context.fill(CGRect(x: content, y: frame.maxY - 90 - contentWidth * 0.42, width: contentWidth, height: contentWidth * 0.42))
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.56, blue: 0.6, alpha: 1))
        var y = frame.maxY - 130 - contentWidth * 0.42
        var line = 0
        while y > frame.minY + 40 {
            let width = line % 4 == 3 ? contentWidth * 0.6 : contentWidth
            context.fill(CGRect(x: content, y: y, width: width, height: 12))
            y -= 30
            line += 1
        }
        context.restoreGState()
    }
}
