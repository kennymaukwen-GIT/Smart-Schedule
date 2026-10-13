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
