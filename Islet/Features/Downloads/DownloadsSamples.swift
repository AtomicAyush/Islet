import CoreGraphics
import Foundation

/// Made-up downloads for the previews, and a small file for the finished card to hand
/// over, in the temporary folder beside Drop Zone's samples, so nothing of the person's
/// is shown or touched.
enum DownloadsSamples {
    enum Run {
        /// One download of a known size, from start to finish.
        case single
        /// One whose server does not say how big it is.
        case unknownSize
        /// Three at once.
        case several

        /// How long the made-up downloads run.
        var duration: TimeInterval {
            switch self {
            case .single: 6
            case .unknownSize: 5
            case .several: 7
            }
        }
    }

    static let guideName = "Lisbon Field Guide.pdf"
    /// What the finished card says the guide weighs; the file itself is a few kilobytes.
    static let guideSize: Int64 = 48_213_760

    private struct Sample {
        var id: String
        var name: String
        var total: Int64?
        /// Bytes a second, for one whose size is not known; one whose size is known goes
        /// at whatever rate brings it to its end with the preview.
        var rate: Double
        /// How much had come when the preview started.
        var head: Int64
        /// Seconds into the preview the download starts.
        var start: TimeInterval = 0
    }

    private static func samples(for run: Run) -> [Sample] {
        let guide = Sample(id: "sample.guide", name: guideName, total: guideSize, rate: 0, head: 3_100_000)
        switch run {
        case .single:
            return [guide]
        case .unknownSize:
            return [Sample(id: "sample.timetable", name: "Tram 28 Timetable.xlsx", total: nil, rate: 1_250_000, head: 400_000)]
        case .several:
            return [
                Sample(id: "sample.photos", name: "Sintra Photos.zip", total: 312_475_648, rate: 0, head: 118_000_000),
                Sample(id: "sample.timetable", name: "Tram 28 Timetable.xlsx", total: nil, rate: 1_250_000, head: 400_000),
                Sample(id: "sample.guide", name: guideName, total: guideSize, rate: 0, head: 0, start: 0.5),
            ]
        }
    }

    /// The downloads `elapsed` seconds into a preview that began at `started`. One of a
    /// known size reaches its end just as the preview does.
    static func items(for run: Run, at elapsed: TimeInterval, started: Date) -> [DownloadItem] {
        samples(for: run).compactMap { sample in
            guard elapsed >= sample.start else { return nil }
            let running = elapsed - sample.start
            let measured = running >= 1
            let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            guard let total = sample.total else {
                return DownloadItem(
                    id: sample.id, name: sample.name, location: folder.appendingPathComponent(sample.name + ".part"),
                    received: sample.head + Int64(sample.rate * running), total: nil,
                    bytesPerSecond: measured ? sample.rate : nil, secondsLeft: nil,
                    startedAt: started.addingTimeInterval(sample.start)
                )
            }
            let rate = Double(total - sample.head) / max(0.5, run.duration - sample.start)
            let received = min(total, sample.head + Int64(rate * running))
            return DownloadItem(
                id: sample.id, name: sample.name, location: folder.appendingPathComponent(sample.name + ".download"),
                received: received, total: total,
                bytesPerSecond: measured ? rate : nil,
                secondsLeft: measured ? Double(total - received) / rate : nil,
                startedAt: started.addingTimeInterval(sample.start)
            )
        }
    }

    /// The finished guide: a one-page PDF drawn in code, so the card has a real file to
    /// open, drag and show in Finder. Made once and reused.
    static func guide() async -> FinishedDownload? {
        await Task.detached(priority: .utility) { () -> FinishedDownload? in
            let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Islet Samples", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(guideName)
            if !FileManager.default.fileExists(atPath: url.path), !drawGuide(to: url) { return nil }
            return FinishedDownload(url: url, size: guideSize)
        }.value
    }

    /// A page of a travel guide in outline: a title band, a map and lines of text.
    private static func drawGuide(to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.36, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 515, width: 420, height: 80))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 32, y: 548, width: 190, height: 16))
        // The map: the river, and the hills either side.
        context.setFillColor(CGColor(srgbRed: 0.72, green: 0.85, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 32, y: 300, width: 356, height: 190))
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.75, blue: 0.5, alpha: 1))
        context.fillEllipse(in: CGRect(x: 60, y: 380, width: 120, height: 90))
        context.fillEllipse(in: CGRect(x: 230, y: 330, width: 140, height: 110))
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.35, blue: 0.4, alpha: 1))
        for line in 0..<9 {
            let width: CGFloat = line % 3 == 2 ? 220 : 356
            context.fill(CGRect(x: 32, y: 250 - CGFloat(line) * 24, width: width, height: 7))
        }
        context.endPDFPage()
        context.closePDF()
        return true
    }
}
