import XCTest

/// Departure reminders on the event: the user's two choices (minutes early, way of travelling) in its private
/// properties on Google Calendar, read and written by the mapper. Never the time to leave, which comes from Google
/// (owner decision 2026-10-20). Events without them read exactly as before.
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

    private let saved = ["ssArriveEarly": "30", "ssTravelMode": "transit"]

    // MARK: Reading

    func testAnEventWithDepartureSettingsReadsThem() throws {
        let event = try XCTUnwrap(mapper.scheduleEvent(from: googleEvent(saved)))
        XCTAssertEqual(event.departure, DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit))
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
            ["ssArriveEarly": "30"],                                       // one missing
            ["ssTravelMode": "transit"],
            ["ssArriveEarly": "thirty", "ssTravelMode": "transit"],
            ["ssArriveEarly": "30", "ssTravelMode": "bicycling"],          // not a mode the app uses
            ["ssArriveEarly": "30", "ssTravelMode": "two_wheeler"],        // the server's spelling, not the app's
            ["ssArriveEarly": "30", "ssTravelMode": ""],
            ["ssArriveEarly": "-5", "ssTravelMode": "transit"],
            ["ssArriveEarly": "181", "ssTravelMode": "transit"],
            ["ssArriveEarly": " 30", "ssTravelMode": "transit"],
        ]
        for properties in cases {
            XCTAssertNil(CalendarEventMapper.departure(from: properties), "\(properties)")
        }
    }

    /// An event written while the time to leave was still kept on it (development builds only) reads its two choices.
    func testAnOlderThirdValueIsIgnored() {
        XCTAssertEqual(CalendarEventMapper.departure(from: ["ssArriveEarly": "30", "ssTravelMode": "driving",
                                                            "ssLeaveBefore": "62"]),
                       DepartureSettings(arriveEarlyMinutes: 30, travelMode: .driving))
    }

    // MARK: Writing

    func testItWritesExactlyTheTwoValues() {
        let settings = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit)
        XCTAssertEqual(CalendarEventMapper.departureProperties(settings), saved)
        let patch = mapper.departurePatch(settings)
        XCTAssertEqual(patch.extendedProperties?.private, saved,
                       "no location, starting point, travel time or time to leave")
        XCTAssertNil(patch.extendedProperties?.shared)
        XCTAssertNil(patch.summary)
        XCTAssertNil(patch.location)
        XCTAssertNil(patch.start)
        XCTAssertNil(patch.end)
        XCTAssertNil(patch.reminders)
        XCTAssertNil(patch.description)
    }

    func testAScooterIsKeptAsTwoWheeler() {
        let settings = DepartureSettings(arriveEarlyMinutes: 10, travelMode: .scooter)
        XCTAssertEqual(CalendarEventMapper.departureProperties(settings),
                       ["ssArriveEarly": "10", "ssTravelMode": "two-wheeler"])
    }

    func testWritingThenReadingGivesTheSameSettings() {
        for mode in TravelMode.allCases {
            for early in [0, 10, 30, 180] {
                let settings = DepartureSettings(arriveEarlyMinutes: early, travelMode: mode)
                XCTAssertEqual(CalendarEventMapper.departure(from: CalendarEventMapper.departureProperties(settings)),
                               settings, "\(mode) \(early)")
            }
        }
    }

    func testValuesAreKeptInRange() {
        XCTAssertEqual(DepartureSettings(arriveEarlyMinutes: 999, travelMode: .driving).arriveEarlyMinutes, 180)
        XCTAssertEqual(DepartureSettings(arriveEarlyMinutes: -5, travelMode: .walking).arriveEarlyMinutes, 0)
    }

    // MARK: A new event's insert body

    private func mapped(_ draft: EventDraft) throws -> MappedEvent {
        try mapper.event(from: draft, seed: "s|0", utterance: "今天 5 點要到台北 101 開會")
    }

    func testANewTimedEventGetsTheTwoValuesInItsInsertBody() throws {
        let plain = try mapped(EventDraft(title: "開會", start: "2026-10-20T17:00", durationMinutes: 60,
                                          location: "台北 101"))
        let with = CalendarEventMapper.addingDeparture(DepartureSettings(arriveEarlyMinutes: 30, travelMode: .scooter),
                                                       to: plain)
        let before = try XCTUnwrap(plain.body.extendedProperties?.private)
        let after = try XCTUnwrap(with.body.extendedProperties?.private)
        XCTAssertEqual(after["ssArriveEarly"], "30")
        XCTAssertEqual(after["ssTravelMode"], "two-wheeler")
        XCTAssertEqual(after.filter { !["ssArriveEarly", "ssTravelMode"].contains($0.key) }, before,
                       "ssSource, ssKind, ssSchema and ssReminders stay as they were")
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), ["ssArriveEarly", "ssTravelMode"])
        var unchanged = with.body
        unchanged.extendedProperties = plain.body.extendedProperties
        XCTAssertEqual(unchanged, plain.body, "nothing else in the body changes")
        XCTAssertEqual(with.wantsConference, plain.wantsConference)
    }

    func testAnAllDayEventGetsNoDeparture() throws {
        let allDay = try mapped(EventDraft(title: "露營", start: "2026-10-20", allDay: true, location: "露營地"))
        let with = CalendarEventMapper.addingDeparture(DepartureSettings(arriveEarlyMinutes: 30, travelMode: .driving),
                                                       to: allDay)
        XCTAssertEqual(with.body, allDay.body)
    }

    func testANewDepartureReplacesAnOlderOne() throws {
        let first = CalendarEventMapper.addingDeparture(DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit),
                                                        to: try mapped(EventDraft(title: "開會", start: "2026-10-20T17:00")))
        let second = CalendarEventMapper.addingDeparture(DepartureSettings(arriveEarlyMinutes: 10, travelMode: .walking),
                                                         to: first)
        XCTAssertEqual(second.body.extendedProperties?.private?["ssArriveEarly"], "10")
        XCTAssertEqual(second.body.extendedProperties?.private?["ssTravelMode"], "walking")
    }

    // MARK: From a plan, and back

    /// The owner's example: 17:00, 30 minutes early → be there by 16:30. Only the minutes early and the way of
    /// travelling are kept; the travel time and the time to leave are not.
    func testAPlanKeepsOnlyTheUsersChoices() {
        let start = TestClock.local(2026, 10, 20, 17, 0)
        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: 22,
                                         travelMode: .transit, isEstimate: false)
        let settings = DeparturePlanner.settings(for: plan, start: start)
        XCTAssertEqual(settings, DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit))
        XCTAssertEqual(settings.arriveBy(start: start), TestClock.local(2026, 10, 20, 16, 30))
    }

    func testMovingTheEventMovesTheArrival() {
        let settings = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit)
        XCTAssertEqual(settings.arriveBy(start: TestClock.local(2026, 10, 20, 18, 0)), TestClock.local(2026, 10, 20, 17, 30))
    }

    // MARK: The cache

    func testTheCacheKeepsItAndOldCachesStillLoad() throws {
        var event = TestEvents.make(id: "e1", start: TestClock.local(2026, 10, 20, 17), end: TestClock.local(2026, 10, 20, 18))
        let legacy = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("departure"), "nothing written when there is none")
        XCTAssertNil(try JSONDecoder().decode(ScheduleEvent.self, from: legacy).departure)

        event.departure = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .scooter)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleEvent.self, from: data), event)
    }

    // MARK: Waiting to sync

    /// A departure saved while offline waits in the outbox; the event shows it at once (`OutboxOverlay`), merged the
    /// way Google merges private properties.
    func testAQueuedDepartureShowsOnTheEventAtOnce() throws {
        var event = try XCTUnwrap(mapper.scheduleEvent(from: googleEvent(nil)))
        let settings = DepartureSettings(arriveEarlyMinutes: 15, travelMode: .scooter)
        let shown = OutboxOverlay.applying(mapper.departurePatch(settings), to: event, clock: TestClock.clock)
        XCTAssertEqual(shown.departure, settings)
        XCTAssertEqual(shown.title, event.title)
        XCTAssertEqual(shown.start, event.start)
        XCTAssertEqual(shown.reminderMinutes, event.reminderMinutes)

        // One of the two values changes only that one.
        event.departure = DepartureSettings(arriveEarlyMinutes: 30, travelMode: .transit)
        var travel = GCalEvent()
        travel.extendedProperties = GCalExtendedProperties(private: ["ssTravelMode": "driving"])
        XCTAssertEqual(OutboxOverlay.applying(travel, to: event, clock: TestClock.clock).departure,
                       DepartureSettings(arriveEarlyMinutes: 30, travelMode: .driving))
        // Other private properties, or other fields, leave it as it was.
        var other = GCalEvent()
        other.summary = "Lunch"
        other.extendedProperties = GCalExtendedProperties(private: ["ssKind": "event"])
        XCTAssertEqual(OutboxOverlay.applying(other, to: event, clock: TestClock.clock).departure, event.departure)
        // Without a value already on the event, one of the two alone is not enough to read.
        event.departure = nil
        XCTAssertNil(OutboxOverlay.applying(travel, to: event, clock: TestClock.clock).departure)
    }
}
