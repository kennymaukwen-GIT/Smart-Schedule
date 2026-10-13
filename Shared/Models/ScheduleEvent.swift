import Foundation

/// Provider-agnostic event shared across all three processes through the App Group cache.
struct ScheduleEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case event      // meetings, appointments
        case task       // "Reply to…", "Pay bills" — rendered with a checkbox
        case deadline   // "Deadline for Plan 5008" — orange chip
        case routine    // sessions generated from a long-term plan
    }

    var id: String                 // Google event id (instance id for expanded recurrences)
    var seriesID: String?          // Google `recurringEventId`
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var kind: Kind
    var colorHex: String
    var location: String?
    var meetURL: URL?
    var notes: String?
    var reminderMinutes: [Int]?
    var planID: String?
    var htmlLink: URL?
    var isCompleted: Bool = false
    // Which connected calendar this copy came from. All nil for demo, draft and pre-migration events.
    var accountID: String? = nil
    var calendarID: String? = nil
    /// Same for every copy of one meeting across accounts (and for every instance of a series).
    var iCalUID: String? = nil
    /// The account owning this copy organises the event (Google `organizer.self`).
    var isOrganizer: Bool? = nil
    /// No colorId of its own: drawn in its calendar's colour, so a local colour override applies.
    var usesCalendarColor: Bool? = nil

    /// Cache identity: the same Google id can be cached once per calendar.
    var ref: EventRef { EventRef(accountID: accountID, calendarID: calendarID, eventID: id) }

    var calendarRef: CalendarRef? {
        guard let accountID, let calendarID else { return nil }
        return CalendarRef(accountID: accountID, calendarID: calendarID)
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func overlaps(_ other: ScheduleEvent) -> Bool {
        !isAllDay && !other.isAllDay && start < other.end && other.start < end && id != other.id
    }

    func intersects(_ interval: DateInterval) -> Bool {
        start < interval.end && end > interval.start
    }
}

/// A morning nudge attached to a long-term plan ("set notification every morning…", Artboard 5).
struct PlanNudge: Codable, Hashable, Sendable {
    var planID: String
    var hour: Int
    var minute: Int
    var message: String
    var endsOn: Date
}
