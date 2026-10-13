import XCTest

final class RecurrenceRuleTests: XCTestCase {
    private let clock = TestClock.clock

    func testBasicRules() {
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", clock: clock), "RRULE:FREQ=DAILY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "weekly", byWeekday: ["mo", "we", "fr"], clock: clock),
                       "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR")
        XCTAssertEqual(RecurrenceRule.make(frequency: "Monthly", clock: clock), "RRULE:FREQ=MONTHLY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "YEARLY", count: 3, clock: clock), "RRULE:FREQ=YEARLY;COUNT=3")
    }

    func testInvalidFrequencyIsRejected() {
        XCTAssertNil(RecurrenceRule.make(frequency: "HOURLY", clock: clock))
        XCTAssertNil(RecurrenceRule.make(frequency: "", clock: clock))
        XCTAssertNil(RecurrenceRule.make(frequency: "every day", byWeekday: ["MO"], clock: clock))
    }

    func testUntilForGMTDay() throws {
        let day = try XCTUnwrap(clock.date("2026-11-30"))
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", untilDay: day, clock: clock),
                       "RRULE:FREQ=WEEKLY;UNTIL=20261130T235959Z")
    }

    func testUntilForBSTDay() throws {
        let day = try XCTUnwrap(clock.date("2027-04-13"))
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", untilDay: day, clock: clock),
                       "RRULE:FREQ=WEEKLY;UNTIL=20270413T225959Z")
    }

    func testUntilOnDSTChangeDays() throws {
        let autumn = try XCTUnwrap(clock.date("2026-10-25")) // ends in GMT
        let spring = try XCTUnwrap(clock.date("2027-03-28")) // ends in BST
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", untilDay: autumn, clock: clock),
                       "RRULE:FREQ=DAILY;UNTIL=20261025T235959Z")
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", untilDay: spring, clock: clock),
                       "RRULE:FREQ=DAILY;UNTIL=20270328T225959Z")
    }

    func testUntilIgnoresTimeOfDay() {
        let afternoon = TestClock.local(2026, 11, 30, 15, 45)
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", untilDay: afternoon, clock: clock),
                       "RRULE:FREQ=WEEKLY;UNTIL=20261130T235959Z")
    }

    func testUntilWinsOverCount() throws {
        let day = try XCTUnwrap(clock.date("2026-11-30"))
        let rule = try XCTUnwrap(RecurrenceRule.make(frequency: "WEEKLY", byWeekday: ["MO"], untilDay: day, count: 5, clock: clock))
        XCTAssertEqual(rule, "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261130T235959Z")
        XCTAssertFalse(rule.contains("COUNT"))
    }

    func testCountIsClampedAndIgnoredWhenNotPositive() {
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", count: 10, clock: clock), "RRULE:FREQ=DAILY;COUNT=10")
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", count: 5000, clock: clock), "RRULE:FREQ=DAILY;COUNT=730")
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", count: 0, clock: clock), "RRULE:FREQ=DAILY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", count: -2, clock: clock), "RRULE:FREQ=DAILY")
    }

    func testIntervalClamp() {
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", interval: 1, clock: clock), "RRULE:FREQ=WEEKLY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", interval: 0, clock: clock), "RRULE:FREQ=WEEKLY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", interval: -4, clock: clock), "RRULE:FREQ=WEEKLY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", interval: 2, clock: clock), "RRULE:FREQ=WEEKLY;INTERVAL=2")
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", interval: 100, clock: clock), "RRULE:FREQ=WEEKLY;INTERVAL=52")
    }

    func testByDayOnlyForDailyAndWeekly() {
        XCTAssertEqual(RecurrenceRule.make(frequency: "DAILY", byWeekday: ["MO", "TU"], clock: clock),
                       "RRULE:FREQ=DAILY;BYDAY=MO,TU")
        XCTAssertEqual(RecurrenceRule.make(frequency: "MONTHLY", byWeekday: ["MO"], clock: clock), "RRULE:FREQ=MONTHLY")
        XCTAssertEqual(RecurrenceRule.make(frequency: "WEEKLY", byWeekday: ["XX"], clock: clock), "RRULE:FREQ=WEEKLY")
    }

    func testWeekdayNormalizationDedupeAndMondayFirstOrder() {
        XCTAssertEqual(RecurrenceRule.normalizedWeekdays(["fr", "Monday", "WE", "mo", "xx", "SU", "sa"]),
                       ["MO", "WE", "FR", "SA", "SU"])
        XCTAssertEqual(RecurrenceRule.normalizedWeekdays(["SU", "MO"]), ["MO", "SU"])
        XCTAssertEqual(RecurrenceRule.normalizedWeekdays([]), [])
        XCTAssertEqual(RecurrenceRule.normalizedWeekdays(nil), [])
    }

    func testFullRuleOrderFromDraft() throws {
        let draft = try TestJSON.decode(RecurrenceDraft.self, json: """
        {"frequency": "weekly", "interval": 2, "by_weekday": ["TH", "tu", "TU"], "until": "2027-04-13", "count": 9}
        """)
        XCTAssertEqual(RecurrenceRule.make(from: draft, clock: clock),
                       "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20270413T225959Z")
    }

    func testDraftWithUnparseableUntilFallsBackToCount() throws {
        let draft = try TestJSON.decode(RecurrenceDraft.self, json: """
        {"frequency": "DAILY", "until": "someday", "count": 4}
        """)
        XCTAssertEqual(RecurrenceRule.make(from: draft, clock: clock), "RRULE:FREQ=DAILY;COUNT=4")
    }

    // MARK: firstMatchingDay

    func testFirstMatchingDayMovesTuesdayToWednesday() throws {
        let tuesday = try XCTUnwrap(clock.date("2026-10-13"))
        let wednesday = try XCTUnwrap(clock.date("2026-10-14"))
        XCTAssertEqual(RecurrenceRule.firstMatchingDay(onOrAfter: tuesday, weekdays: ["MO", "WE", "FR"], clock: clock),
                       wednesday)
    }

    func testFirstMatchingDayKeepsAMatchingDay() throws {
        let wednesday = try XCTUnwrap(clock.date("2026-10-14"))
        XCTAssertEqual(RecurrenceRule.firstMatchingDay(onOrAfter: wednesday, weekdays: ["WE"], clock: clock), wednesday)
    }

    func testFirstMatchingDayWithoutWeekdaysReturnsInput() throws {
        let tuesday = try XCTUnwrap(clock.date("2026-10-13"))
        XCTAssertEqual(RecurrenceRule.firstMatchingDay(onOrAfter: tuesday, weekdays: [], clock: clock), tuesday)
        XCTAssertEqual(RecurrenceRule.firstMatchingDay(onOrAfter: tuesday, weekdays: ["??"], clock: clock), tuesday)
    }

    func testFirstMatchingDayAcrossAutumnDSTChange() throws {
        let saturday = try XCTUnwrap(clock.date("2026-10-24"))
        let monday = try XCTUnwrap(clock.date("2026-10-26"))
        XCTAssertEqual(RecurrenceRule.firstMatchingDay(onOrAfter: saturday, weekdays: ["MO"], clock: clock), monday)
    }

    func testFirstMatchingDayKeepsWallClockTime() throws {
        let saturdayMorning = try XCTUnwrap(clock.dateTime("2026-10-24T07:00"))
        let aligned = try XCTUnwrap(RecurrenceRule.firstMatchingDay(onOrAfter: saturdayMorning, weekdays: ["MO"], clock: clock))
        XCTAssertEqual(clock.wallDateTimeString(aligned), "2026-10-26T07:00:00")
    }
}
