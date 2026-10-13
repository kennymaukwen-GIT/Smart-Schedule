import Foundation

/// Text of the morning briefing ("Today") and the evening preview ("Tomorrow"):
///
///     4 events, first at 09:00
///     All day · Holiday
///     09:00 Weekly team sync
///     …up to 6 lines
///     +2 more
///     Not sent as reminders: Gym, Reply to Joe
///
/// Built when the notification is scheduled, so it is only as fresh as the last reschedule, which runs after every
/// write, sync, launch, background refresh and preference change.
enum BriefingBuilder {
    struct Content: Hashable, Sendable {
        var title: String
        var body: String
    }

    static let maxLines = 6

    /// nil when the day has no events and no reminders held back by the daily cap.
    static func build(kind: PlannedBriefing.Kind,
                      day: Date,
                      events: [ScheduleEvent],
                      cappedTitles: [String] = [],
                      clock: WallClock) -> Content? {
        let listed = self.events(on: day, from: events, clock: clock)
        guard !listed.isEmpty || !cappedTitles.isEmpty else { return nil }

        var lines: [String] = []
        if let summary = summary(listed, clock: clock) { lines.append(summary) }
        for event in listed.prefix(maxLines) {
            lines.append(event.isAllDay
                ? String(localized: "All day") + " · " + event.title
                : time(event.start, clock: clock) + " " + event.title)
        }
        if listed.count > maxLines {
            lines.append(String(localized: "+\(listed.count - maxLines) more"))
        }
        if !cappedTitles.isEmpty {
            let titles = cappedTitles.joined(separator: ReminderText.separator)
            lines.append(String(localized: "Not sent as reminders: \(titles)"))
        }
        let title = kind == .morning ? String(localized: "Today") : String(localized: "Tomorrow")
        return Content(title: title, body: lines.joined(separator: "\n"))
    }

    /// Timed events starting on `day` and all-day events covering it; all-day first, then by start. Completed items
    /// and drafts (not in the calendar yet) are left out.
    static func events(on day: Date, from events: [ScheduleEvent], clock: WallClock) -> [ScheduleEvent] {
        let calendar = clock.calendar
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: max(start, end))
        return events
            .filter { event in
                guard !event.isCompleted, !event.isDraft else { return false }
                return event.isAllDay ? event.intersects(interval) : (event.start >= start && event.start < end)
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return (lhs.start, lhs.title) < (rhs.start, rhs.title)
            }
    }

    /// "4 events, first at 09:00" / "1 event, at 09:00" / "2 events, all day".
    private static func summary(_ events: [ScheduleEvent], clock: WallClock) -> String? {
        guard !events.isEmpty else { return nil }
        let count = events.count
        if let first = events.first(where: { !$0.isAllDay }) {
            let at = time(first.start, clock: clock)
            return count == 1 ? String(localized: "1 event, at \(at)") : String(localized: "\(count) events, first at \(at)")
        }
        return count == 1 ? String(localized: "1 event, all day") : String(localized: "\(count) events, all day")
    }

    private static func time(_ date: Date, clock: WallClock) -> String {
        ReminderText.clock(ReminderPlanner.minuteOfDay(date, clock: clock))
    }
}
