import XCTest

final class RecurrenceExpanderTests: XCTestCase {
    private let clock = TestClock.clock
    private let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())
    private let farFuture = TestClock.utc(2030, 1, 1)

    private func starts(from first: String, _ rrule: String, through horizon: Date? = nil) throws -> [Date] {
        let firstStart = try XCTUnwrap(clock.dateTime(first))
        return RecurrenceExpander.weeklyStarts(firstStart: firstStart, rrule: rrule, through: horizon ?? farFuture, clock: clock)
    }

    private func wall(_ dates: [Date]) -> [String] {
        dates.map(clock.promptDateTimeString)
    }

    // MARK: Rule parsing

    func testRuleParsing() throws {
        let rule = try XCTUnwrap(RecurrenceExpander.Rule("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO;UNTIL=20261130T235959Z;COUNT=4"))
        XCTAssertEqual(rule.frequency, "WEEKLY")
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.weekdays, ["MO", "TH"])
        XCTAssertEqual(rule.until, TestClock.utc(2026, 11, 30, 23, 59, 59))
        XCTAssertEqual(rule.count, 4)

        let bare = try XCTUnwrap(RecurrenceExpander.Rule("FREQ=weekly"))
        XCTAssertEqual(bare.frequency, "WEEKLY")
        XCTAssertEqual(bare.interval, 1)
        XCTAssertEqual(bare.weekdays, [])
        XCTAssertNil(bare.until)
        XCTAssertNil(bare.count)

        XCTAssertNil(RecurrenceExpander.Rule("RRULE:BYDAY=MO"))
    }

    func testParseICSUTC() {
        XCTAssertEqual(RecurrenceExpander.parseICSUTC("20270413T225959Z"), TestClock.utc(2027, 4, 13, 22, 59, 59))
        XCTAssertEqual(RecurrenceExpander.parseICSUTC("20270413"), TestClock.utc(2027, 4, 13))
        XCTAssertNil(RecurrenceExpander.parseICSUTC("2027"))
    }

    // MARK: Weekly expansion

    func testWeeklyExpansionKeepsWallClockAcrossBothDSTChanges() throws {
        // London leaves BST on 2026-10-25 and returns to it on 2027-03-28; UNTIL is the mapper's end of 2027-04-13.
        let dates = try starts(from: "2026-10-15T18:30", "RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20270413T225959Z")

        XCTAssertEqual(dates.count, 52) // python3 -I scripts/validate_schema.py reference
        XCTAssertEqual(dates.first, TestClock.local(2026, 10, 15, 18, 30))
        XCTAssertEqual(dates.last, TestClock.local(2027, 4, 12, 18, 30))
        XCTAssertEqual(Set(dates.map { String(clock.wallDateTimeString($0).suffix(8)) }), ["18:30:00"])

        // The wall clock stays put, so the UTC instant moves by an hour at each change.
        XCTAssertTrue(dates.contains(TestClock.utc(2026, 10, 22, 17, 30)), "Thursday before the autumn change (BST)")
        XCTAssertTrue(dates.contains(TestClock.utc(2026, 10, 26, 18, 30)), "Monday after the autumn change (GMT)")
        XCTAssertTrue(dates.contains(TestClock.utc(2027, 3, 25, 18, 30)), "Thursday before the spring change (GMT)")
        XCTAssertTrue(dates.contains(TestClock.utc(2027, 3, 29, 17, 30)), "Monday after the spring change (BST)")
    }

    func testUntilIsInclusive() throws {
        // 2026-11-30 is a GMT Monday, so 18:30 local is 18:30Z.
        let exact = try starts(from: "2026-10-19T18:30", "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261130T183000Z")
        XCTAssertEqual(exact.count, 7)
        XCTAssertEqual(exact.last, TestClock.local(2026, 11, 30, 18, 30))

        let secondEarlier = try starts(from: "2026-10-19T18:30", "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261130T182959Z")
        XCTAssertEqual(secondEarlier.last, TestClock.local(2026, 11, 23, 18, 30))

        // The rule the mapper writes (UNTIL = end of the last day) keeps the last day's session.
        let lastDay = try XCTUnwrap(clock.date("2026-11-30"))
        let rule = try XCTUnwrap(RecurrenceRule.make(frequency: "WEEKLY", byWeekday: ["MO"], untilDay: lastDay, clock: clock))
        XCTAssertEqual(try starts(from: "2026-10-19T18:30", rule).last, TestClock.local(2026, 11, 30, 18, 30))
    }

    func testFirstOccurrenceIsAlignedToByDay() throws {
        // DTSTART on a Wednesday with BYDAY=MO,TH: the first occurrence is Thursday; the Wednesday is not one.
        let dates = try starts(from: "2026-10-14T18:30", "RRULE:FREQ=WEEKLY;BYDAY=MO,TH",
                               through: TestClock.local(2026, 10, 27))
        XCTAssertEqual(wall(dates), ["2026-10-15T18:30", "2026-10-19T18:30", "2026-10-22T18:30", "2026-10-26T18:30"])
    }

    func testMapperSeriesStartOnTheirDTSTART() throws {
        // The plan mapper aligns DTSTART itself, so each series' first occurrence is exactly its DTSTART.
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let series = try mapper.events(fromPlan: plan, planID: "demoplan", utterance: "u").filter { $0.body.recurrence != nil }
        XCTAssertEqual(series.count, 6)
        for item in series {
            let instances = RecurrenceExpander.instances(of: item.body, through: farFuture, idPrefix: "", mapper: mapper)
            XCTAssertEqual(instances.first.map { clock.wallDateTimeString($0.start) }, item.body.start?.dateTime, item.body.summary ?? "")
        }
    }

    func testHorizonIsExclusive() throws {
        let dates = try starts(from: "2026-10-15T18:30", "RRULE:FREQ=WEEKLY;BYDAY=MO,TH",
                               through: TestClock.local(2026, 10, 22, 18, 30))
        XCTAssertEqual(wall(dates), ["2026-10-15T18:30", "2026-10-19T18:30"])
    }

    func testCountAndInterval() throws {
        // Every other Monday-based week, starting with DTSTART's week.
        let dates = try starts(from: "2026-10-15T18:30", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;COUNT=5")
        XCTAssertEqual(wall(dates), ["2026-10-15T18:30", "2026-10-26T18:30", "2026-10-29T18:30",
                                     "2026-11-09T18:30", "2026-11-12T18:30"])
    }

    func testWithoutByDayRepeatsOnDTSTARTsWeekday() throws {
        let dates = try starts(from: "2026-10-15T07:00", "RRULE:FREQ=WEEKLY;COUNT=3")
        XCTAssertEqual(wall(dates), ["2026-10-15T07:00", "2026-10-22T07:00", "2026-10-29T07:00"])
    }

    func testOnlyWeeklyRulesExpand() throws {
        XCTAssertEqual(try starts(from: "2026-10-15T07:00", "RRULE:FREQ=DAILY;COUNT=3"), [])
        XCTAssertEqual(try starts(from: "2026-10-15T07:00", "not a rule"), [])
    }

    // MARK: Instances

    func testInstancesAreShapedLikeGoogleExpansions() throws {
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let mapped = try mapper.events(fromPlan: plan, planID: "demoplan", utterance: "u")
        let body = try XCTUnwrap(mapped.first?.body) // Full body A: MO,TH 18:30, 60 min, until 2026-11-30
        let seriesID = try XCTUnwrap(body.id)

        let instances = RecurrenceExpander.instances(of: body, through: farFuture, idPrefix: PlanDraft.eventIDPrefix, mapper: mapper)
        XCTAssertEqual(instances.count, 14)
        let first = try XCTUnwrap(instances.first)
        XCTAssertEqual(first.id, "draft-\(seriesID)_20261015")
        XCTAssertEqual(first.seriesID, "draft-\(seriesID)")
        XCTAssertEqual(first.title, "Muscle 6M · Full body A")
        XCTAssertEqual(first.kind, .routine)
        XCTAssertEqual(first.planID, "demoplan")
        XCTAssertEqual(first.colorHex, "#0B8043")
        XCTAssertFalse(first.isAllDay)
        XCTAssertEqual(instances.last?.start, TestClock.local(2026, 11, 30, 18, 30))
        XCTAssertTrue(instances.allSatisfy { $0.isDraft && $0.duration == 3600 })
        XCTAssertEqual(Set(instances.map(\.id)).count, instances.count)
    }

    func testInstancesOfANonRecurringBodyAreEmpty() throws {
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let milestone = try XCTUnwrap(mapper.events(fromPlan: plan, planID: "demoplan", utterance: "u").last?.body)
        XCTAssertNil(milestone.recurrence)
        XCTAssertTrue(RecurrenceExpander.instances(of: milestone, through: farFuture, idPrefix: "", mapper: mapper).isEmpty)
    }
}
