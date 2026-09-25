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
    static let presets: [TimeInterval] = [60, 5 * 60, 10 * 60, 25 * 60]

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
                    ForEach(Self.presets, id: \.self) { seconds in
                        Button {
                            model.start(seconds)
                        } label: {
                            Text("\(Int(seconds / 60))m")
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

/// A filled circular button in the iPhone Live Activity style.
struct RoundButton: View {
    let symbol: String
    let tint: Color
    var diameter: CGFloat = 38
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(isHovering ? 0.3 : 0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
