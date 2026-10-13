import Foundation

// Subset of the Calendar API v3 Event resource that Smart Schedule reads and writes.
// Synthesized Codable skips nil optionals, which is exactly what PATCH semantics need.

struct GCalEvent: Codable, Sendable {
    var id: String?
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var colorId: String?
    var start: GCalDateTime?
    var end: GCalDateTime?
    var recurrence: [String]?
    var recurringEventId: String?
    var reminders: GCalReminders?
    var attendees: [GCalAttendee]?
    var conferenceData: GCalConferenceData?
    var extendedProperties: GCalExtendedProperties?
    var hangoutLink: String?
    var htmlLink: String?
}

struct GCalDateTime: Codable, Sendable {
    var date: String?        // all-day: "2026-10-15" (end is exclusive)
    var dateTime: String?    // "2026-10-14T14:00:00" (+ timeZone) or RFC3339 with offset
    var timeZone: String?    // IANA, required for recurring events
}

struct GCalReminders: Codable, Sendable {
    struct Override: Codable, Sendable {
        var method: String   // "popup" | "email"
        var minutes: Int     // 0...40320
    }
    var useDefault: Bool
    var overrides: [Override]?
}

struct GCalAttendee: Codable, Sendable {
    var email: String
}

struct GCalConferenceData: Codable, Sendable {
    struct CreateRequest: Codable, Sendable {
        struct SolutionKey: Codable, Sendable { var type: String }
        var requestId: String
        var conferenceSolutionKey: SolutionKey
    }
    struct EntryPoint: Codable, Sendable {
        var entryPointType: String?
        var uri: String?
    }
    var createRequest: CreateRequest?
    var entryPoints: [EntryPoint]?

    static func meet(requestID: String) -> GCalConferenceData {
        GCalConferenceData(createRequest: .init(requestId: requestID, conferenceSolutionKey: .init(type: "hangoutsMeet")))
    }
}

struct GCalExtendedProperties: Codable, Sendable {
    var `private`: [String: String]?
    var shared: [String: String]?
}

struct GCalEventList: Decodable, Sendable {
    var items: [GCalEvent]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

/// Keys written to `extendedProperties.private` so events created by Smart Schedule can be found,
/// grouped into plans and round-tripped without parsing titles. Queryable with
/// `privateExtendedProperty=ssPlanId=<id>` on events.list.
enum SSProperty {
    static let source = "ssSource"     // "smart-schedule"
    static let kind = "ssKind"         // ScheduleEvent.Kind raw value
    static let planID = "ssPlanId"
    static let schema = "ssSchema"     // bump when the mapping changes
}

/// Google Calendar event colorIds (fixed palette) → hex used for chips.
enum GoogleColor {
    static let palette: [String: String] = [
        "1": "#7986CB", "2": "#33B679", "3": "#8E24AA", "4": "#E67C73",
        "5": "#F6BF26", "6": "#F4511E", "7": "#039BE5", "8": "#616161",
        "9": "#3F51B5", "10": "#0B8043", "11": "#D50000"
    ]
    static let calendarDefault = "#039BE5"

    /// Kind → colorId, matching the artboards (gym = green, deadline = orange).
    static func colorID(for kind: ScheduleEvent.Kind) -> String? {
        switch kind {
        case .event: nil            // inherit the calendar color
        case .task: "5"             // Banana
        case .deadline: "6"         // Tangerine
        case .routine: "10"         // Basil
        }
    }
}
