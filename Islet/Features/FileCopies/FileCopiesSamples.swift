import Foundation

/// Made-up copies for the previews, onto made-up disks and folders, so nothing of the
/// person's is shown or touched.
enum FileCopiesSamples {
    enum Run {
        /// One big file onto an external drive, from start to finish.
        case single
        /// Twelve items chosen at once, into a folder.
        case several
        /// Two copies at once: a folder, then a file.
        case two

        /// How long the made-up copies run.
        var duration: TimeInterval {
            switch self {
            case .single: 6
            case .several: 6
            case .two: 7
            }
        }
    }

    private struct Sample {
        var id: String
        var kind: FileCopyItem.Kind = .copying
        var name: String
        var itemCount: Int
        var destination: String
        var total: Int64
        /// How much had been copied when the preview started.
        var head: Int64
        /// Seconds into the preview the copy starts.
        var start: TimeInterval = 0
        /// Seconds of working out how much there is, before any bytes go.
        var preparing: TimeInterval = 0
    }

    private static func samples(for run: Run) -> [Sample] {
        let film = Sample(
            id: "sample.film", name: "Harbour Timelapse.mov", itemCount: 1,
            destination: "/Volumes/Archive Drive", total: 6_442_450_944, head: 900_000_000
        )
        switch run {
        case .single:
            return [film]
        case .several:
            return [Sample(
                id: "sample.recordings", name: FileCopyItem.itemsName(12), itemCount: 12,
                destination: "/Volumes/Archive Drive/Field Recordings", total: 2_147_483_648, head: 0, preparing: 1
            )]
        case .two:
            var later = film
            later.start = 1
            later.head = 0
            return [
                Sample(
                    id: "sample.photos", name: "Sintra Photos", itemCount: 1,
                    destination: "/Volumes/Archive Drive", total: 3_865_470_566, head: 1_400_000_000
                ),
                later,
            ]
        }
    }

    /// The copies `elapsed` seconds into a preview that began at `started`. Each reaches
    /// its end just as the preview does.
    static func items(for run: Run, at elapsed: TimeInterval, started: Date) -> [FileCopyItem] {
        samples(for: run).compactMap { sample in
            guard elapsed >= sample.start else { return nil }
            let running = elapsed - sample.start
            let destination = URL(fileURLWithPath: sample.destination, isDirectory: true)
            let copying = running - sample.preparing
            let span = max(0.5, run.duration - sample.start - sample.preparing)
            let rate = Double(sample.total - sample.head) / span
            let copied = copying < 0 ? 0 : min(sample.total, sample.head + Int64(rate * copying))
            let measured = copying >= 1
            return FileCopyItem(
                id: sample.id, kind: sample.kind, name: sample.name, itemCount: sample.itemCount,
                destination: destination, destinationName: destination.lastPathComponent,
                copied: copied, total: copying < 0 ? nil : sample.total,
                fraction: copying < 0 ? nil : Double(copied) / Double(sample.total),
                bytesPerSecond: measured ? rate : nil,
                secondsLeft: measured ? Double(sample.total - copied) / rate : nil,
                canStop: true, startedAt: started.addingTimeInterval(sample.start)
            )
        }
    }
}
