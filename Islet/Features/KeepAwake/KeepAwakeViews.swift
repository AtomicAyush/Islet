import AppKit
import SwiftUI

extension FeatureTint {
    /// A coffee's crema: warm, like the timer's orange, but paler, so the two are told
    /// apart when both are beside the notch.
    static let keepAwake = FeatureTint.colour(RGB(0.96, 0.77, 0.55))
}

/// The symbol Keep Awake goes by everywhere it shows.
enum KeepAwakeSymbol {
    static let on = "cup.and.saucer.fill"
    static let off = "cup.and.saucer"
}

/// The lengths the home tile offers, and the Keep Mac Awake action in Shortcuts.
enum KeepAwakeLength: String, CaseIterable, Sendable {
    case fifteenMinutes
    case oneHour
    case twoHours
    case untilTurnedOff

    /// `nil` until turned off.
    var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .untilTurnedOff: nil
        }
    }

    /// For VoiceOver, where the tile's buttons are only "15m" or a symbol.
    var spokenTitle: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilTurnedOff: "Until turned off"
        }
    }
}

/// Time left, counting down on its own as the timer's does, or the infinity sign for a
/// session that runs until turned off.
struct KeepAwakeTimeText: View {
    let session: KeepAwakeModel.Session
    var size: CGFloat
    var weight: Font.Weight = .semibold
    /// The island, or the home tile.
    var backdrop: IslandBackdrop = .island

