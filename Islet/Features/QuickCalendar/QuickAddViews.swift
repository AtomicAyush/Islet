import AppKit
import SwiftUI

// MARK: - The preview

/// Under the field in Event mode: when the event is, with chips to change it, the blanks
/// for its place and notes, a warning if it clashes, and Add.
struct QuickAddPreview: View {
    @Bindable var session: QuickAddSession
    @Environment(\.island) private var island
    @SwiftUI.FocusState private var focused: Field?

    enum Field {
        case location
        case notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickAddWhenRow(session: session)
            blanks
            if let clash = session.clashes.first {
                QuickAddClashLine(session: session, clash: clash, more: session.clashes.count - 1)
            }
            actions
        }
        .padding(.horizontal, 6)
        .onChange(of: session.locationFocus) { _, _ in focused = .location }
    }

    private var blanks: some View {
        HStack(spacing: 8) {
            QuickAddBlank(symbol: "mappin.and.ellipse", placeholder: "Location", text: $session.location,
                          isGuess: session.isLocationGuessed)
                .focused($focused, equals: .location)
                .onSubmit { focused = .notes }
            QuickAddBlank(symbol: "note.text", placeholder: "Notes", text: $session.notes, isGuess: false)
                .focused($focused, equals: .notes)
                // The last blank: Return there is done, and adds.
                .onSubmit { if session.canAdd { session.addFromButton() } }
        }
        .onExitCommand { island?.endTyping(.escape) }
        .onKeyPress(.escape) {
            island?.endTyping(.escape)
            return .handled
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            QuickAddFilledButton(title: "Add", isEnabled: session.canAdd) { session.addFromButton() }
                .help("Add to Calendar (⌘↩)")
                .accessibilityHint("Adds the event to your calendar")
            Text("⌘↩")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.islandText(0.4))
                .accessibilityHidden(true)
            InputQuietButton(title: "Cancel", symbol: "xmark") { session.cancel() }
                .help("Close without adding anything")
            Spacer(minLength: 0)
            if session.event == nil {
                Text(session.parsed.title.isEmpty ? "Type what it is" : "Type a day or a time")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.5))
            }
        }
    }
}

/// When the event is: its day, its time and length, and all day, each a chip that
/// changes it. A time guessed from an hour alone ends in "?".
private struct QuickAddWhenRow: View {
    let session: QuickAddSession

