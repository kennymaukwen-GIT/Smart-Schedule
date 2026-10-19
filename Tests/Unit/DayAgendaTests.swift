import XCTest

/// The list a tapped date opens: all-day first, then by the time each event starts on that day.
final class DayAgendaTests: XCTestCase {
    private let calendar = TestClock.clock.calendar

    private func timed(_ id: String, _ start: Date, _ end: Date) -> ScheduleEvent {
        TestEvents.make(id: id, title: id, start: start, end: end)
    }

    private func items(on day: Date, _ events: [ScheduleEvent]) -> [DayAgenda.Item] {
        DayAgenda.items(on: day, events: events, calendar: calendar)
    }

    func testAllDayFirstThenByStartTime() {
        let day = TestClock.local(2026, 10, 20)
        let afternoon = timed("afternoon", TestClock.local(2026, 10, 20, 14), TestClock.local(2026, 10, 20, 15))
        let morning = timed("morning", TestClock.local(2026, 10, 20, 9), TestClock.local(2026, 10, 20, 10))
        let holiday = TestEvents.make(id: "holiday", start: day, end: TestClock.local(2026, 10, 21), allDay: true)
        let list = items(on: day, [afternoon, morning, holiday])
        XCTAssertEqual(list.map(\.id), ["holiday", "morning", "afternoon"])
        XCTAssertEqual(list.map(\.timing), [
            .allDay,
            .timed(start: TestClock.local(2026, 10, 20, 9), end: TestClock.local(2026, 10, 20, 10)),
            .timed(start: TestClock.local(2026, 10, 20, 14), end: TestClock.local(2026, 10, 20, 15)),
        ])
    }

    func testOtherDaysAreLeftOut() {
        let day = TestClock.local(2026, 10, 20)
        let yesterday = timed("yesterday", TestClock.local(2026, 10, 19, 9), TestClock.local(2026, 10, 19, 10))
        let endsAtMidnight = timed("late", TestClock.local(2026, 10, 19, 23), TestClock.local(2026, 10, 20))
        let tomorrow = timed("tomorrow", TestClock.local(2026, 10, 21), TestClock.local(2026, 10, 21, 1))
        XCTAssertTrue(items(on: day, [yesterday, endsAtMidnight, tomorrow]).isEmpty)
    }

    /// Fri 18:00 → Sun 12:00: from 18:00 on Friday, the whole of Saturday, until 12:00 on Sunday.
    func testAMultiDayEventOnEachOfItsDays() {
        let trip = timed("trip", TestClock.local(2026, 10, 23, 18), TestClock.local(2026, 10, 25, 12))
        let friday = items(on: TestClock.local(2026, 10, 23), [trip])
        XCTAssertEqual(friday.map(\.timing), [.timed(start: TestClock.local(2026, 10, 23, 18), end: nil)])
        XCTAssertEqual(items(on: TestClock.local(2026, 10, 24), [trip]).map(\.timing), [.allDay])
        XCTAssertEqual(items(on: TestClock.local(2026, 10, 25), [trip]).map(\.timing),
                       [.timed(start: nil, end: TestClock.local(2026, 10, 25, 12))])
    }

    func testAnEventFromTheDayBeforeCountsFromMidnight() {
        let day = TestClock.local(2026, 10, 20)
        let overnight = timed("overnight", TestClock.local(2026, 10, 19, 22), TestClock.local(2026, 10, 20, 2))
        let early = timed("early", TestClock.local(2026, 10, 20, 1), TestClock.local(2026, 10, 20, 3))
        XCTAssertEqual(items(on: day, [early, overnight]).map(\.id), ["overnight", "early"])
    }

    func testTheLongerOneFirstWhenTwoStartTogether() {
        let day = TestClock.local(2026, 10, 20)
        let short = timed("short", TestClock.local(2026, 10, 20, 9), TestClock.local(2026, 10, 20, 9, 30))
        let long = timed("long", TestClock.local(2026, 10, 20, 9), TestClock.local(2026, 10, 20, 11))
        XCTAssertEqual(items(on: day, [short, long]).map(\.id), ["long", "short"])
    }

    func testAMultiDayAllDayEventIsAllDayOnEveryDay() {
        let leave = TestEvents.make(id: "leave", start: TestClock.local(2026, 10, 20), end: TestClock.local(2026, 10, 23),
                                    allDay: true)
        for day in 20...22 {
            XCTAssertEqual(items(on: TestClock.local(2026, 10, day), [leave]).map(\.timing), [.allDay], "Oct \(day)")
        }
        XCTAssertTrue(items(on: TestClock.local(2026, 10, 23), [leave]).isEmpty, "the end is exclusive")
    }

    func testAMomentInTimeKeepsItsTime() {
        let deadline = timed("deadline", TestClock.local(2026, 10, 20, 17), TestClock.local(2026, 10, 20, 17))
        XCTAssertEqual(items(on: TestClock.local(2026, 10, 20), [deadline]).map(\.timing),
                       [.timed(start: TestClock.local(2026, 10, 20, 17), end: TestClock.local(2026, 10, 20, 17))])
    }

    /// 25 Oct 2026 has 25 hours in London: an event late that evening is still on the day.
    func testTheClockChangeDayKeepsItsLastHour() {
        let late = timed("late", TestClock.local(2026, 10, 25, 23, 30), TestClock.local(2026, 10, 25, 23, 45))
        XCTAssertEqual(items(on: TestClock.local(2026, 10, 25, 12), [late]).map(\.id), ["late"])
        XCTAssertTrue(items(on: TestClock.local(2026, 10, 26), [late]).isEmpty)
    }
}
