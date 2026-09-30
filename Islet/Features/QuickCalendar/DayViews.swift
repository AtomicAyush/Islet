import AppKit
import SwiftUI

enum DayPageLayout {
    static let symbol = "calendar.day.timeline.left"
    static let rowHeight: CGFloat = 20
    static let headerHeight: CGFloat = 26
    static let allDayHeight: CGFloat = 16
    static let inset: CGFloat = 8
    static let minimumHeight: CGFloat = 96
    /// As the box: past this the rows scroll.
    static let maximumHeight: CGFloat = InputBoxLayout.maximumHeight

    /// The Day page's height for `plan`: its rows, up to the most the island has room for.
    static func height(for plan: DayPlan?) -> CGFloat {
        guard let plan else { return minimumHeight }
        let rows = CGFloat(max(plan.rows.count, 1)) * rowHeight
        let allDay = plan.allDay.isEmpty ? 0 : allDayHeight + 4
        return min(max(inset * 2 + headerHeight + 6 + allDay + rows, minimumHeight), maximumHeight)
    }
}

// MARK: - Today tile

/// The home page's Today tile: how the day stands now, its clashes, a way to see it
/// summed up, and a new event.
struct QuickCalendarTodayTile: View {
    let model: QuickCalendarModel
    let summarise: () -> Void
    let newEvent: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = model.now()
            let plan = model.access == .granted ? model.plan(.today, at: now) : nil
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Today", systemImage: DayPageLayout.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.islandAccentText(.quickCalendar, on: .homeTile))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let plan, !plan.clashes.isEmpty {
                        ClashBadge(count: plan.clashes.count, format: QuickCalendarFormat(model: model))
                    }
                }
                if let plan {
                    status(plan, at: now)
                } else {
                    Text(model.access == .undetermined ? "See when you're free" : "Calendar access is off")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.islandText(0.55, on: .homeTile))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    DayTileButton(title: "Summarise", symbol: "text.alignleft", action: summarise)
                        .help("Your free time and clashes today")
                        .accessibilityHint("Shows your day, from Calendar")
                    DayTileButton(title: nil, symbol: "plus", action: newEvent)
                        .help("New event")
                        .accessibilityLabel("New event")
                        .accessibilityHint("Opens a box to type an event")
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private func status(_ plan: DayPlan, at now: Date) -> some View {
        let words = DayWords(format: QuickCalendarFormat(model: model))
        return VStack(alignment: .leading, spacing: 2) {
            Text(words.status(plan, at: now))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.islandText(0.9, on: .homeTile))
                .lineLimit(1)
            if let line = words.freeLine(plan) {
                Text(line)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.5, on: .homeTile))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "1 clash", in the colour of a warning.
struct ClashBadge: View {
    let count: Int
    let format: QuickCalendarFormat

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8.5, weight: .semibold))
            Text(count == 1 ? "1 clash" : "\(count) clashes")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.islandHueText(.warning, on: .homeTile))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A button on the Today tile: a word and a symbol, or a symbol alone.