    var body: some View {
        Group {
            if let end = session.end {
                if end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true, showsHours: true)
                } else {
                    Text(TimeInterval(0).countdownText)
                }
            } else {
                // The symbol is set larger than digits would be to look the same size.
                Image(systemName: "infinity")
                    .font(.system(size: size * 0.9, weight: weight))
                    .accessibilityLabel("Until turned off")
            }
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.islandAccentText(.keepAwake, on: backdrop))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A ring that drains as a timed session runs, redrawn once a second: a session lasts
/// minutes or hours, so nothing finer would show. Full, and still, until turned off.
struct KeepAwakeRing: View {
    let session: KeepAwakeModel.Session
    var lineWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: session.end == nil)) { context in
            ZStack {
                Circle().stroke(IslandStyle.islandAccent(.keepAwake).opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: session.progress(at: context.date))
                    .stroke(.islandAccent(.keepAwake), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// The ring with the cup in it, as the bubble and the opened island show it.
private struct KeepAwakeBadge: View {
    let session: KeepAwakeModel.Session
    var lineWidth: CGFloat
    var symbolSize: CGFloat

    var body: some View {
        KeepAwakeRing(session: session, lineWidth: lineWidth)
            .overlay(
                Image(systemName: KeepAwakeSymbol.on)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(.islandAccent(.keepAwake))
            )
            .accessibilityHidden(true)
    }
}

struct KeepAwakeCompactLeading: View {
    var body: some View {
        Image(systemName: KeepAwakeSymbol.on)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.islandAccent(.keepAwake))
            .accessibilityLabel("Keeping the Mac awake")
    }
}

struct KeepAwakeCompactTrailing: View {
    let model: KeepAwakeModel

    var body: some View {
        if let session = model.shown {
            KeepAwakeTimeText(session: session, size: 13)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }
    }
}

/// In the bubble, beside music or a timer: the draining ring, which says as much as the
/// minutes would at a glance. Folded into the island's end, where the circle is too
/// small for a ring with a cup inside it, the cup alone.
struct KeepAwakeMinimal: View {
    let model: KeepAwakeModel

    var body: some View {
        if let session = model.shown {
            GeometryReader { proxy in
                if proxy.size.width < 24 {
                    Image(systemName: KeepAwakeSymbol.on)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.islandAccent(.keepAwake))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .accessibilityLabel("Keeping the Mac awake")
                } else {
                    KeepAwakeBadge(session: session, lineWidth: 2.5, symbolSize: 7.5)
                        .padding(5)
                }
            }
        }
    }
}

/// The opened island: until when, the time left, and the two things to do with it.
struct KeepAwakeExpanded: View {
    let model: KeepAwakeModel

    var body: some View {
        if let session = model.shown {
            HStack(spacing: 16) {
                KeepAwakeBadge(session: session, lineWidth: 5, symbolSize: 18)
                    .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 0) {
                    Text(KeepAwakeWords.until(session.end, now: Date()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.islandText(0.55))
                        .lineLimit(1)
                    KeepAwakeTimeText(session: session, size: 40, weight: .medium)
                }

                Spacer(minLength: 8)

                if session.end != nil {
                    Button {
                        model.extend(by: KeepAwakeFeature.extra)
                    } label: {
                        Label("15 min", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .islandWashed(.accent(.keepAwake, minimum: Contrast.text), wash: 0.2, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("15 more minutes")
                }
                RoundButton(symbol: "xmark") {
                    model.stop()
                }
                .accessibilityLabel("Stop keeping the Mac awake")
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Quick starts on the home page, or, while the Mac is kept awake, the time left and the
/// ways to lengthen or stop it.
struct KeepAwakeHomeTile: View {
    let model: KeepAwakeModel
    /// Starts a session. The feature's, since it checks it is still on.
    let start: (KeepAwakeLength) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keep Awake", systemImage: KeepAwakeSymbol.on)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccentText(.keepAwake, on: .homeTile))
                .lineLimit(1)

            if let session = model.shown {
                KeepAwakeTimeText(session: session, size: 26, weight: .medium, backdrop: .homeTile)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                HStack(spacing: 6) {
                    if session.end != nil {
                        pill { Text("+15") } action: { model.extend(by: KeepAwakeFeature.extra) }
                            .accessibilityLabel("15 more minutes")
                    }
                    pill { Text("Stop") } action: { model.stop() }
                        .accessibilityLabel("Stop keeping the Mac awake")
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(KeepAwakeLength.allCases, id: \.self) { length in
                        pill { label(for: length) } action: { start(length) }
                            .accessibilityLabel("Keep awake: \(length.spokenTitle)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func label(for length: KeepAwakeLength) -> some View {
        switch length {
        case .fifteenMinutes: Text("15m")
        case .oneHour: Text("1h")
        case .twoHours: Text("2h")
        case .untilTurnedOff: Image(systemName: "infinity")
        }
    }

    private func pill(@ViewBuilder _ label: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.islandText(1, on: IslandBackdrop.homeTile.stacked(0.12)))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(.islandSurface(0.12, on: .homeTile)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Banner

/// Left of the notch as a timed session runs out: the cup, empty, and the feature's
/// name.
struct KeepAwakeEndedLeading: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: KeepAwakeBannerLayout.symbolSpacing) {
                symbol
                Text(KeepAwakeBannerLayout.name)
                    .font(Font(KeepAwakeBannerLayout.font))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, KeepAwakeBannerLayout.outerInset)
            .padding(.trailing, KeepAwakeBannerLayout.innerInset)
            symbol
                .padding(.leading, KeepAwakeBannerLayout.outerInset)
                .padding(.trailing, KeepAwakeBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: KeepAwakeSymbol.off)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(.islandAccent(.keepAwake))
            .frame(width: KeepAwakeBannerLayout.symbolSize.width, height: KeepAwakeBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: "Off", in grey, as Caps Lock says it. Only as wide as the word,
/// so the opened island's header can set it beside the cup.
struct KeepAwakeEndedTrailing: View {
    var body: some View {
        Text(KeepAwakeBannerLayout.status)
            .font(Font(KeepAwakeBannerLayout.font))
            .foregroundStyle(.islandText(0.5))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, KeepAwakeBannerLayout.innerInset)
            .padding(.trailing, KeepAwakeBannerLayout.outerInset)
    }
}

/// The banner's measurements, the Caps Lock banner's: 13-point semibold words, the same
/// insets, and each side only as wide as it needs, the island evening the two up.
enum KeepAwakeBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let name = "Keep Awake"
    static let status = "Off"
    /// The cup and saucer are wider than they are tall.
    static let symbolSize = CGSize(width: 20, height: 16)
    static let symbolSpacing: CGFloat = 7
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static var widths: (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing + textWidth(name) + innerInset,
            innerInset + textWidth(status) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

/// The words the opened island uses.
enum KeepAwakeWords {
    /// "Awake until 15:30", with the day when it is not today, or "Awake until turned off".
    static func until(_ end: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let end else { return "Awake until turned off" }
        let time = calendar.isDate(end, inSameDayAs: now)
            ? end.formatted(date: .omitted, time: .shortened)
            : end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Awake until \(time)"
    }
}
