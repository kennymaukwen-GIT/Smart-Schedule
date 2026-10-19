import XCTest

/// Departure reminders on the event (step 3): the three values in its private properties on Google Calendar, read and
/// written by the mapper. Events without them read exactly as before.
final class DepartureSettingsTests: XCTestCase {
    private let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())

    private func googleEvent(_ properties: [String: String]?) -> GCalEvent {
        var event = GCalEvent()
        event.id = "abc123"
        event.summary = "Meeting"
        event.location = "Taipei 101"
        event.start = GCalDateTime(dateTime: "2026-10-20T17:00:00+01:00")
        event.end = GCalDateTime(dateTime: "2026-10-20T18:00:00+01:00")
        event.extendedProperties = properties.map { GCalExtendedProperties(private: $0) }
        return event
    }

    private let saved = ["ssArriveEarly": "30", "ssTravelMode": "transit", "ssLeaveBefore": "62"]

    // MARK: Reading

    func testAnEventWithDepartureSettingsReadsThem() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: googleEvent(saved)))
        XCTAssertEqual(event.departure, DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit,
                                                         leaveMinutesBeforeStart: 62))
    }

    func testAnOlderEventReadsAsBefore() throws {
        let withNone = try XCTUnwrap(mapper.scheduleEvent(from: googleEvent(nil)))
        let withOthers = try XCTUnwrap(mapper.scheduleEvent(from: googleEvent(["ssKind": "event", "ssSchema": "1",
                                                                               "ssReminders": "default"])))
        XCTAssertNil(withNone.departure)
        XCTAssertNil(withOthers.departure)
        XCTAssertEqual(withOthers.kind, .event)
        XCTAssertNil(withOthers.reminderMinutes)
        XCTAssertEqual(withOthers.title, "Meeting")
        XCTAssertEqual(withOthers.location, "Taipei 101")
    }

    func testBadOrMissingValuesAreIgnored() {
        let cases: [[String: String]] = [
            ["ssArriveEarly": "30", "ssTravelMode": "transit"],                         // one missing
            ["ssArriveEarly": "thirty", "ssTravelMode": "transit", "ssLeaveBefore": "62"],
            ["ssArriveEarly": "30", "ssTravelMode": "bicycling", "ssLeaveBefore": "62"], // not a mode the app uses
            ["ssArriveEarly": "30", "ssTravelMode": "transit", "ssLeaveBefore": ""],
            ["ssArriveEarly": "-5", "ssTravelMode": "transit", "ssLeaveBefore": "62"],
            ["ssArriveEarly": "181", "ssTravelMode": "transit", "ssLeaveBefore": "200"],
            ["ssArriveEarly": "30", "ssTravelMode": "transit", "ssLeaveBefore": "1801"],
            ["ssArriveEarly": "30", "ssTravelMode": "transit", "ssLeaveBefore": "20"],   // leaving after arriving
            ["ssArriveEarly": " 30", "ssTravelMode": "transit", "ssLeaveBefore": "62"],
        ]
        for properties in cases {
            XCTAssertNil(CalendarEventMapper.departure(from: properties), "\(properties)")
        }
    }

    // MARK: Writing

    func testItWritesExactlyTheThreeValues() {
        let settings = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit, leaveMinutesBeforeStart: 62)
        XCTAssertEqual(CalendarEventMapper.departureProperties(settings), saved)
        let patch = mapper.departurePatch(settings)
        XCTAssertEqual(patch.extendedProperties?.private, saved, "no location, starting point or travel time")
        XCTAssertNil(patch.extendedProperties?.shared)
        XCTAssertNil(patch.summary)
        XCTAssertNil(patch.location)
        XCTAssertNil(patch.start)
        XCTAssertNil(patch.end)
        XCTAssertNil(patch.reminders)
        XCTAssertNil(patch.description)
    }

    func testWritingThenReadingGivesTheSameSettings() {
        for mode in TravelMode.allCases {
            for (early, leave) in [(0, 0), (0, 32), (30, 62), (180, 1_800)] {
                let settings = DepartureSettings(arriveEarlyMinutes: early, travelMode: mode, leaveMinutesBeforeStart: leave)
                XCTAssertEqual(CalendarEventMapper.departure(from: CalendarEventMapper.departureProperties(settings)),
                               settings, "\(mode) \(early) \(leave)")
            }
        }
    }

    func testValuesAreKeptInRange() {
        let tooBig = DepartureSettings(arriveEarlyMinutes: 999, travelMode: .driving, leaveMinutesBeforeStart: 99_999)
        XCTAssertEqual(tooBig.arriveEarlyMinutes, 180)
        XCTAssertEqual(tooBig.leaveMinutesBeforeStart, 1_800)
        let backwards = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .walking, leaveMinutesBeforeStart: 10)
        XCTAssertEqual(backwards.leaveMinutesBeforeStart, 30, "never leave after the time to arrive")
        let negative = DepartureSettings(arriveEarlyMinutes: -5, travelMode: .walking, leaveMinutesBeforeStart: -5)
        XCTAssertEqual([negative.arriveEarlyMinutes, negative.leaveMinutesBeforeStart], [0, 0])
        XCTAssertEqual(DepartureSettings.leaveRange, 0...1_800)
    }

    // MARK: From a plan, and back

    /// The owner's example: 17:00, 30 minutes early, 22 minutes by transit, 10 minutes' margin → leave 62 minutes
    /// before the start (15:58). The travel time itself is not kept.
    func testAPlanBecomesTheThreeValues() {
        let start = TestClock.local(2026, 10, 20, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22,
                                         travelMode: .transit, isEstimate: false)
        let settings = DeparturePlanner.settings(for: plan, start: start)
        XCTAssertEqual(settings, DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit, leaveMinutesBeforeStart: 62))
        XCTAssertEqual(settings.departAt(start: start), plan.departAt)
    }

    func testMovingTheEventMovesTheDeparture() {
        let settings = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit, leaveMinutesBeforeStart: 62)
        XCTAssertEqual(settings.departAt(start: TestClock.local(2026, 10, 20, 18, 0)), TestClock.local(2026, 10, 20, 16, 58))
    }

    // MARK: The cache

    func testTheCacheKeepsItAndOldCachesStillLoad() throws {
        var event = TestEvents.make(id: "e1", start: TestClock.local(2026, 10, 20, 17), end: TestClock.local(2026, 10, 20, 18))
        let legacy = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("departure"), "nothing written when there is none")
        XCTAssertNil(try JSONDecoder().decode(ScheduleEvent.self, from: legacy).departure)

        event.departure = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .driving, leaveMinutesBeforeStart: 100)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleEvent.self, from: data), event)
    }
}