    var body: some View {
        let format = QuickCalendarFormat(model: session.model)
        HStack(spacing: 5) {
            if !session.parsed.title.isEmpty {
                // The title as it will be added, read from what was typed: the chips
                // keep their room, and a long one is cut short.
                Text(session.parsed.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.islandText(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 2)
            }
            if let when = session.when {
                dayMenu(format, current: when.start)
                if !when.isAllDay {
                    timeMenu(format, start: when.start, end: when.end)
                    lengthMenu(format, minutes: Int(when.end.timeIntervalSince(when.start) / 60))
                }
                QuickAddChip(title: "All day", symbol: when.isAllDay ? "checkmark" : nil, isOn: when.isAllDay) {
                    session.allDayChoice = !when.isAllDay
                }
                .accessibilityAddTraits(when.isAllDay ? .isSelected : [])
                if let zone = session.parsed.typedZone, session.dayChoice == nil, session.timeChoice == nil {
                    Text("(\(zone))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.islandText(0.5))
                        .lineLimit(1)
                }
            } else {
                Text("When?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandText(0.6))
                dayMenu(format, current: nil)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(format.spoken(session))
    }

    private func dayMenu(_ format: QuickCalendarFormat, current: Date?) -> some View {
        Menu {
            ForEach(format.nextDays(), id: \.self) { day in
                Button(format.longDay(day)) { session.dayChoice = day }
            }
        } label: {
            QuickAddChip(title: current.map(format.day) ?? "Pick a day", symbol: "calendar")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Day: \(current.map(format.longDay) ?? "none")")
    }

    private func timeMenu(_ format: QuickCalendarFormat, start: Date, end: Date) -> some View {
        let guessed = session.parsed.flags.contains(.guessedHour) && session.timeChoice == nil
        return Menu {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minutes in
                Button(format.time(minutes: minutes, on: start)) { session.timeChoice = minutes }
            }
        } label: {
            QuickAddChip(title: format.range(start, end) + (guessed ? "?" : ""), symbol: "clock", isGuess: guessed)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Time: \(format.range(start, end))\(guessed ? ", a guess" : "")")
    }

    private func lengthMenu(_ format: QuickCalendarFormat, minutes: Int) -> some View {
        Menu {
            ForEach(QuickCalendarFeature.previewLengths, id: \.self) { length in
                Button(format.length(length)) { session.lengthChoice = length }
            }
        } label: {
            QuickAddChip(title: format.length(minutes), symbol: "hourglass")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Length: \(format.length(minutes))")
    }
}

/// A clash with the rest of the day, as a warning: Add still works.
private struct QuickAddClashLine: View {
    let session: QuickAddSession
    let clash: Clash
    let more: Int

    var body: some View {
        let format = QuickCalendarFormat(model: session.model)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.islandHue(.warning))
                .accessibilityHidden(true)
            Text(Clashes.line(clash, for: QuickAddSession.candidateID, time: format.time) + (more > 0 ? " (+\(more) more)" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.islandText(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A blank to fill in, or leave for later: a symbol, and a one-line field.
private struct QuickAddBlank: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    let isGuess: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.5, on: .surface(0.08)))
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.islandText(0.4, on: .surface(0.08)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // No title: the placeholder above is the only one drawn.
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.islandPrimary)
                    .accessibilityLabel(placeholder)
            }
            .font(.system(size: 11.5))
            if isGuess {
                Text("guess")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.islandText(0.5, on: .surface(0.08)))
                    .help("Read from what you typed")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.islandSurface(0.08)))
    }
}

/// A chip in the preview: a word, with a symbol, to change what it says.
struct QuickAddChip: View {
    let title: String
    var symbol: String?
    var isGuess = false
    var isOn = false
    var action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        let wash = isOn ? 0.2 : isHovering ? 0.16 : 0.1
        return HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.islandText(isGuess ? 0.65 : 0.9, on: .surface(wash)))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(.islandSurface(wash)))
        .contentShape(Capsule())
        .fixedSize()
        .onHover { isHovering = $0 }
    }
}

/// A button filled with Quick Calendar's colour: Add.
struct QuickAddFilledButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        let paint = theme.filledButton(.quickCalendar)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(paint.label)
                .padding(.horizontal, 12)
                .frame(height: 20)
                .background(Capsule().fill(paint.fill))
                .brightness(isHovering && isEnabled ? 0.08 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Rows in place of the preview

/// Without access: the offer, or where to turn it on.
struct QuickAddAccessRow: View {
    let model: QuickCalendarModel
    /// What access is for, after "Islet needs your calendar".
    var purpose = "to add events"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.islandHue(.warning))
                .accessibilityHidden(true)
            switch model.access {
            case .undetermined:
                Text("Islet needs your calendar \(purpose)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.islandText(0.8))
                InputQuietButton(title: "Allow Calendar access", symbol: "lock.open") { model.requestAccess() }
            case .denied:
                Text("Calendar access is off")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.islandText(0.8))
                InputQuietButton(title: "Open Privacy Settings", symbol: "gearshape") { CalendarApp.openPrivacySettings() }
            case .restricted, .granted:
                Text("Calendar access is restricted on this Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.islandText(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .onAppear { model.refresh() }
    }
}

/// After Add: where it went, and Undo for a while; after Undo, what happened.
struct QuickAddOutcomeRow: View {
    let session: QuickAddSession

    var body: some View {
        HStack(spacing: 6) {
            switch session.outcome {
            case .added(let added):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.islandHue(.success))
                    .accessibilityHidden(true)
                Text("Added to \(added.calendarTitle)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.islandText(0.85))
                InputQuietButton(title: "Undo", symbol: "arrow.uturn.backward") { session.undo() }
                    .help("Take the event away again")
            case .removed(let calendar):
                Text("Removed from \(calendar)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.islandText(0.7))
            case .changedSince:
                Text("Changed since — open Calendar")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.islandText(0.7))
            case .failed(let problem):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.islandHue(.warning))
                    .accessibilityHidden(true)
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.islandText(0.8))
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }
}

/// The chip after the field in Event mode: the calendar the event goes to, and a menu of
/// the others.
struct QuickAddCalendarChip: View {
    let session: QuickAddSession

    var body: some View {
        let model = session.model
        let chosen = session.calendarID ?? model.chosenCalendarID
        let title = model.calendarTitle(chosen) ?? "Calendar"
        Menu {
            Button {
                session.calendarID = nil
            } label: {
                if session.calendarID == nil {
                    Label("As in Settings", systemImage: "checkmark")
                } else {
                    Text("As in Settings")
                }
            }
            Divider()
            ForEach(model.calendars) { calendar in
                Button {
                    session.calendarID = calendar.id
                } label: {
                    if session.calendarID == calendar.id {
                        Label(calendar.title, systemImage: "checkmark")
                    } else {
                        Text(calendar.title)
                    }
                }
            }
        } label: {
            InputChipLabel(title: title, symbol: "calendar", tint: .quickCalendar)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Adding to \(title)")
        .accessibilityHint("Chooses the calendar")
    }
}

// MARK: - Words

/// Days, times and lengths as Quick Calendar says them, in the locale and time zone
/// events are read in.
@MainActor
struct QuickCalendarFormat {
    let calendar: Calendar
    let locale: Locale
    let now: Date

    init(model: QuickCalendarModel) {
        calendar = model.calendar
        locale = model.locale
        now = model.now()
    }

    init(calendar: Calendar, locale: Locale, now: Date) {
        self.calendar = calendar
        self.locale = locale
        self.now = now
    }

    private func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// "Today", "Tomorrow", "Tue 29 Sep".
    func day(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return formatter("EEEdMMM").string(from: date)
    }

    /// "Tuesday 29 September".
    func longDay(_ date: Date) -> String {
        formatter("EEEEdMMMM").string(from: date)
    }

    func time(_ date: Date) -> String {
        formatter("jmm").string(from: date)
    }

    func time(minutes: Int, on day: Date) -> String {
        time(calendar.date(minutes: minutes, into: day) ?? calendar.startOfDay(for: day))
    }

    /// "today", "tomorrow", "Tue 29 Sep": the day in a sentence.
    func dayInSentence(_ date: Date) -> String {
        let day = day(date)
        return day == "Today" || day == "Tomorrow" ? day.lowercased() : day
    }

    /// "3:00 – 4:00 pm", "15:00 – 16:00"; "23:30 – 00:30 +1" when it ends on a later day
    /// than it starts, rather than both dates in full.
    func range(_ start: Date, _ end: Date) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
        let days = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        if days > 0 { return "\(time(start)) – \(time(end)) +\(days)" }
        // Ending at midnight: its day is the start's.
        if !calendar.isDate(start, inSameDayAs: end) { return "\(time(start)) – \(time(end))" }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: start, to: end)
    }

    /// "30 min", "1 h", "1 h 30".
    func length(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
    }

    /// Today and the week after it, for the day's menu.
    func nextDays() -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// The preview as VoiceOver reads it: "Dentist, Tuesday 29 September, 3:00 – 4:00
    /// pm, clashes with Standup".
    func spoken(_ session: QuickAddSession) -> String {
        var parts = [session.parsed.title.isEmpty ? "New event" : session.parsed.title]
        if let when = session.when {
            parts.append(longDay(when.start))
            parts.append(when.isAllDay ? "all day" : range(when.start, when.end))
        } else {
            parts.append("no day or time yet")
        }
        if let clash = session.clashes.first {
            let line = Clashes.line(clash, for: QuickAddSession.candidateID, time: time)
            parts.append(line.prefix(1).lowercased() + line.dropFirst())
        }
        return parts.joined(separator: ", ")
    }
}