private struct DayTileButton: View {
    let title: String?
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let backdrop = IslandBackdrop.homeTile.stacked(0.12)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.islandAccent(.quickCalendar, on: backdrop))
                if let title {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.islandText(0.75, on: backdrop))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 24)
            .frame(height: 24)
            .background(Capsule().fill(.islandSurface(isHovering ? 0.16 : 0.12, on: .homeTile)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Day page

/// The Day page: the day as free time, travel and events, with its clashes between
/// them, for today or tomorrow, and a way to add an event.
struct DayPage: View {
    @Bindable var model: QuickCalendarModel
    @Environment(\.island) private var island

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = model.now()
            let words = DayWords(format: QuickCalendarFormat(model: model))
            VStack(alignment: .leading, spacing: 6) {
                if model.access == .granted {
                    let plan = model.plan(model.dayShown, at: now)
                    header(Text(words.headline(plan)))
                    if !plan.allDay.isEmpty {
                        DayAllDayLine(plan: plan)
                    }
                    ScrollView(.vertical) {
                        DayRows(plan: plan, words: words)
                    }
                    .scrollIndicators(.automatic)
                } else {
                    header(Text("Your day"))
                    QuickAddAccessRow(model: model, purpose: "to find your free time")
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DayPageLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.refresh() }
    }

    private func header(_ title: Text) -> some View {
        HStack(spacing: 8) {
            title
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.islandPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            DaySwitch(selection: $model.dayShown)
            InputQuietButton(title: "New event", symbol: "plus") {
                InputCenter.shared.open(QuickCalendarFeature.modeID, on: island)
            }
            .accessibilityHint("Opens a box to type an event")
        }
        .frame(height: DayPageLayout.headerHeight)
    }
}

/// Today or tomorrow, as two words to pick between.
private struct DaySwitch: View {
    @Binding var selection: QuickDay

    var body: some View {
        HStack(spacing: 2) {
            ForEach(QuickDay.allCases) { day in
                let isSelected = day == selection
                Button { selection = day } label: {
                    Text(day.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.islandText(isSelected ? 0.95 : 0.5, on: .surface(0.12)))
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Capsule().fill(.islandSurface(isSelected ? 0.18 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.islandSurface(0.08)))
        .fixedSize()
    }
}

/// "All day: Mum's birthday".
private struct DayAllDayLine: View {
    let plan: DayPlan

    var body: some View {
        Text("All day: " + plan.allDay.map(Clashes.named).joined(separator: ", "))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.islandText(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: DayPageLayout.allDayHeight)
    }
}

/// The day's rows, as the Day page and the box show them; VoiceOver reads them as one.
struct DayRows: View {
    let plan: DayPlan
    let words: DayWords

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(plan.rows) { row in
                DayRow(row: row, plan: plan, words: words)
                    .frame(height: DayPageLayout.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.spoken(plan))
    }
}

private struct DayRow: View {
    let row: DayPlan.Row
    let plan: DayPlan
    let words: DayWords

    var body: some View {
        HStack(spacing: 7) {
            switch row {
            case .free(let span):
                mark(Capsule().fill(.islandHue(.success)).frame(width: 3, height: 12))
                Text(words.free(span, in: plan))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.islandText(0.75))
            case .travel(let span, let event):
                mark(Image(systemName: "car.fill").font(.system(size: 9)).foregroundStyle(.islandGraphic(0.45)))
                time(words.format.time(span.start), alpha: 0.45)
                Text(words.travel(to: event))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.islandText(0.5))
            case .event(let event):
                mark(Circle().fill(.islandAccent(.quickCalendar)).frame(width: 6, height: 6))
                time(words.format.range(event.start, event.end), alpha: 0.6)
                Text(Clashes.named(event))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.islandText(0.95))
                    .layoutPriority(1)
                if event.isOnline {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.islandGraphic(0.45))
                } else if let place = event.location {
                    Text("· " + place)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.islandText(0.5))
                }
            case .clash(let clash):
                mark(Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5)).foregroundStyle(.islandHue(.warning)))
                Text(words.marker(clash))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.islandHueText(.warning))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func mark(_ view: some View) -> some View {
        view.frame(width: 12)
    }

    private func time(_ text: String, alpha: Double) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.islandText(alpha))
            .fixedSize()
    }
}

// MARK: - Summarised in the box

/// "Summarise my day", typed in the box, or "what about Friday" after it: the day from
/// the calendar, worked out on this Mac, and a way to send just the words typed on to the
/// model after all.
struct DaySummaryAnswer: View {
    let model: QuickCalendarModel
    /// The day summed up: any day, gone by or to come.
    let day: Date
    let anyway: InputAnyway?

    /// The day as the box shows it, in words, for a follow-up asked of the model on this
    /// Mac: the date, and every row read out.
    static func words(model: QuickCalendarModel, day: Date) -> String {
        let format = QuickCalendarFormat(model: model)
        guard model.access == .granted else {
            return "\(format.longDay(day)): Calendar isn't allowed to be read, so the day wasn't summed up."
        }
        return "\(format.longDay(day)), from Calendar. " + DayWords(format: format).spoken(model.plan(on: day, at: model.now()))
    }

    var body: some View {
        let words = DayWords(format: QuickCalendarFormat(model: model))
        VStack(alignment: .leading, spacing: 6) {
            let plan = model.access == .granted ? model.plan(on: day, at: model.now()) : nil
            if let plan {
                Text(words.headline(plan))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.islandPrimary)
            }
            // Under the headline, so it is read before the rows scroll.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.islandGraphic(0.4))
                    .accessibilityHidden(true)
                Text(anyway.map { $0.onThisMac ? "Your day, from Calendar, on this Mac" : "Your day, from Calendar — not sent to \($0.name)" }
                    ?? "Your day, from Calendar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.islandText(0.45))
                    .lineLimit(1)
                if let anyway {
                    InputQuietButton(title: "Ask \(anyway.name) \(anyway.onThisMac ? "instead" : "anyway")", symbol: "arrow.up") { anyway.send() }
                        .fixedSize()
                        .accessibilityHint(anyway.onThisMac ? "Asks the words you typed instead" : "Sends only the words you typed, not your calendar")
                }
                Spacer(minLength: 0)
            }
            if let plan {
                if !plan.allDay.isEmpty {
                    DayAllDayLine(plan: plan)
                }
                DayRows(plan: plan, words: words)
            } else {
                QuickAddAccessRow(model: model, purpose: "to find your free time")
            }
        }
        .padding(.bottom, 2)
    }
}
