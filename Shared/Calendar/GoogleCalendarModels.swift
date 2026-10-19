import Foundation

// Subset of the Calendar API v3 Event resource that Smart Schedule reads and writes.
// Synthesized Codable skips nil optionals, which is exactly what PATCH semantics need.

struct GCalEvent: Codable, Equatable, Sendable {
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
    /// Same in every attendee's calendar and for every instance of a series (read only).
    var iCalUID: String?
    var organizer: GCalPerson?
    /// The resource's version (read only, quotes included): sent back as If-Match on PATCH and DELETE.
    var etag: String?
    /// Last modification time, RFC3339 (read only).
    var updated: String?
}

struct GCalPerson: Codable, Equatable, Sendable {
    var email: String?
    var isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email
        case isSelf = "self"
    }
}

struct GCalDateTime: Codable, Equatable, Sendable {
    var date: String?        // all-day: "2026-10-15" (end is exclusive)
    var dateTime: String?    // "2026-10-14T14:00:00" (+ timeZone) or RFC3339 with offset
    var timeZone: String?    // IANA, required for recurring events
    /// PATCH only, when an event switches between all-day and timed: also sends the other form as `null`
    /// (`{"date": "2026-10-15", "dateTime": null}`). Google merges a PATCH's objects field by field and deletes a
    /// field only when it is sent as null, so without it the old form would stay next to the new one. Read back
    /// from JSON (the outbox file) when such a null is there.
    var clearsOtherForm = false

    private enum CodingKeys: String, CodingKey {
        case date, dateTime, timeZone
    }
}

// In an extension so the memberwise initializer stays available.
extension GCalDateTime {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        dateTime = try c.decodeIfPresent(String.self, forKey: .dateTime)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        let nullDate = c.contains(.date) ? ((try? c.decodeNil(forKey: .date)) ?? false) : false
        let nullDateTime = c.contains(.dateTime) ? ((try? c.decodeNil(forKey: .dateTime)) ?? false) : false
        clearsOtherForm = nullDate || nullDateTime
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(dateTime, forKey: .dateTime)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
        if clearsOtherForm {
            if date == nil { try c.encodeNil(forKey: .date) }
            if dateTime == nil { try c.encodeNil(forKey: .dateTime) }
        }
    }
}

struct GCalReminders: Codable, Equatable, Sendable {
    struct Override: Codable, Equatable, Sendable {
        var method: String   // "popup" | "email"
        var minutes: Int     // 0...40320
    }
    var useDefault: Bool
    var overrides: [Override]?
}

struct GCalAttendee: Codable, Equatable, Sendable {
    var email: String
}

struct GCalConferenceData: Codable, Equatable, Sendable {
    struct CreateRequest: Codable, Equatable, Sendable {
        struct SolutionKey: Codable, Equatable, Sendable { var type: String }
        var requestId: String
        var conferenceSolutionKey: SolutionKey
    }
    struct EntryPoint: Codable, Equatable, Sendable {
        var entryPointType: String?
        var uri: String?
    }
    var createRequest: CreateRequest?
    var entryPoints: [EntryPoint]?

    static func meet(requestID: String) -> GCalConferenceData {
        GCalConferenceData(createRequest: .init(requestId: requestID, conferenceSolutionKey: .init(type: "hangoutsMeet")))
    }
}

struct GCalExtendedProperties: Codable, Equatable, Sendable {
    var `private`: [String: String]?
    var shared: [String: String]?
}

struct GCalEventList: Decodable, Sendable {
    var items: [GCalEvent]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

/// One entry of `users/me/calendarList` (needs the `calendar.calendarlist.readonly` scope).
struct GCalCalendarListEntry: Codable, Sendable {
    var id: String?
    var summary: String?
    var summaryOverride: String?
    var backgroundColor: String?    // "#9fe1e7": the calendar palette, not the event palette
    var accessRole: String?         // owner | writer | reader | freeBusyReader
    var primary: Bool?
    var selected: Bool?             // shown in Google Calendar's own list
    var hidden: Bool?
    var deleted: Bool?
    var timeZone: String?
}

struct GCalCalendarList: Decodable, Sendable {
    var items: [GCalCalendarListEntry]?
    var nextPageToken: String?
}

extension GCalCalendarListEntry {
    /// A calendar of `accountID` as first listed: visible when Google shows it (the primary calendar always),
    /// notifications on. `AccountStore.replaceCalendars` keeps the local settings of calendars it already knows.
    func calendarInfo(accountID: String, accountEmail: String) -> CalendarInfo? {
        guard let id, !id.isEmpty, hidden != true, deleted != true else { return nil }
        let isPrimary = primary == true
        return CalendarInfo(
            accountID: accountID,
            accountEmail: accountEmail,
            calendarID: id,
            name: summaryOverride.nonBlank ?? summary.nonBlank ?? id,
            isPrimary: isPrimary,
            accessRole: accessRole ?? "reader",
            googleColorHex: backgroundColor.flatMap(Self.normalizedHex) ?? CalendarInfo.defaultColorHex,
            timeZone: timeZone,
            isVisible: isPrimary || selected == true,
            colorOverrideHex: nil,
            notificationsEnabled: true
        )
    }

    /// "#9fe1e7" → "#9FE1E7"; nil for anything that is not #RRGGBB.
    static func normalizedHex(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard hex.count == 7, hex.hasPrefix("#"),
              hex.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

/// Keys written to `extendedProperties.private` so events created by Smart Schedule can be found,
/// grouped into plans and round-tripped without parsing titles. Queryable with
/// `privateExtendedProperty=ssPlanId=<id>` on events.list.
enum SSProperty {
    static let source = "ssSource"     // "smart-schedule"
    static let kind = "ssKind"         // ScheduleEvent.Kind raw value
    static let planID = "ssPlanId"
    static let schema = "ssSchema"     // bump when the mapping changes
    /// The reminders Smart Schedule itself sends: "default" (the kind's defaults) or minutes like "60,10".
    /// Google's own pop-ups may differ (none at all in "Smart Schedules only" mode).
    static let localReminders = "ssReminders"
    /// Departure reminders (`DepartureSettings`): minutes early to arrive ("30"), the travel mode ("transit") and the
    /// minutes before the start to leave ("62"). All three or none; no location, starting point or travel time.
    static let arriveEarly = "ssArriveEarly"
    static let travelMode = "ssTravelMode"
    static let leaveBefore = "ssLeaveBefore"
}

/// Google Calendar's fixed event colorIds → the colour Google Calendar shows for each, so an event keeps the colour
/// the user picked there. Only for colours that come from (or go to) Google; app-chosen colours live in Theme.
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
