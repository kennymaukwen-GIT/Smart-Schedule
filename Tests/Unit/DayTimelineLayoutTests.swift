import XCTest

/// Quick Capture's DAY timeline (`DayTimelineLayout`): overlapping events share the width in columns, events from
/// another day are clipped to this one, and the grid opens near what matters.
final class DayTimelineLayoutTests: XCTestCase {
    private let calendar = TestClock.clock.calendar
    /// Wednesday 14 October 2026, London (BST).
    private lazy var day = CalendarPaging.dayInterval(containing: TestClock.local(2026, 10, 14), calendar: calendar)

    private func item(_ id: String, _ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int,
                      day: Int = 14) -> DayTimelineLayout.Item {
        DayTimelineLayout.Item(id: id,
                               start: TestClock.local(2026, 10, day, startHour, startMinute),
                               end: TestClock.local(2026, 10, day, endHour, endMinute))
    }

    private func slots(_ items: [DayTimelineLayout.Item], minimumMinutes: Double = 0) -> [String: DayTimelineLayout.Slot] {
        let slots = DayTimelineLayout.slots(for: items, in: day, calendar: calendar, minimumMinutes: minimumMinutes)
        return Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
    }

    func testEventsThatDoNotOverlapTakeTheWholeWidth() {
        let result = slots([item("a", 9, 0, 10, 0), item("b", 11, 0, 12, 0), item("c", 10, 0, 11, 0)])
        XCTAssertEqual(result.count, 3)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(result[id]?.column, 0, id)
            XCTAssertEqual(result[id]?.columns, 1, id)
            XCTAssertEqual(result[id]?.span, 1, id)
        }
        XCTAssertEqual(result["a"]?.startMinute, 540)
        XCTAssertEqual(result["a"]?.endMinute, 600)
    }

    func testTwoOverlappingEventsShareTheWidth() {
        let result = slots([item("a", 9, 0, 10, 0), item("b", 9, 30, 10, 30)])
        XCTAssertEqual(result["a"]?.column, 0)
        XCTAssertEqual(result["b"]?.column, 1)
        XCTAssertEqual(result["a"]?.columns, 2)
        XCTAssertEqual(result["b"]?.columns, 2)
    }

    func testAChainOfOverlapsReusesAFreeColumn() {
        // A–B and B–C overlap, A and C don't: C takes A's column, so two columns are enough for all three.
        let result = slots([item("a", 9, 0, 10, 0), item("b", 9, 30, 10, 30), item("c", 10, 0, 11, 0)])
        XCTAssertEqual(result["a"]?.column, 0)
        XCTAssertEqual(result["b"]?.column, 1)
        XCTAssertEqual(result["c"]?.column, 0)
        XCTAssertEqual(Set(result.values.map(\.columns)), [2])
        // An event after the chain has ended starts afresh.
        let later = slots([item("a", 9, 0, 10, 0), item("b", 9, 30, 10, 30), item("d", 10, 30, 11, 0)])
        XCTAssertEqual(later["d"]?.column, 0)
        XCTAssertEqual(later["d"]?.columns, 1)
    }

    func testEventsStartingTogetherSitSideBySideLongestFirst() {
        let result = slots([item("short", 9, 0, 10, 0), item("long", 9, 0, 11, 0), item("same", 9, 0, 10, 0)])
        XCTAssertEqual(result["long"]?.column, 0, "the longer one keeps the left column")
        XCTAssertEqual(result["short"]?.column, 1, "then in the order given")
        XCTAssertEqual(result["same"]?.column, 2)
        XCTAssertEqual(Set(result.values.map(\.columns)), [3])
    }

    func testZeroLengthEvents() {
        // Two reminders at the same minute are side by side, not on top of each other.
        let together = slots([item("a", 9, 0, 9, 0), item("b", 9, 0, 9, 0)])
        XCTAssertEqual(together["a"]?.columns, 2)
        XCTAssertNotEqual(together["a"]?.column, together["b"]?.column)
        XCTAssertEqual(together["a"]?.startMinute, 540)
        XCTAssertEqual(together["a"]?.endMinute, 540)
        // At the end of an event, an instant doesn't overlap it…
        let after = slots([item("meeting", 9, 0, 10, 0), item("ping", 10, 0, 10, 0)])
        XCTAssertEqual(after["ping"]?.columns, 1)
        // …but the shortest block is taller than ten minutes: drawn that tall, it would cover the next event.
        let drawn = slots([item("ping", 10, 0, 10, 0), item("call", 10, 15, 10, 45)], minimumMinutes: 30)
        XCTAssertEqual(drawn["ping"]?.columns, 2)
        XCTAssertEqual(drawn["call"]?.column, 1)
        XCTAssertEqual(drawn["ping"]?.endMinute, 600, "the slot keeps the real end; only the overlap test stretches it")
        // An end before the start (bad data) counts as an instant.
        let backwards = slots([DayTimelineLayout.Item(id: "x", start: TestClock.local(2026, 10, 14, 9, 0),
                                                      end: TestClock.local(2026, 10, 14, 8, 0))])
        XCTAssertEqual(backwards["x"]?.endMinute, 540)
    }

    func testEventsCrossingMidnightAreClippedToTheDay() {
        let result = slots([
            item("overnight", 23, 0, 1, 0, day: 13).withEndOn(14),
            item("late", 23, 30, 23, 59).withEndOn(15, 0, 30),
            item("yesterday", 22, 0, 0, 0, day: 13).withEndOn(14, 0, 0),
            item("tomorrow", 0, 0, 1, 0, day: 15),
            item("midnightPing", 0, 0, 0, 0, day: 15),
            item("startPing", 0, 0, 0, 0)
        ])
        XCTAssertEqual(result["overnight"]?.startMinute, 0)
        XCTAssertEqual(result["overnight"]?.endMinute, 60)
        XCTAssertEqual(result["late"]?.startMinute, 1410)
        XCTAssertEqual(result["late"]?.endMinute, 1440)
        XCTAssertNil(result["yesterday"], "ends as this day starts")
        XCTAssertNil(result["tomorrow"])
        XCTAssertNil(result["midnightPing"], "an instant at the next midnight belongs to the next day")
        XCTAssertEqual(result["startPing"]?.startMinute, 0)
        XCTAssertEqual(result["overnight"]?.columns, 2, "the overnight event and the instant at 00:00 overlap")
    }

    func testAFreeColumnToTheRightIsSpanned() {
        // "long" holds column 0; "b" and "c" start with it; "d" follows "b" in column 1 and "c" has ended by then.
        let result = slots([item("long", 9, 0, 12, 0), item("b", 9, 0, 10, 30), item("c", 9, 0, 10, 0),
                            item("d", 10, 30, 11, 30)])
        XCTAssertEqual(result["long"]?.column, 0)
        XCTAssertEqual(result["b"]?.column, 1)
        XCTAssertEqual(result["c"]?.column, 2)
        XCTAssertEqual(result["d"]?.column, 1)
        XCTAssertEqual(Set(result.values.map(\.columns)), [3])
        XCTAssertEqual(result["d"]?.span, 2, "column 2 is free from 10:00")
        XCTAssertEqual(result["long"]?.span, 1)
        XCTAssertEqual(result["c"]?.span, 1)
    }

    func testSlotsAreSortedByStartAndKeepTheirIndex() {
        let items = [item("late", 15, 0, 16, 0), item("early", 8, 0, 9, 0)]
        let slots = DayTimelineLayout.slots(for: items, in: day, calendar: calendar)
        XCTAssertEqual(slots.map(\.id), ["early", "late"])
        XCTAssertEqual(slots.map(\.index), [1, 0])
    }

    func testMinutesFollowTheWallClockOnADSTDay() throws {
        // Sunday 25 October 2026: London goes back from BST to GMT at 02:00, so the day lasts 25 hours.
        let dstDay = CalendarPaging.dayInterval(containing: TestClock.local(2026, 10, 25, 12), calendar: calendar)
        XCTAssertEqual(dstDay.duration, 25 * 3600)
        XCTAssertEqual(DayTimelineLayout.minute(of: TestClock.local(2026, 10, 25, 15, 30), in: dstDay, calendar: calendar),
                       930, "15:30 sits on the 15:00 line's half hour, not an hour lower")
        XCTAssertEqual(DayTimelineLayout.minute(of: dstDay.end, in: dstDay, calendar: calendar), 1440)
        XCTAssertEqual(DayTimelineLayout.minute(of: dstDay.start.addingTimeInterval(-60), in: dstDay, calendar: calendar), 0)
        XCTAssertEqual(DayTimelineLayout.minute(of: TestClock.local(2026, 10, 14, 9, 0).addingTimeInterval(30),
                                                in: day, calendar: calendar), 540.5)
    }

    func testBackToBackBlocksStayFullWidthAtTheDrawnMinimumHeight() {
        // DAY's numbers: 24-pt blocks drawn 22 pt tall (1-pt gap each side) at 46 pt an hour, about 28.7 minutes.
        let minimum = DayTimelineLayout.minutes(spanning: 22, hourHeight: 46)
        XCTAssertEqual(minimum, 22.0 / 46 * 60, accuracy: 0.0001)
        XCTAssertEqual(DayTimelineLayout.minutes(spanning: 22, hourHeight: 0), 0)
        let chain = slots([item("a", 9, 0, 9, 30), item("b", 9, 30, 10, 0), item("c", 10, 0, 10, 30)],
                          minimumMinutes: minimum)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(chain[id]?.columns, 1, "30-minute events one after another don't zig-zag: \(id)")
            XCTAssertEqual(chain[id]?.column, 0, id)
        }
        // A 10-minute item is drawn as tall as 28.7 minutes: one 20 minutes later would sit under it…
        let close = slots([item("ping", 9, 0, 9, 10), item("call", 9, 20, 10, 0)], minimumMinutes: minimum)
        XCTAssertEqual(close["ping"]?.columns, 2)
        XCTAssertEqual(close["call"]?.column, 1)
        // …one 30 minutes later is clear of it.
        let clear = slots([item("ping", 9, 0, 9, 10), item("call", 9, 30, 10, 0)], minimumMinutes: minimum)
        XCTAssertEqual(clear["ping"]?.columns, 1)
        XCTAssertEqual(clear["call"]?.columns, 1)
    }

    func testOpeningHour() {
        let today = TestClock.local(2026, 10, 14, 12, 27)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: today, firstStart: TestClock.local(2026, 10, 14, 6, 0),
                                                     calendar: calendar), 11, "today: about an hour before now")
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: TestClock.local(2026, 10, 14, 12, 30), firstStart: nil,
                                                     calendar: calendar), 12, "30 minutes or more past the hour")
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: TestClock.local(2026, 10, 14, 0, 20), firstStart: nil,
                                                     calendar: calendar), 0)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: TestClock.local(2026, 10, 14, 23, 50), firstStart: nil,
                                                     calendar: calendar), 23)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: today, firstStart: nil, calendar: calendar, lead: 60),
                       11)
        let otherDay = TestClock.local(2026, 10, 12, 9, 0)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: otherDay, firstStart: TestClock.local(2026, 10, 14, 6, 30),
                                                     calendar: calendar), 6, "another day: before its first event")
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: otherDay, firstStart: TestClock.local(2026, 10, 14, 6, 15),
                                                     calendar: calendar), 5)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: otherDay, firstStart: TestClock.local(2026, 10, 13, 23, 0),
                                                     calendar: calendar), 0, "an event from the evening before")
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: otherDay, firstStart: nil, calendar: calendar), 8)
        XCTAssertEqual(DayTimelineLayout.openingHour(day: day, now: day.end, firstStart: nil, calendar: calendar), 8,
                       "the next midnight is tomorrow")
    }
}

private extension DayTimelineLayout.Item {
    /// The same start, ending on another day of October 2026 (London).
    func withEndOn(_ day: Int, _ hour: Int? = nil, _ minute: Int? = nil) -> DayTimelineLayout.Item {
        let calendar = TestClock.clock.calendar
        let parts = calendar.dateComponents([.hour, .minute], from: end)
        return DayTimelineLayout.Item(id: id, start: start,
                                      end: TestClock.local(2026, 10, day, hour ?? parts.hour ?? 0, minute ?? parts.minute ?? 0))
    }
}
