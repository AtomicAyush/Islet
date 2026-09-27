import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A made-up history for previews: a little of everything the history keeps, copied
/// from apps that come with every Mac, so their icons are always there. Nothing in it
/// was ever on anyone's clipboard; the picture is drawn here, and the file is named
/// but not made.
///
/// The file sits in a folder at the top of the startup disk, which is read-only, so it
/// can never be there: drawing its row looks nothing up in anyone's Documents (which
/// macOS might ask about) and shows its kind's icon, not a real file's.
@MainActor
enum ClipboardSamples {
    static func items(now: Date = Date()) -> [ClipboardItem] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func app(_ id: String, _ name: String) -> ClipboardSource {
            ClipboardSource(bundleIdentifier: id, name: name)
        }
        let documents = URL(fileURLWithPath: "/Islet Samples/Documents", isDirectory: true)

        var items = [
            ClipboardItem(
                content: .text("Meet at the café on the corner at seven — I’ll book a table for four."),
                source: app("com.apple.MobileSMS", "Messages"), copiedAt: ago(0.2)
            ),
            ClipboardItem(
                content: .link(
                    URL(string: "https://developer.apple.com/documentation/appkit/nspasteboard") ?? URL(fileURLWithPath: "/"),
                    title: "NSPasteboard | Apple Developer Documentation"
                ),
                source: app("com.apple.Safari", "Safari"), copiedAt: ago(4)
            ),
            ClipboardItem(
                content: .files([documents.appendingPathComponent("Quarterly Report.pdf")]),
                source: app("com.apple.finder", "Finder"), copiedAt: ago(26)
            ),
            ClipboardItem(
                content: .text("git log --oneline --since=yesterday"),
                source: app("com.apple.Terminal", "Terminal"), copiedAt: ago(48)
            ),
            ClipboardItem(
                content: .text("Oat milk, lemons, basil, sourdough, two tins of tomatoes"),
                source: app("com.apple.Notes", "Notes"), copiedAt: ago(95)
            ),
            ClipboardItem(
                content: .text("jane.appleseed@example.com"),
                source: app("com.apple.AddressBook", "Contacts"), copiedAt: ago(60 * 26), isPinned: true
            ),
        ]
        if let picture = picture() {
            items.insert(
                ClipboardItem(content: .image(picture), source: app("com.apple.Preview", "Preview"), copiedAt: ago(12)),
                at: 2
            )
        }
        return items
    }

    /// A sunset over hills, 1600 × 1000: something to see in a thumbnail.
    static func picture(width: Int = 1600, height: Int = 1000) -> ClipboardImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let colours = [
            CGColor(srgbRed: 0.98, green: 0.55, blue: 0.30, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.36, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.35, green: 0.22, blue: 0.52, alpha: 1),
        ]
        if let sky = CGGradient(colorsSpace: nil, colors: colours as CFArray, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.3), end: CGPoint(x: 0, y: h), options: [])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.56, y: h * 0.28, width: w * 0.2, height: w * 0.2))
        for (index, shade) in [0.28, 0.18].enumerated() {
            context.setFillColor(CGColor(srgbRed: shade * 0.7, green: shade * 0.5, blue: shade, alpha: 1))
            let path = CGMutablePath()
            let base = h * (0.32 - CGFloat(index) * 0.12)
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: base))
            path.addCurve(
                to: CGPoint(x: w, y: base * 0.8),
                control1: CGPoint(x: w * (0.3 + CGFloat(index) * 0.2), y: base * 1.9),
                control2: CGPoint(x: w * 0.6, y: base * 0.2)
            )
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipboardImage.make(data: data as Data, type: .png)
    }
}
