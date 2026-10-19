import Foundation

/// The list a tapped day in the month grid opens (`DayAgendaSheet`): every event on the day, all-day ones first, then
/// by the time they start on that day. Pure, so the order and the times shown are tested without a screen.
enum DayAgenda {
    /// How an event sits on the day.
    enum Timing: Equatable, Sendable {
        /// All day, or a multi-day event that covers the whole day.
        case allDay
        /// `start` is nil when the event began on an earlier day, `end` is nil when it goes on past this day.
        case timed(start: Date?, end: Date?)
    }

    struct Item: Equatable, Identifiable, Sendable {
        let event: ScheduleEvent
        let timing: Timing
        var id: String { event.id }
    }

    /// Everything on `day` (its local midnight to the next, 23 or 25 hours on clock-change days): all-day events and
    /// days a longer event covers completely first, then by the time each starts on the day (an event from an earlier
    /// day counts from midnight), the longer first when two start together.
    static func items(on day: Date, events: [ScheduleEvent], calendar: Calendar) -> [Item] {
        let interval = CalendarPaging.dayInterval(containing: day, calendar: calendar)
        return events
            .filter { $0.intersects(interval) }
            .map { Item(event: $0, timing: timing(of: $0, on: interval)) }
            .sorted { precedes($0, $1, on: interval) }
    }

    static func timing(of event: ScheduleEvent, on day: DateInterval) -> Timing {
        if event.isAllDay || (event.start <= day.start && event.end >= day.end) { return .allDay }
        return .timed(start: event.start >= day.start ? event.start : nil,
                      end: event.end <= day.end ? event.end : nil)
    }

    private static func precedes(_ lhs: Item, _ rhs: Item, on day: DateInterval) -> Bool {
        let lhsAllDay = lhs.timing == .allDay, rhsAllDay = rhs.timing == .allDay
        if lhsAllDay != rhsAllDay { return lhsAllDay }
        let lhsStart = max(lhs.event.start, day.start), rhsStart = max(rhs.event.start, day.start)
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        if lhs.event.end != rhs.event.end { return lhs.event.end > rhs.event.end }
        return lhs.event.id < rhs.event.id
    }
}
