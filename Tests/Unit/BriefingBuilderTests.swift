import XCTest

final class BriefingBuilderTests: XCTestCase {
    private let clock = TestClock.clock
    /// Thursday 2026-10-15.
    private let day = TestClock.local(2026, 10, 15)

    private func timed(_ id: String, _ title: String, _ hour: Int, _ minute: Int = 0, day: Int = 15) -> ScheduleEvent {
        let start = TestClock.local(2026, 10, day, hour, minute)
        return TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(3600))
    }

    private func allDay(_ id: String, _ title: String, from first: Int, through last: Int) -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: TestClock.local(2026, 10, first),
                        end: TestClock.local(2026, 10, last + 1), allDay: true)
    }

    private func lines(_ content: BriefingBuilder.Content?) -> [String] {
        content?.body.components(separatedBy: "\n") ?? []
    }

    func testMorningBriefingListsAllDayFirstThenByTime() throws {
        let events = [timed("lunch", "Lunch", 13), timed("sync", "Team sync", 9), allDay("hol", "Holiday", from: 15, through: 15)]
        let content = try XCTUnwrap(BriefingBuilder.build(kind: .morning, day: day, events: events, clock: clock))
        XCTAssertEqual(content.title, "Today")
        XCTAssertEqual(lines(content), ["3 events, first at 09:00", "All day · Holiday", "09:00 Team sync", "13:00 Lunch"])
    }

    func testSingleEventWording() {
        XCTAssertEqual(lines(BriefingBuilder.build(kind: .morning, day: day, events: [timed("a", "Dentist", 8, 45)], clock: clock)),
                       ["1 event, at 08:45", "08:45 Dentist"])
        XCTAssertEqual(lines(BriefingBuilder.build(kind: .morning, day: day,
                                                   events: [allDay("h", "Holiday", from: 15, through: 15)], clock: clock)),
                       ["1 event, all day", "All day · Holiday"])
        XCTAssertEqual(lines(BriefingBuilder.build(kind: .morning, day: day,
                                                   events: [allDay("h", "Holiday", from: 15, through: 15),
                                                            allDay("t", "Trip", from: 14, through: 16)], clock: clock)).first,
                       "2 events, all day")
    }

    func testAtMostSixLinesThenACount() {
        let events = (0..<8).map { timed("e\($0)", "Item \($0)", 8 + $0) }
        let body = lines(BriefingBuilder.build(kind: .morning, day: day, events: events, clock: clock))
        XCTAssertEqual(body.count, 1 + BriefingBuilder.maxLines + 1)
        XCTAssertEqual(body.first, "8 events, first at 08:00")
        XCTAssertEqual(body[6], "13:00 Item 5")
        XCTAssertEqual(body.last, "+2 more")
    }

    func testCappedRemindersAreListed() {
        let body = lines(BriefingBuilder.build(kind: .morning, day: day, events: [timed("a", "Gym", 18)],
                                               cappedTitles: ["Gym", "Reply to Joe"], clock: clock))
        XCTAssertEqual(body.last, "Not sent as reminders: Gym, Reply to Joe")
    }

    func testEmptyDayHasNoBriefingUnlessRemindersWereHeldBack() {
        XCTAssertNil(BriefingBuilder.build(kind: .morning, day: day, events: [timed("x", "Other day", 9, day: 16)], clock: clock))
        XCTAssertEqual(lines(BriefingBuilder.build(kind: .morning, day: day, events: [], cappedTitles: ["Essay due"], clock: clock)),
                       ["Not sent as reminders: Essay due"])
    }

    func testEveningPreviewIsTitledTomorrow() {
        let content = BriefingBuilder.build(kind: .evening, day: day, events: [timed("a", "Dentist", 9)], clock: clock)
        XCTAssertEqual(content?.title, "Tomorrow")
    }

    func testOnlyThatDaysBookedItemsAreListed() {
        var done = timed("done", "Done task", 10)
        done.isCompleted = true
        let draft = timed("draft-ev-batch-0", "Not added yet", 11)
        let yesterdayLate = TestEvents.make(id: "late", title: "Overnight", start: TestClock.local(2026, 10, 14, 23),
                                            end: TestClock.local(2026, 10, 15, 1))
        let tomorrow = timed("tomorrow", "Tomorrow's", 9, day: 16)
        let spanning = allDay("trip", "Trip", from: 14, through: 16)
        let listed = BriefingBuilder.events(on: day, from: [done, draft, yesterdayLate, tomorrow, spanning, timed("ok", "OK", 12)],
                                            clock: clock)
        XCTAssertEqual(listed.map(\.id), ["trip", "ok"])
    }
}
