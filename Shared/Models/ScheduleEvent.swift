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
    /// Google's version of this copy, sent as If-Match so an edit never lands on a newer Google edit unseen.
    var etag: String? = nil
    /// Changed on this iPhone and waiting in the outbox for Google (offline, or Google unreachable).
    var isPendingSync: Bool? = nil
    /// Things this event may need that the assistant suggested when it created the event (`create_events`
    /// `suggested_notes`) or on the event page ("✨ AI suggestions"), offered as chips under its notes. Local only:
    /// never part of a Google write (the mapper and `EventEdit` ignore it) and kept across listings by
    /// `ScheduleEvent.keepingLocalFields`. nil = none; [] = cleared.
    var suggestedNotes: [String]? = nil

    var isWaitingToSync: Bool { isPendingSync == true }

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

extension ScheduleEvent {
    /// Local-only fields that a Google listing, a refresh or an outbox overlay does not carry
    /// (`suggestedNotes`): a copy in `events` that comes back without them keeps what the same copy (`EventRef`) had
    /// in `previous`; a new occurrence of a series takes what its series had. Copies that have their own value keep
    /// it, so `[]` (cleared) is never refilled.
    static func keepingLocalFields(_ events: inout [ScheduleEvent], from previous: [ScheduleEvent]) {
        var byRef: [EventRef: [String]] = [:]
        var bySeries: [EventRef: [String]] = [:]
        for event in previous {
            guard let notes = event.suggestedNotes else { continue }
            byRef[event.ref] = notes
            let series = event.seriesRef
            if bySeries[series] == nil { bySeries[series] = notes }
        }
        guard !byRef.isEmpty else { return }
        for index in events.indices where events[index].suggestedNotes == nil {
            let event = events[index]
            if let notes = byRef[event.ref] ?? bySeries[event.seriesRef] {
                events[index].suggestedNotes = notes
            }
        }
    }

    /// The series this copy belongs to in its calendar (the copy itself when it is not an occurrence).
    var seriesRef: EventRef {
        EventRef(accountID: accountID, calendarID: calendarID, eventID: seriesID ?? id)
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
