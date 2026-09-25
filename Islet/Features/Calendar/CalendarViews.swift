import SwiftUI

/// How far off an event is, in as few words as each presentation has room for.
enum CalendarCountdown {
    /// Absorbs floating-point error at a tick, which lands exactly on a whole minute.
    private static let slack: TimeInterval = 0.001

    /// Whole minutes to go, rounded up so "1m" lasts until the event begins.
    static func minutes(until start: Date, at date: Date) -> Int {
        Int(((start.timeIntervalSince(date) - slack) / 60).rounded(.up))
    }

    /// "5m", then "now".
    static func short(_ event: CalendarEvent, at date: Date) -> String {
        let minutes = minutes(until: event.start, at: date)
        return minutes > 0 ? "\(minutes)m" : "now"
    }

    /// "in 5 min", "now", then "started 2 min ago".
    static func relative(_ event: CalendarEvent, at date: Date) -> String {
        let minutes = minutes(until: event.start, at: date)
        if minutes > 0 { return "in \(minutes) min" }
        let elapsed = Int((date.timeIntervalSince(event.start) + slack) / 60)
        return elapsed < 1 ? "now" : "started \(elapsed) min ago"
    }

    /// "10:30 – 11:00", in the user's clock style. An event that runs past midnight
    /// gets its two times only: the interval style would spell out both dates, which
    /// leaves no room for the countdown beside it.
    static func span(_ event: CalendarEvent) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        guard event.end > event.start else { return event.start.formatted(time) }
        guard Calendar.current.isDate(event.start, inSameDayAs: event.end) else {
            return "\(event.start.formatted(time)) – \(event.end.formatted(time))"
        }
        return (event.start..<event.end).formatted(.interval.hour().minute())
    }
}

/// Ticks whenever a whole number of minutes remains until (or has passed since) an
/// event's start. `.everyMinute` follows the clock instead, and its dates are the
/// start of the current minute, so an event starting at 10:30:20 would read a minute
/// high for most of each minute.
struct CalendarCountdownSchedule: TimelineSchedule {
    let start: Date

    func entries(from date: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let whole = (start.timeIntervalSince(date) / 60).rounded(.down)
        let aligned = start.addingTimeInterval(-whole * 60)
        let tick = aligned > date ? aligned : aligned.addingTimeInterval(60)
        return sequence(first: date) { previous in
            previous < tick ? tick : previous.addingTimeInterval(60)
        }
    }
}

/// A small square in the calendar's colour with a calendar on it, like the app icon
/// in miniature.
struct CalendarGlyph: View {
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "calendar")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Island

struct CalendarCompactLeading: View {
    let model: CalendarModel

    var body: some View {
        if let event = model.featured {
            CalendarGlyph(color: event.color)
        }
    }
}

struct CalendarCompactTrailing: View {
    let model: CalendarModel

    var body: some View {
        if let event = model.featured {
            TimelineView(CalendarCountdownSchedule(start: event.start)) { context in
                Text(CalendarCountdown.short(event, at: context.date))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(event.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
            }
            .id(event.start)
        }
    }
}

/// The detached bubble: a dot in the calendar's colour with the minutes left on it.
struct CalendarMinimal: View {
    let model: CalendarModel

    var body: some View {
        if let event = model.featured {
            TimelineView(CalendarCountdownSchedule(start: event.start)) { context in
                let minutes = CalendarCountdown.minutes(until: event.start, at: context.date)
                Circle()
                    .fill(event.color)
                    .overlay(
                        Text(minutes > 0 ? "\(minutes)" : "now")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(3)
                    )
                    .padding(3)
            }
            .id(event.start)
        }
    }
}

struct CalendarExpanded: View {
    let model: CalendarModel
    @AppStorage(CalendarFeature.Key.showJoin) private var showJoin = true

