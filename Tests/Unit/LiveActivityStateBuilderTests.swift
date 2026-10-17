import XCTest

final class LiveActivityStateBuilderTests: XCTestCase {
    private let clock = TestClock.clock
    /// Wednesday 2026-10-14 10:00 BST.
    private let now = TestClock.local(2026, 10, 14, 10, 0)

    private func build(_ events: [ScheduleEvent], lastLine: String? = nil, now: Date? = nil) -> ScheduleActivityAttributes.ContentState {
        LiveActivityStateBuilder.build(events: events, lastLine: lastLine, now: now ?? self.now, clock: clock)
    }

    /// The island's week strip has room for two rows a day: two chips, or one chip and "+N" for every other event.
    func testADayShowsAtMostTwoRows() {
        let chip = { (title: String) in ScheduleActivityAttributes.Chip(title: title, colorHex: "#33B679", isTask: false) }
        func rows(_ chips: Int, overflow: Int) -> (titles: [String], more: Int) {
            let day = ScheduleActivityAttributes.DayDigest(dayNumber: 17, chips: (0..<chips).map { chip("e\($0)") },
                                                           overflow: overflow)
            let shown = day.visibleRows(2)
            return (shown.chips.map(\.title), shown.more)
        }
        XCTAssertEqual(rows(0, overflow: 0).titles, [])
        XCTAssertEqual(rows(1, overflow: 0).titles, ["e0"])
        XCTAssertEqual(rows(2, overflow: 0).titles, ["e0", "e1"])
        XCTAssertEqual(rows(2, overflow: 0).more, 0)
        // Yoga, 我要吃飯 and one more: Yoga and "+2".
        XCTAssertEqual(rows(2, overflow: 1).titles, ["e0"])
        XCTAssertEqual(rows(2, overflow: 1).more, 2)
        // One chip (a long payload kept one) and one more event: both rows used.
        XCTAssertEqual(rows(1, overflow: 1).titles, ["e0"])
        XCTAssertEqual(rows(1, overflow: 1).more, 1)
        XCTAssertEqual(rows(1, overflow: 4).titles, ["e0"])
        XCTAssertEqual(rows(1, overflow: 4).more, 4)
        XCTAssertEqual(rows(0, overflow: 3).titles, [])
        XCTAssertEqual(rows(0, overflow: 3).more, 3)
    }

    func testWeekHasSevenDaysStartingSunday() {
        let state = build([])
        XCTAssertEqual(state.days.count, 7)
        XCTAssertEqual(state.days.map(\.dayNumber), [11, 12, 13, 14, 15, 16, 17])
        XCTAssertEqual(state.weekStart, TestClock.local(2026, 10, 11))
        XCTAssertEqual(state.todayIndex, 3)
        XCTAssertNil(state.eventID)
        XCTAssertNil(state.countdownTarget)
        XCTAssertFalse(state.isInProgress)
    }

    func testStateRecordsTheFirstWeekday() {
        XCTAssertEqual(build([]).firstWeekday, 1)
    }

    func testMondayFirstWeek() {
        let monday = WallClock(timeZone: TestClock.zone, firstWeekday: 2)
        let state = LiveActivityStateBuilder.build(events: [], lastLine: nil, now: now, clock: monday)
        XCTAssertEqual(state.firstWeekday, 2)
        XCTAssertEqual(state.days.map(\.dayNumber), [12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(state.weekStart, TestClock.local(2026, 10, 12))
        XCTAssertEqual(state.todayIndex, 2)
        // Sunday is the last day of a Monday-first week.
        let sunday = LiveActivityStateBuilder.build(events: [], lastLine: nil, now: TestClock.local(2026, 10, 18, 9), clock: monday)
        XCTAssertEqual(sunday.todayIndex, 6)
        XCTAssertEqual(sunday.weekStart, TestClock.local(2026, 10, 12))
    }

    func testPayloadsWithoutFirstWeekdayStillDecode() throws {
        var object = try TestJSON.object(encoding: build([]))
        object.removeValue(forKey: "firstWeekday")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        let state = try decoder.decode(ScheduleActivityAttributes.ContentState.self, from: data)
        XCTAssertNil(state.firstWeekday)
    }

    func testDraftsAreNeverTheNextEvent() {
        let draft = TestEvents.make(id: "draft-ev-batch-0", start: TestClock.local(2026, 10, 14, 11), end: TestClock.local(2026, 10, 14, 12))
        let real = TestEvents.make(id: "real", start: TestClock.local(2026, 10, 14, 13), end: TestClock.local(2026, 10, 14, 14))
        XCTAssertEqual(build([draft, real]).eventID, "real")
    }

    // MARK: Dynamic Island lead time

    func testNextEventIsDueWithinTheLeadTime() {
        let soon = TestEvents.make(id: "soon", start: TestClock.local(2026, 10, 14, 10, 20), end: TestClock.local(2026, 10, 14, 11))
        XCTAssertTrue(LiveActivityStateBuilder.isNextEventDue(events: [soon], leadMinutes: 30, now: now))
        XCTAssertTrue(LiveActivityStateBuilder.isNextEventDue(events: [soon], leadMinutes: 20, now: now))
        XCTAssertFalse(LiveActivityStateBuilder.isNextEventDue(events: [soon], leadMinutes: 15, now: now))
        XCTAssertFalse(LiveActivityStateBuilder.isNextEventDue(events: [soon], leadMinutes: nil, now: now))
        XCTAssertFalse(LiveActivityStateBuilder.isNextEventDue(events: [], leadMinutes: 120, now: now))
    }

    func testInProgressEventIsDueButAllDayCompletedAndPastAreNot() {
        let current = TestEvents.make(id: "now", start: TestClock.local(2026, 10, 14, 9, 30), end: TestClock.local(2026, 10, 14, 10, 30))
        XCTAssertTrue(LiveActivityStateBuilder.isNextEventDue(events: [current], leadMinutes: 15, now: now))
        var done = current
        done.isCompleted = true
        let past = TestEvents.make(id: "past", start: TestClock.local(2026, 10, 14, 8), end: TestClock.local(2026, 10, 14, 9))
        let allDay = TestEvents.make(id: "day", start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15), allDay: true)
        XCTAssertFalse(LiveActivityStateBuilder.isNextEventDue(events: [done, past, allDay], leadMinutes: 120, now: now))
    }

    func testWeekAcrossAutumnDSTChange() {
        // Tuesday after the clocks go back; the week starts on Sunday 25th, which is 25 hours long.
        let state = build([], now: TestClock.local(2026, 10, 27, 9, 0))
        XCTAssertEqual(state.days.map(\.dayNumber), [25, 26, 27, 28, 29, 30, 31])
        XCTAssertEqual(state.weekStart, TestClock.local(2026, 10, 25))
        XCTAssertEqual(state.todayIndex, 2)
    }

    func testNextUpcomingEventDrivesCountdown() throws {
        let past = TestEvents.make(id: "past", title: "Breakfast",
                                   start: TestClock.local(2026, 10, 14, 7), end: TestClock.local(2026, 10, 14, 8))
        let allDay = TestEvents.make(id: "allday", title: "Holiday",
                                     start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15), allDay: true)
        let next = TestEvents.make(id: "next", title: "Online meeting on the product quality",
                                   start: TestClock.local(2026, 10, 14, 14), end: TestClock.local(2026, 10, 14, 15))
        let tomorrow = TestEvents.make(id: "tomorrow", title: "Dentist",
                                       start: TestClock.local(2026, 10, 15, 9), end: TestClock.local(2026, 10, 15, 10))

        let state = build([tomorrow, past, allDay, next], lastLine: "Schedule set")
        XCTAssertEqual(state.eventID, "next")
        XCTAssertEqual(state.headline, next.title)
        XCTAssertEqual(state.shortHeadline, String(next.title.prefix(16)))
        XCTAssertFalse(state.isInProgress)
        XCTAssertEqual(state.countdownFrom, now)
        let target = try XCTUnwrap(state.countdownTarget)
        XCTAssertEqual(target, next.start)
        XCTAssertLessThanOrEqual(state.countdownFrom, target)
        XCTAssertEqual(state.lastAssistantLine, "Schedule set")
    }

