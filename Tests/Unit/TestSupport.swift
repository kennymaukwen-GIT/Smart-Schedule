import Foundation
import XCTest

// Shared/ is compiled straight into this bundle (no @testable import), so helper names here must not
// collide with any type in Shared/.

/// Fixed zone and explicit instants, so assertions never depend on the machine's time zone or locale.
enum TestClock {
    static let zone = TimeZone(identifier: "Europe/London")!
    static let clock = WallClock(timeZone: zone)

    /// An absolute instant written in UTC.
    static func utc(_ year: Int, _ month: Int, _ day: Int,
                    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        date(in: TimeZone(identifier: "UTC")!, year, month, day, hour, minute, second)
    }

    /// An instant written as London wall-clock time. Built without `WallClock` so WallClock tests stay independent.
    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        date(in: zone, year, month, day, hour, minute, 0)
    }

    private static func date(in zone: TimeZone, _ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }
}

/// Tests/fixtures is copied into the bundle as a folder reference named "fixtures".
enum Fixtures {
    private final class BundleToken {}

    static func directory() throws -> URL {
        try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "fixtures", withExtension: nil),
                      "Tests/fixtures must be a folder resource of SmartScheduleCoreTests")
    }

    static func allNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory().path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    static func root(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory().appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
    }

    /// `expected_call.name` and `expected_call.args` re-serialized on its own, i.e. what Gemini would send as `args`.
    static func call(_ name: String) throws -> (name: String, args: Data) {
        let call = try XCTUnwrap(root(name)["expected_call"] as? [String: Any], name)
        let function = try XCTUnwrap(call["name"] as? String, name)
        let args = try XCTUnwrap(call["args"] as? [String: Any], name)
        let data = try JSONSerialization.data(withJSONObject: args)
        return (function, data)
    }

    static func args<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try TestJSON.decode(type, data: call(name).args)
    }

    static func utterance(_ name: String) throws -> String {
        try XCTUnwrap(root(name)["utterance"] as? String, name)
    }
}

enum TestJSON {
    /// Same decoder configuration as `GeminiFunctionCall.decode`.
    static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try decode(type, data: Data(json.utf8))
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Top-level JSON object of an encoded value, to assert which keys are present.
    static func object<T: Encodable>(encoding value: T) throws -> [String: Any] {
        try object(JSONEncoder().encode(value))
    }
}

enum TestEvents {
    static func make(id: String,
                     title: String = "Event",
                     start: Date,
                     end: Date,
                     allDay: Bool = false,
                     kind: ScheduleEvent.Kind = .event,
                     seriesID: String? = nil,
                     planID: String? = nil,
                     colorHex: String = GoogleColor.calendarDefault,
                     calendar: CalendarRef? = nil,
                     iCalUID: String? = nil,
                     isOrganizer: Bool? = nil,
                     usesCalendarColor: Bool? = nil) -> ScheduleEvent {
        ScheduleEvent(
            id: id,
            seriesID: seriesID,
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            kind: kind,
            colorHex: colorHex,
            location: nil,
            meetURL: nil,
            notes: nil,
            reminderMinutes: nil,
            planID: planID,
            htmlLink: nil,
            accountID: calendar?.accountID,
            calendarID: calendar?.calendarID,
            iCalUID: iCalUID,
            isOrganizer: isOrganizer,
            usesCalendarColor: usesCalendarColor
        )
    }
}

/// Temporary App Group stand-ins: a hostless test bundle has no App Group, so stores get explicit files.
final class TemporaryStoreFiles {
    private var urls: [URL] = []

    func url(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        urls.append(url)
        return url
    }

    func removeAll() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
    }
}

enum SampleAccounts {
    static func calendar(_ accountID: String, _ calendarID: String,
                         email: String? = nil,
                         name: String? = nil,
                         primary: Bool = false,
                         role: String = "owner",
                         hex: String = CalendarInfo.defaultColorHex,
                         visible: Bool = true,
                         notifications: Bool = true) -> CalendarInfo {
        CalendarInfo(accountID: accountID, accountEmail: email ?? "\(accountID)@example.com", calendarID: calendarID,
                     name: name ?? calendarID, isPrimary: primary, accessRole: role, googleColorHex: hex,
                     isVisible: visible, notificationsEnabled: notifications)
    }

    /// An account whose primary calendar id is its email, as Google does it.
    static func account(_ id: String, email: String, extra: [CalendarInfo] = []) -> GoogleAccount {
        GoogleAccount(id: id, email: email, connectedAt: TestClock.utc(2026, 10, 1),
                      grantedScopes: [GoogleAccount.calendarListScope],
                      calendars: [calendar(id, email, email: email, name: email, primary: true)] + extra)
    }
}