    var body: some View {
        if let event = model.featured {
            HStack(spacing: 14) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 4, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    EventTitleButton(event: event)

                    TimelineView(CalendarCountdownSchedule(start: event.start)) { context in
                        let span = Text(verbatim: CalendarCountdown.span(event))
                            .foregroundStyle(.white.opacity(0.55))
                        let relative = Text(verbatim: CalendarCountdown.relative(event, at: context.date))
                            .foregroundStyle(event.color)
                        Text("\(span)\(Text(verbatim: "  ·  ").foregroundStyle(.white.opacity(0.35)))\(relative)")
                    }
                    .id(event.start)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)

                    if let place = event.place {
                        HStack(spacing: 5) {
                            Image(systemName: event.location == place ? "mappin.and.ellipse" : "video.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(place)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showJoin, let meeting = event.meeting {
                    JoinButton(meeting: meeting)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
    }
}

/// The event's title, which opens it in Calendar.
private struct EventTitleButton: View {
    let event: CalendarEvent
    @State private var isHovering = false

    var body: some View {
        Button {
            CalendarApp.show(event)
        } label: {
            Text(event.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.8 : 1))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open in Calendar")
    }
}

private struct JoinButton: View {
    let meeting: MeetingLink
    @State private var isHovering = false

    var body: some View {
        Button {
            CalendarApp.join(meeting)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(CalendarPalette.green))
                .brightness(isHovering ? 0.08 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Join on \(meeting.service.name)")
    }
}

// MARK: - Home

/// "Up next": what is left of today, or a way to let Islet see the calendar.
struct CalendarHomeTile: View {
    let model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up next", systemImage: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CalendarPalette.red)

            switch model.visibleAccess {
            case .granted:
                TimelineView(.everyMinute) { context in
                    UpNextList(events: model.visibleEvents, now: context.date)
                }
            case .undetermined:
                AccessPrompt(message: "Show your next event", action: "Allow…") {
                    model.requestAccess()
                }
            case .denied:
                AccessPrompt(message: "Calendar access is off", action: "Open Settings…") {
                    CalendarApp.openPrivacySettings()
                }
            case .restricted:
                AccessPrompt(message: "Calendar access is restricted", action: "Open Settings…") {
                    CalendarApp.openPrivacySettings()
                }
            }
        }
        .onAppear { model.refreshAccess() }
    }
}

private struct UpNextList: View {
    let events: [CalendarEvent]
    let now: Date

    /// Narrower than this, the tile trades its third row for room to read titles.
    private static let listWidth: CGFloat = 150

    /// "9:30", or "21:30" where the clock runs to 24: the locale's own hours without
    /// AM or PM, which a row has no room for and the day makes plain.
    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Jmm")
        return formatter
    }()

    /// The rest of today: timed events first, since they are the ones with somewhere
    /// to be, then all-day ones.
    private var remaining: [CalendarEvent] {
        let today = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 60 * 60)
        let left = events.filter { $0.end > now && $0.start < tomorrow }
        return left.filter { !$0.isAllDay } + left.filter(\.isAllDay)
    }

    var body: some View {
        let remaining = remaining
        if remaining.isEmpty {
            Text("No more events today")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            GeometryReader { geo in
                if geo.size.width >= Self.listWidth {
                    list(Array(remaining.prefix(3)))
                } else {
                    stack(Array(remaining.prefix(2)))
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// A line each, in columns: dot, time, title.
    private func list(_ rows: [CalendarEvent]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows) { event in
                GridRow {
                    Circle()
                        .fill(event.color)
                        .frame(width: 6, height: 6)
                    Button { CalendarApp.show(event) } label: {
                        Text(time(of: event))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isUnderway(event) ? event.color : .white.opacity(0.55))
                    }
                    Button { CalendarApp.show(event) } label: {
                        Text(event.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// Two lines each, so the title has the tile's full width.
    private func stack(_ rows: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { event in
                Button { CalendarApp.show(event) } label: {
                    HStack(spacing: 7) {
                        Capsule()
                            .fill(event.color)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            detail(of: event)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .lineLimit(1)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func isUnderway(_ event: CalendarEvent) -> Bool {
        !event.isAllDay && event.start <= now
    }

    private func time(of event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        if isUnderway(event) { return "Now" }
        return Self.hourMinute.string(from: event.start)
    }

    /// "10:30 – 11:00 AM", "All day", or "Now" in the event's colour with its end.
    private func detail(of event: CalendarEvent) -> Text {
        if event.isAllDay { return Text("All day") }
        guard isUnderway(event) else { return Text(verbatim: CalendarCountdown.span(event)) }
        return Text("\(Text("Now").foregroundStyle(event.color)) · until \(Self.hourMinute.string(from: event.end))")
    }
}

private struct AccessPrompt: View {
    let message: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Text(action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