    func testInProgressEventCountsDownToItsEnd() throws {
        let current = TestEvents.make(id: "now", title: "Standup",
                                      start: TestClock.local(2026, 10, 14, 9, 30), end: TestClock.local(2026, 10, 14, 11))
        let later = TestEvents.make(id: "later", start: TestClock.local(2026, 10, 14, 13), end: TestClock.local(2026, 10, 14, 14))

        let state = build([later, current])
        XCTAssertEqual(state.eventID, "now")
        XCTAssertTrue(state.isInProgress)
        let target = try XCTUnwrap(state.countdownTarget)
        XCTAssertEqual(target, current.end)
        XCTAssertLessThanOrEqual(state.countdownFrom, target)
    }

    func testCompletedEventIsSkipped() {
        var done = TestEvents.make(id: "done", start: TestClock.local(2026, 10, 14, 11), end: TestClock.local(2026, 10, 14, 12))
        done.isCompleted = true
        let next = TestEvents.make(id: "next", start: TestClock.local(2026, 10, 14, 12), end: TestClock.local(2026, 10, 14, 13))
        XCTAssertEqual(build([done, next]).eventID, "next")
    }

    func testChipsAreTruncatedAndOverflowCounted() {
        let events = (0..<3).map { index in
            TestEvents.make(id: "e\(index)", title: "Very long event title \(index)",
                            start: TestClock.local(2026, 10, 15, 9 + index), end: TestClock.local(2026, 10, 15, 10 + index),
                            kind: index == 0 ? .task : .event)
        }
        let thursday = build(events).days[4]
        XCTAssertEqual(thursday.dayNumber, 15)
        XCTAssertEqual(thursday.chips.count + thursday.overflow, 3)
        XCTAssertTrue(thursday.chips.allSatisfy { $0.title.count <= 10 })
        XCTAssertEqual(thursday.chips.first?.isTask, true)
    }

    func testPayloadStaysUnderBudgetForBusyWeek() throws {
        let title = String(String(repeating: "健身訓練與會議", count: 9).prefix(60))
        XCTAssertEqual(title.count, 60)
        let weekStart = TestClock.local(2026, 10, 11)
        let events = (0..<80).map { index -> ScheduleEvent in
            let start = weekStart.addingTimeInterval(Double(index % 7) * 86_400 + Double(8 + index / 7) * 3600)
            return TestEvents.make(id: "busy\(index)", title: title, start: start, end: start.addingTimeInterval(1800),
                                   kind: index % 3 == 0 ? .task : .event, colorHex: "#0B8043")
        }

        let state = build(events, lastLine: String(repeating: "x", count: 500))
        let encoded = try JSONEncoder().encode(state)
        XCTAssertLessThanOrEqual(encoded.count, 3_200, "ActivityKit content must stay well under 4 KB")
        XCTAssertEqual(state.days.count, 7)
        XCTAssertEqual(state.days.reduce(0) { $0 + $1.chips.count + $1.overflow }, 80)
        XCTAssertLessThanOrEqual(state.lastAssistantLine?.count ?? 0, 60)
        XCTAssertLessThanOrEqual(state.shortHeadline.count, 16)
    }
}
