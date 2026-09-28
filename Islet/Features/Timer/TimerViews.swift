import SwiftUI

/// The Clock app's timer orange.
let timerOrange = Color(red: 1.0, green: 0.62, blue: 0.04)

/// Remaining time that ticks without anyone driving it: `Text(timerInterval:)`
/// counts down on its own while running.
struct TimerCountdownText: View {
    let model: TimerModel
    var size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        Group {
            if case .running(let end) = model.state, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true, showsHours: true)
            } else {
                Text(model.remaining().countdownText)
            }
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(timerOrange)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A ring that drains as the timer runs, redrawn a few times a second.
struct TimerRing: View {
    let model: TimerModel
    var lineWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !isRunning)) { context in
            ZStack {
                Circle().stroke(timerOrange.opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: model.progress(at: context.date))
                    .stroke(timerOrange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private var isRunning: Bool {
        if case .running = model.state { return true }
        return false
    }
}

struct TimerCompactLeading: View {
    let model: TimerModel

    var body: some View {
        TimerRing(model: model, lineWidth: 2.5)
            .overlay(
                Image(systemName: "timer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(timerOrange)
            )
            .frame(width: 18, height: 18)
    }
}

struct TimerCompactTrailing: View {
    let model: TimerModel

    var body: some View {
        TimerCountdownText(model: model, size: 13)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

struct TimerMinimal: View {
    let model: TimerModel

    var body: some View {
        TimerRing(model: model, lineWidth: 2.5)
            .overlay(
                Image(systemName: "timer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(timerOrange)
            )
            .padding(5)
    }
}

struct TimerExpanded: View {
    let model: TimerModel

    var body: some View {
        HStack(spacing: 16) {
            TimerRing(model: model, lineWidth: 5)
                .overlay(
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(timerOrange)
                )
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 0) {
                Text(isPaused ? "Paused" : "Timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                TimerCountdownText(model: model, size: 40, weight: .medium)
            }

            Spacer()

            RoundButton(symbol: isPaused ? "play.fill" : "pause.fill", tint: timerOrange) {
                model.togglePause()
            }
            RoundButton(symbol: "xmark", tint: .white) {
                model.cancel()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var isPaused: Bool {
        if case .paused = model.state { return true }
        return false
    }
}

/// The finished alert: the bell rings, and the last length is one click away.
struct TimerDoneCard: View {
    let model: TimerModel
    let dismiss: () -> Void
    @State private var ring = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bell.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(timerOrange)
                .rotationEffect(.degrees(ring ? 14 : -14), anchor: .top)
                .animation(.easeInOut(duration: 0.12).repeatCount(9, autoreverses: true), value: ring)
                .frame(width: 44, height: 44)
                .background(Circle().fill(timerOrange.opacity(0.18)))

            VStack(alignment: .leading, spacing: 1) {
                Text("Timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button {
                model.start(model.lastDuration)
                dismiss()
            } label: {
                Label(model.lastDuration.countdownText, systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(timerOrange)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(timerOrange.opacity(0.2)))
            }
            .buttonStyle(.plain)

            RoundButton(symbol: "xmark", tint: .white, diameter: 30, action: dismiss)
        }
        .frame(maxHeight: .infinity)
        .onAppear { ring = true }
    }
}

/// Quick starts on the home page, or the countdown when one is running.
struct TimerHomeTile: View {
    let model: TimerModel
    @AppStorage(TimerPresets.key) private var presets = TimerPresets.stored(TimerPresets.standard)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Timer", systemImage: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(timerOrange)

            if model.isActive {
                TimerCountdownText(model: model, size: 28, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    // By place, since two quick starts may be set to the same length.
                    ForEach(Array(TimerPresets.minutes(in: presets).enumerated()), id: \.offset) { _, minutes in
                        Button {
                            model.start(TimeInterval(minutes * 60))
                        } label: {
                            Text(TimerPresets.label(minutes))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 24)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The tile's four quick starts, in whole minutes, as Settings keeps them: one string,
/// "1,5,10,25", so the tile can follow it through `@AppStorage`. Anything unreadable
/// or the wrong length reads as the standard four.
enum TimerPresets {
    static let key = "timer.presets"
    static let standard = [1, 5, 10, 25]
    /// A minute to twelve hours, the longest a timer runs.
    static let range = 1...720

    static func minutes(in stored: String) -> [Int] {
        let values = stored.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == standard.count else { return standard }
        return values.map { min(max($0, range.lowerBound), range.upperBound) }
    }

    static func stored(_ minutes: [Int]) -> String {
        minutes.map(String.init).joined(separator: ",")
    }

    /// How a quick start reads on the tile: "5m", "1h", "1h30".
    static func label(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(String(format: "%02d", rest))"
    }
}
