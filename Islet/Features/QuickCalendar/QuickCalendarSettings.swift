import SwiftUI

/// Quick Calendar's options: where events go, how long they last, asking for a missing
/// place, the time allowed to get somewhere, the person's day, the calendars checked for
/// clashes, and being told of them.
struct QuickCalendarSettings: View {
    let model: QuickCalendarModel
    @AppStorage(QuickCalendarFeature.Key.calendar) private var calendarID = ""
    @AppStorage(QuickCalendarFeature.Key.length) private var length = QuickCalendarFeature.defaultLength
    @AppStorage(QuickCalendarFeature.Key.askDetails) private var askDetails = true
    @AppStorage(QuickCalendarFeature.Key.askAfter) private var askAfter = QuickCalendarFeature.defaultAskAfter
    @AppStorage(QuickCalendarFeature.Key.travel) private var travel = QuickCalendarFeature.defaultTravel
    @AppStorage(QuickCalendarFeature.Key.dayFrom) private var dayFrom = QuickCalendarFeature.defaultDayFrom
    @AppStorage(QuickCalendarFeature.Key.dayTo) private var dayTo = QuickCalendarFeature.defaultDayTo
    @AppStorage(QuickCalendarFeature.Key.tellClashes) private var tellClashes = true

    var body: some View {
        Picker("Add events to", selection: $calendarID) {
            Text("Default calendar").tag("")
            ForEach(model.calendars) { calendar in
                Text(calendar.title).tag(calendar.id)
            }
            // A calendar chosen before, gone or not readable now, still has a row.
            if !calendarID.isEmpty, !model.calendars.contains(where: { $0.id == calendarID }) {
                Text("A calendar not available now").tag(calendarID)
            }
        }
        Picker("Default length", selection: $length) {
            ForEach(QuickCalendarFeature.lengthChoices, id: \.self) { minutes in
                Text(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "1 hour \(minutes - 60) minutes").tag(minutes)
            }
        }
        Toggle(isOn: $askDetails) {
            Text("Ask about missing details")
            Text("An event added without a place, and not online, is asked about later on a card: add a place, not now, or don't ask. Islet keeps only the event's identifiers and times for this, never its title or notes.")
        }
        Picker("After", selection: $askAfter) {
            ForEach(QuickCalendarFeature.askAfterChoices, id: \.self) { hours in
                Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(hours)
            }
        }
        .disabled(!askDetails)
        Picker(selection: $travel) {
            ForEach(QuickCalendarFeature.travelChoices, id: \.self) { minutes in
                Text(minutes == 0 ? "None" : "\(minutes) minutes").tag(minutes)
            }
        } label: {
            Text("Travel time")
            Text("Allowed to get to an event with a place, from one somewhere else. An event that leaves less is shown as a clash.")
        }
        LabeledContent("Your day") {
            HStack(spacing: 6) {
                Picker("From", selection: $dayFrom) {
                    ForEach(Self.hours(from: 0, to: 12), id: \.self) { Text(time($0)).tag($0) }
                }
                Picker("To", selection: $dayTo) {
                    ForEach(Self.hours(from: 14, to: 24), id: \.self) { Text(time($0)).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .help("The hours Summarise looks for free time in")
        LabeledContent("Calendars to check") {
            Menu(checkedSummary) {
                ForEach(model.eventCalendars) { calendar in
                    Toggle(calendar.title, isOn: Binding(
                        get: { !model.uncheckedCalendars.contains(calendar.id) },
                        set: { model.setChecked($0, calendarID: calendar.id) }
                    ))
                }
            }
            .fixedSize()
            .disabled(model.eventCalendars.isEmpty)
        }
        Toggle(isOn: $tellClashes) {
            Text("Tell me about clashes")
            Text("A card, once for each clash today or tomorrow: two events that overlap, or too little time to get from one to the other.")
        }
        .onChange(of: tellClashes) { _, _ in model.clashes.review() }
        LabeledContent("Calendar access") {
            switch model.access {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .undetermined:
                Button("Allow…") { model.requestAccess() }
            case .denied, .restricted:
                HStack {
                    Text(model.access == .denied ? "Off" : "Restricted").foregroundStyle(.secondary)
                    Button("Open Privacy Settings…") { CalendarApp.openPrivacySettings() }
                }
            }
        }
        .onAppear { model.refresh() }
        Text("What you type is read on this Mac and never sent anywhere, and your day is worked out here too: your calendar is never sent to ChatGPT or Claude. Apple's model on this Mac alone may read it, in Ask mode, while Quick Ask's switch lets it, and is given your day summed up for a follow-up. Only Add writes to your calendar: the event shown, or the place typed on a card.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "All calendars", "3 of 5".
    private var checkedSummary: String {
        let all = model.eventCalendars
        let checked = all.filter { !model.uncheckedCalendars.contains($0.id) }.count
        return checked == all.count ? "All calendars" : "\(checked) of \(all.count)"
    }

    /// Whole hours, in minutes after midnight.
    private static func hours(from: Int, to: Int) -> [Int] {
        (from...to).map { $0 * 60 }
    }

    private func time(_ minutes: Int) -> String {
        minutes == 24 * 60 ? "Midnight" : QuickCalendarFormat(model: model).time(minutes: minutes, on: model.now())
    }
}
