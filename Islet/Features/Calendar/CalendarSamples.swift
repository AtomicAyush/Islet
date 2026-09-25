import SwiftUI

/// Stand-in events for the previews, placed around the current time so every
/// presentation can be seen without calendar access.
extension CalendarEvent {
    private static func sample(
        _ title: String,
        start: Date,
        minutes: Double,
        allDay: Bool = false,
        location: String? = nil,
        color: Color,
        meeting: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: "sample.\(title)",
            eventIdentifier: nil,
            occurrence: nil,
            title: title,
            start: start,
            end: start.addingTimeInterval(minutes * 60),
            isAllDay: allDay,
            location: location,
            color: color,
            meeting: meeting.flatMap(URL.init(string:)).flatMap(MeetingLink.init(url:))
        )
    }

    /// A video call a hair under five minutes away, so it reads "5m" for the whole
    /// preview.
    static func sampleMeeting() -> CalendarEvent {
        let zoom = "https://us02web.zoom.us/j/5550123456?pwd=islet"
        return sample(
            "Design sync", start: Date().addingTimeInterval(5 * 60 - 1), minutes: 30,
            location: zoom, color: CalendarPalette.blue, meeting: zoom
        )
    }

    static func sampleStartingNow() -> CalendarEvent {
        sample(
            "Team standup", start: Date(), minutes: 15,
            location: "Maple Room, 4th floor", color: CalendarPalette.orange
        )
    }

    /// One event under way, one later on, and an all-day one, on the half hours
    /// around now.
    static func sampleDay() -> [CalendarEvent] {
        let now = Date()
        let halfHour: TimeInterval = 30 * 60
        let next = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / halfHour).rounded(.up) * halfHour)
        let today = Calendar.current.startOfDay(for: now)
        return [
            sample("Birthday: Priya", start: today, minutes: 24 * 60, allDay: true, color: CalendarPalette.green),
            sample(
                "Product review", start: next.addingTimeInterval(-halfHour * 2), minutes: 90,
                location: "Studio", color: CalendarPalette.purple
            ),
            sample(
                "1:1 with Maya", start: next.addingTimeInterval(halfHour * 2), minutes: 30,
                color: CalendarPalette.blue, meeting: "https://meet.google.com/abc-defg-hij"
            ),
        ]
    }
}
