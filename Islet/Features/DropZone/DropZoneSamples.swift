import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Three small files for the previews, in the temporary folder, so the shelf can be
/// shown full without touching the user's own files. Made once and reused.
enum DropZoneSamples {
    static func make() async -> [URL] {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Islet Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let files: [(name: String, contents: () -> Data?)] = [
            ("Sunset.png", sunsetPNG),
            ("Trip Itinerary.txt", { Data(itinerary.utf8) }),
            ("Budget 2026.csv", { Data(budget.utf8) }),
        ]
        return files.compactMap { file in
            let url = folder.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            guard let data = file.contents(), (try? data.write(to: url, options: .atomic)) != nil
            else { return nil }
            return url
        }
    }

    private static let itinerary = """
        Lisbon, 12–16 October

        Sat  Land 09:40, drop bags at the flat in Alfama
             Tram 28 up to the castle, dinner at the miradouro
        Sun  Belém: the tower, the monastery, pastéis
        Mon  Day trip to Sintra, train from Rossio 08:11
        Tue  LX Factory, then the river walk to Cais do Sodré
        Wed  Fly home 18:25
        """

    private static let budget = """
        Category,Planned,Spent
        Rent,1450,1450
        Groceries,420,386.20
        Transport,120,98.50
        Eating out,180,212.75
        Savings,600,600
        """

    /// A small landscape drawn in code, so the shelf has a picture with a real
    /// Quick Look thumbnail.
    private static func sunsetPNG() -> Data? {
        let width = 640, height = 400
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let sky = CGGradient(
                  colorsSpace: space,
                  colors: [
                      CGColor(srgbRed: 1.0, green: 0.55, blue: 0.32, alpha: 1),
                      CGColor(srgbRed: 0.93, green: 0.33, blue: 0.42, alpha: 1),
                      CGColor(srgbRed: 0.29, green: 0.18, blue: 0.52, alpha: 1),
                  ] as CFArray,
                  locations: [0, 0.45, 1]
              )
        else { return nil }

        // Core Graphics puts the origin at the bottom left.
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1.0, green: 0.86, blue: 0.45, alpha: 1))
        context.fillEllipse(in: CGRect(x: 360, y: 120, width: 150, height: 150))

        for (color, peaks) in [
            (CGColor(srgbRed: 0.36, green: 0.16, blue: 0.36, alpha: 1), [(0, 170), (150, 230), (330, 150), (480, 210), (640, 160)]),
            (CGColor(srgbRed: 0.14, green: 0.08, blue: 0.22, alpha: 1), [(0, 110), (200, 150), (390, 90), (560, 140), (640, 120)]),
        ] {
            context.setFillColor(color)
            context.move(to: .zero)
            for (x, y) in peaks { context.addLine(to: CGPoint(x: x, y: y)) }
            context.addLine(to: CGPoint(x: width, y: 0))
            context.closePath()
            context.fillPath()
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
