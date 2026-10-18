import XCTest

final class LiveActivityStateBuilderTests: XCTestCase {
    private let clock = TestClock.clock
    /// Wednesday 2026-10-14 10:00 BST.
    private let now = TestClock.local(2026, 10, 14, 10, 0)

    private func build(_ events: [ScheduleEvent], lastLine: String? = nil, now: Date? = nil) -> ScheduleActivityAttributes.ContentState {
        LiveActivityStateBuilder.build(events: events, lastLine: lastLine, now: now ?? self.now, clock: clock)
    }

    /// `DayDigest.visibleRows` (the rows a day of the island's former week strip had, now replaced by "Up next"; kept
    /// in Shared): two chips, or one chip and "+N" for every other event.
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

    // MARK: Up next (the island's bottom region and the Lock Screen)

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        TestClock.local(2026, 10, day, hour, minute)
    }

    private func item(_ id: String, _ title: String, _ start: Date, minutes: Double = 30,
                      kind: ScheduleEvent.Kind = .event, allDay: Bool = false) -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                        allDay: allDay, kind: kind)
    }

    func testUpNextListsTheRestOfTheDaySoonestFirstAndCountsTheRest() throws {
        let next = item("next", "Drive to school", at(10, 30))
        let events = [
            item("dinner", "Dinner", at(19)),
            item("lunch", "Lunch", at(12)),
            item("call", "Call Ann", at(12)),                       // same start as Lunch: by title
            item("pay", "Pay bills", at(15), kind: .task),
            item("gym", "Gym", at(17)),
            item("tomorrow", "Dentist", at(9, day: 15)),
            next
        ]
        let state = build(events)
        XCTAssertEqual(state.eventID, "next")
        let upNext = try XCTUnwrap(state.upNext)
        XCTAssertEqual(upNext.map(\.title), ["Call Ann", "Lunch", "Pay bills"])
        XCTAssertEqual(upNext.map(\.start), [at(12), at(12), at(15)])
        XCTAssertEqual(upNext.map(\.isTask), [false, false, true])
        XCTAssertEqual(upNext.map(\.isTomorrow), [false, false, false])
        XCTAssertEqual(upNext.first?.colorHex, GoogleColor.calendarDefault)
        XCTAssertEqual(state.upNextMore, 2, "Gym and Dinner; tomorrow's Dentist is not counted")
    }

    func testUpNextLeavesOutAllDayDraftsCompletedTheEventItselfAndWhatStartsBeforeIt() throws {
        let next = item("next", "Design review", at(10, 30))
        var done = item("done", "Done already", at(13))
        done.isCompleted = true
        let events = [
            next,
            item("next", "Design review", at(10, 30)),               // its copy in another calendar
            item("allday", "Holiday", TestClock.local(2026, 10, 14), minutes: 24 * 60, allDay: true),
            item("draft-ev-batch-0", "Proposed lunch", at(12)),
            done,
            item("before", "Standup", at(9, 30), minutes: 150),       // under way, but started first
            item("same", "Coffee", at(10, 30)),                       // starts with it
            item("review", "Review", at(14))
        ]
        let state = LiveActivityStateBuilder.build(for: next, events: events, lastLine: nil, asOf: now, clock: clock)
        XCTAssertEqual(try XCTUnwrap(state.upNext).map(\.title), ["Coffee", "Review"])
        XCTAssertEqual(state.upNextMore, 0)
    }

    func testUnderWayEventListsOnlyWhatIsNotOverYet() throws {
        let current = item("now", "Workshop", at(9, 30), minutes: 90)
        let events = [current,
                      item("over", "Break", at(9, 40), minutes: 10),     // ended at 9:50
                      item("huddle", "Huddle", at(9, 45)),                // still going at 10:00
                      item("lunch", "Lunch", at(13))]
        let state = build(events)
        XCTAssertTrue(state.isInProgress)
        XCTAssertEqual(try XCTUnwrap(state.upNext).map(\.title), ["Huddle", "Lunch"])
    }

    func testNothingLaterTodayShowsOnlyTheFirstItemTomorrow() throws {
        let next = item("next", "Drive to school", at(10, 30))
        let events = [
            next,
            item("dentist", "Dentist", at(9, day: 15)),
            item("run", "Morning run", at(8, day: 15), kind: .task),
            item("lunch", "Lunch", at(12, day: 15)),
            item("trip", "Trip", TestClock.local(2026, 10, 15), minutes: 24 * 60, allDay: true),
            item("friday", "Concert", at(20, day: 16))
        ]
        let state = build(events)
        let upNext = try XCTUnwrap(state.upNext)
        XCTAssertEqual(upNext.map(\.title), ["Morning run"])
        XCTAssertEqual(upNext.first?.isTomorrow, true)
        XCTAssertEqual(upNext.first?.isTask, true)
        XCTAssertEqual(upNext.first?.start, at(8, day: 15))
        XCTAssertEqual(state.upNextMore, 0)
    }

    /// "Nothing else today": nothing after the event that day or the next (an item two days on does not count).
    func testNothingAfterTheEventIsAnEmptyList() {
        let next = item("next", "Drive to school", at(10, 30))
        let state = build([next, item("friday", "Concert", at(20, day: 16))])
        XCTAssertEqual(state.upNext, [])
        XCTAssertEqual(state.upNextMore, 0)
        XCTAssertNil(state.location)
    }

    func testNoEventHasNoUpNextNoPlaceAndNoDetailLine() {
        let past = item("past", "Breakfast", at(7))
        let allDay = item("allday", "Holiday", TestClock.local(2026, 10, 14), minutes: 24 * 60, allDay: true)
        let state = build([past, allDay])
        XCTAssertNil(state.eventID)
        XCTAssertEqual(state.headline, "Nothing next — type a plan")
        XCTAssertNil(state.upNext)
        XCTAssertNil(state.upNextMore)
        XCTAssertNil(state.location)
        XCTAssertNil(state.detailLine(locale: Locale(identifier: "en_GB")))
    }

    func testPlaceIsTrimmedJoinedAndCut() {
        XCTAssertEqual(LiveActivityStateBuilder.place("  St Mary's School \n"), "St Mary's School")
        XCTAssertEqual(LiveActivityStateBuilder.place("St Mary's School\n 12 Long Road \n\n"), "St Mary's School, 12 Long Road")
        XCTAssertNil(LiveActivityStateBuilder.place(" \n  "))
        XCTAssertNil(LiveActivityStateBuilder.place(""))
        XCTAssertNil(LiveActivityStateBuilder.place(nil))
        let long = String(repeating: "Riverside ", count: 10)
        let cut = LiveActivityStateBuilder.place(long)
        XCTAssertEqual(cut, "Riverside Riverside Riverside Riverside…", "39 characters, trimmed, and \"…\"")
        XCTAssertLessThanOrEqual(cut?.count ?? 0, LiveActivityStateBuilder.locationLength)

        var next = item("next", "Flight", at(10, 30))
        next.location = "  Terminal 2 \n"
        XCTAssertEqual(build([next]).location, "Terminal 2")
        next.location = "   "
        XCTAssertNil(build([next]).location)
    }

    /// Times are formatted when shown, in the zone the builder grouped the days in (Settings › Time zone).
    func testDetailLineShowsTimeAndPlaceInTheBuildersTimeZone() throws {
        var school = item("school", "Drive to school", at(8, 15, day: 15))
        school.location = "St Mary's School"
        let english = Locale(identifier: "en_GB")
        let state = LiveActivityStateBuilder.build(for: school, events: [school], lastLine: nil, asOf: now, clock: clock)
        XCTAssertEqual(state.timeZoneIdentifier, "Europe/London")
        XCTAssertEqual(state.detailLine(locale: english), "08:15–08:45 · St Mary's School")

        let taipei = WallClock(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Taipei")))
        let away = LiveActivityStateBuilder.build(for: school, events: [school], lastLine: nil, asOf: now, clock: taipei)
        XCTAssertEqual(away.detailLine(locale: english), "15:15–15:45 · St Mary's School")

        school.location = nil
        let noPlace = LiveActivityStateBuilder.build(for: school, events: [school], lastLine: nil, asOf: now, clock: clock)
        XCTAssertEqual(noPlace.detailLine(locale: english), "08:15–08:45")

        // The ended activity's last look has no end: the start alone.
        var ended = state
        ended.eventEnd = nil
        XCTAssertEqual(ended.detailLine(locale: english), "08:15 · St Mary's School")
        // An older payload has no zone: the iPhone's.
        var older = state
        older.timeZoneIdentifier = nil
        XCTAssertEqual(older.displayTimeZone, TimeZone.current)
    }

    func testStateRoundTripsWithEveryField() throws {
        var next = item("next", "Drive to school", at(10, 30))
        next.location = "St Mary's School"
        let state = build([next, item("lunch", "Lunch", at(12)), item("pay", "Pay bills", at(15), kind: .task)],
                          lastLine: "Added: Lunch")
        XCTAssertEqual(state.upNext?.count, 2)
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self,
                                               from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state, "a scheduled activity's content reads back exactly, or it would be replaced every pass")
    }

    func testPayloadsWithoutUpNextStillDecode() throws {
        var next = item("next", "Drive to school", at(10, 30))
        next.location = "St Mary's School"
        let state = build([next, item("lunch", "Lunch", at(12))])
        var object = try TestJSON.object(encoding: state)
        for key in ["location", "upNext", "upNextMore", "timeZoneIdentifier"] {
            XCTAssertNotNil(object.removeValue(forKey: key), key)
        }
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.location)
        XCTAssertNil(decoded.upNext)
        XCTAssertNil(decoded.upNextMore)
        XCTAssertNil(decoded.timeZoneIdentifier)
        XCTAssertNil(decoded.hasEnded)
        XCTAssertEqual(decoded.headline, "Drive to school")
        XCTAssertEqual(decoded.eventStart, at(10, 30))
        XCTAssertEqual(decoded.days, state.days)
    }

    /// The scheduler's final content (an event that is over, left on the Lock Screen for 10 minutes) has no timer and
    /// reads "Ended"; no state the builder makes is marked ended.
    func testTheEndedLookReadsBackWithNoTimer() throws {
        var state = build([item("next", "Drive to school", at(10, 30))])
        XCTAssertNil(state.hasEnded, "only ActivityScheduler.finalContent sets it")
        state.isInProgress = false
        state.countdownTarget = nil
        state.eventEnd = nil
        state.hasEnded = true
        let decoded = try JSONDecoder().decode(ScheduleActivityAttributes.ContentState.self,
                                               from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.hasEnded, true)
        XCTAssertNil(decoded.countdownRange(isStale: true), "no timer, so the capsule reads Ended")
        XCTAssertNil(decoded.countdownRange(isStale: false))
    }

    func testPayloadStaysUnderBudgetWithLongUpNextTitlesAndPlace() throws {
        let title = String(String(repeating: "健身訓練與會議", count: 9).prefix(60))
        let weekStart = TestClock.local(2026, 10, 11)
        var events = (0..<80).map { index -> ScheduleEvent in
            let start = weekStart.addingTimeInterval(Double(index % 7) * 86_400 + Double(8 + index / 7) * 3600)
            return TestEvents.make(id: "busy\(index)", title: title, start: start, end: start.addingTimeInterval(1800),
                                   kind: index % 3 == 0 ? .task : .event, colorHex: "#0B8043")
        }
        var next = TestEvents.make(id: "next", title: title, start: at(10, 30), end: at(11))
        next.location = String(String(repeating: "台北市信義區市府路一號", count: 6).prefix(60))
        events.append(next)

        let state = LiveActivityStateBuilder.build(for: next, events: events, lastLine: String(repeating: "x", count: 500),
                                                   asOf: now, clock: clock)
        let encoded = try JSONEncoder().encode(state)
        XCTAssertLessThanOrEqual(encoded.count, 3_200, "ActivityKit content must stay well under 4 KB")
        let upNext = try XCTUnwrap(state.upNext)
        XCTAssertEqual(upNext.count, 3)
        XCTAssertEqual(state.upNextMore, 5, "Wednesday's eight items from 11:00 to 18:00, three of them shown")
        XCTAssertTrue(upNext.allSatisfy { $0.title.count <= LiveActivityStateBuilder.upNextTitleLength })
        XCTAssertLessThanOrEqual(state.location?.count ?? 0, LiveActivityStateBuilder.locationLength)
        XCTAssertEqual(state.days.reduce(0) { $0 + $1.chips.count + $1.overflow }, 81)

        // Titles of many Unicode scalars each (18 bytes a character): the week digest goes first, still in budget.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let heavy = events.map { original -> ScheduleEvent in
            var event = original
            event.title = String(repeating: family, count: 60)
            return event
        }
        let heavyState = LiveActivityStateBuilder.build(for: heavy[heavy.count - 1], events: heavy, lastLine: nil,
                                                        asOf: now, clock: clock)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(heavyState).count, 3_200)
        XCTAssertEqual(heavyState.upNext?.count, 3)
        XCTAssertTrue(heavyState.upNext?.allSatisfy { $0.title.count <= LiveActivityStateBuilder.upNextTitleLength } ?? false)

        // The assistant's last line, which no view shows, goes before anything on screen shrinks: a long reply (60
        // emoji families, about 1 KB) changes nothing shown, so it sends no update and replaces no activity.
        let chatty = LiveActivityStateBuilder.build(for: heavy[heavy.count - 1], events: heavy,
                                                    lastLine: String(repeating: family, count: 60), asOf: now, clock: clock)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(chatty).count, 3_200)
        XCTAssertEqual(chatty.upNext, heavyState.upNext)
        XCTAssertEqual(chatty.location, heavyState.location)
        XCTAssertTrue(chatty.looksTheSame(as: heavyState))
    }

    /// However long a title is, the payload stays in budget: the headline is cut to `headlineLength` characters,
    /// ending in "…", and characters of many Unicode scalars each (stacked accents here) are cut by scalars as a
    /// last resort.
    func testVeryLongTitlesAreCutAndStayInBudget() throws {
        let long = item("long", String(repeating: "健身訓練與會議", count: 150), at(10, 30)) // 1,050 characters
        let state = LiveActivityStateBuilder.build(for: long, events: [long], lastLine: nil, asOf: now, clock: clock)
        XCTAssertEqual(state.headline.count, LiveActivityStateBuilder.headlineLength)
        XCTAssertTrue(state.headline.hasSuffix("…"))
        XCTAssertTrue(long.title.hasPrefix(String(state.headline.dropLast())))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(state).count, 3_200, "ActivityKit content must stay well under 4 KB")

        // 300 characters of 21 scalars (41 bytes) each: 80 of them alone are over the budget.
        let stacked = String(repeating: "e" + String(repeating: "\u{301}", count: 20), count: 300)
        var first = item("first", stacked, at(10, 30))
        first.location = stacked
        let rows = (0..<5).map { item("row\($0)", stacked, at(12 + $0)) }
        let heavy = LiveActivityStateBuilder.build(for: first, events: [first] + rows, lastLine: stacked, asOf: now, clock: clock)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(heavy).count, 3_200, "ActivityKit content must stay well under 4 KB")
        XCTAssertFalse(heavy.headline.isEmpty)
        XCTAssertEqual(heavy.upNext?.count, 3)
        XCTAssertEqual(heavy.upNextMore, 2)
        XCTAssertNil(heavy.location, "left out as a last resort")
        XCTAssertNil(heavy.lastAssistantLine)
    }

    /// A title longer than a row keeps ends in "…", so the cut does not read like a typo; one that fits stays whole.
    func testLongUpNextTitlesEndInAnEllipsis() throws {
        let next = item("next", "Drive to school", at(10, 30))
        let whole = "Online meeting on the product quality"                         // 37 characters
        let long = "Quarterly planning with the product, design and research teams" // 62 characters
        let state = build([next, item("a", whole, at(12)), item("b", long, at(13))])
        let titles = try XCTUnwrap(state.upNext).map(\.title)
        XCTAssertEqual(titles.first, whole)
        XCTAssertEqual(titles.last, "Quarterly planning with the product, design and…")
        XCTAssertEqual(titles.last?.count, LiveActivityStateBuilder.upNextTitleLength)
        // A separator left at the cut goes before the "…".
        XCTAssertEqual(LiveActivityStateBuilder.clipped("St Mary's School, 12 Long Road", 18), "St Mary's School…")
        XCTAssertEqual(LiveActivityStateBuilder.clipped("Dentist", 18), "Dentist")
    }

    /// The previews' tallest island: time and place, three rows and "+1".
    func testSampleMorningFillsTheTallestLayout() throws {
        let state = ScheduleActivityAttributes.ContentState.sampleMorning(now: now, clock: clock)
        XCTAssertEqual(state.headline, "School drop-off")
        XCTAssertEqual(state.location, "Riverside Primary School")
        XCTAssertEqual(try XCTUnwrap(state.upNext).count, 3)
        XCTAssertEqual(state.upNextMore, 1)
        XCTAssertEqual(state.eventStart, at(8, 15, day: 15), "the next 07:55 still to come is tomorrow's")
        XCTAssertEqual(state.countdownFrom, at(7, 55, day: 15))
    }

    /// The island's and the Lock Screen's labels in Chinese (Localizable.xcstrings, compiled into this bundle).
    func testUpNextLabelsAreTranslated() throws {
        let bundle = Bundle(for: LiveActivityStateBuilderTests.self)
        guard let strings = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "zh-Hant"),
              let table = Bundle(path: (strings as NSString).deletingLastPathComponent) else {
            throw XCTSkip("No compiled zh-Hant Localizable.strings in the test bundle")
        }
        func zh(_ key: String) -> String { table.localizedString(forKey: key, value: nil, table: "Localizable") }
        XCTAssertEqual(zh("Edit"), "編輯")
        XCTAssertEqual(zh("Up next"), "接下來")
        XCTAssertEqual(zh("Nothing else today"), "今天接下來沒有其他行程")
        XCTAssertEqual(String(format: zh("Tomorrow %@"), "09:00"), "明天 09:00")
        XCTAssertEqual(String(format: zh("+%lld"), 2), "+2")
    }
}
