import XCTest

final class CalendarPagingTests: XCTestCase {
    private let calendar = TestClock.clock.calendar // Europe/London, Sunday-first
    private let english = Locale(identifier: "en_US")

    /// Tuesday 13 October 2026, BST.
    private let tuesday = TestClock.local(2026, 10, 13, 9, 30)

    // MARK: Weeks

    func testWeekStartIsTheSundayBefore() {
        XCTAssertEqual(CalendarPaging.weekStart(containing: tuesday, calendar: calendar), TestClock.local(2026, 10, 11))
        XCTAssertEqual(CalendarPaging.weekStart(containing: TestClock.local(2026, 10, 11), calendar: calendar),
                       TestClock.local(2026, 10, 11))
        XCTAssertEqual(CalendarPaging.weekStart(containing: TestClock.local(2026, 10, 17, 23, 59), calendar: calendar),
                       TestClock.local(2026, 10, 11))
    }

    func testWeekDaysRunSundayThroughSaturday() {
        let days = CalendarPaging.days(ofWeekStarting: TestClock.local(2026, 10, 11), calendar: calendar)
        XCTAssertEqual(days, (11...17).map { TestClock.local(2026, 10, $0) })
    }

    func testWeekRangeTitle() {
        let week = CalendarPaging.weekInterval(containing: tuesday, calendar: calendar)
        XCTAssertEqual(week.start, TestClock.local(2026, 10, 11))
        XCTAssertEqual(week.end, TestClock.local(2026, 10, 18))
        XCTAssertEqual(CalendarPaging.rangeTitle(week, calendar: calendar, locale: english), "Oct 11 – Oct 17")
    }

    func testWeekSteppingAcrossTheClockChangeLandsOnMidnight() {
        // Sunday 25 Oct 2026 has 25 hours in London: seven 86 400 s days from it end on Saturday 23:00.
        let longWeek = TestClock.local(2026, 10, 25)
        XCTAssertNotEqual(longWeek.addingTimeInterval(7 * 86_400), TestClock.local(2026, 11, 1))
        XCTAssertEqual(CalendarPaging.week(1, from: longWeek, calendar: calendar), TestClock.local(2026, 11, 1))
        XCTAssertEqual(CalendarPaging.week(2, from: TestClock.local(2026, 10, 18), calendar: calendar),
                       TestClock.utc(2026, 11, 1)) // GMT again, so local midnight is 00:00Z
        XCTAssertEqual(CalendarPaging.week(-1, from: TestClock.local(2026, 11, 1), calendar: calendar), longWeek)
    }

    func testWeekOffsetCountsCalendarWeeksAcrossTheClockChange() {
        XCTAssertEqual(CalendarPaging.weekOffset(of: tuesday, from: tuesday, calendar: calendar), 0)
        XCTAssertEqual(CalendarPaging.weekOffset(of: TestClock.local(2026, 10, 17, 23), from: tuesday, calendar: calendar), 0)
        XCTAssertEqual(CalendarPaging.weekOffset(of: TestClock.local(2026, 10, 18), from: tuesday, calendar: calendar), 1)
        XCTAssertEqual(CalendarPaging.weekOffset(of: TestClock.local(2026, 11, 5, 12), from: tuesday, calendar: calendar), 3)
        XCTAssertEqual(CalendarPaging.weekOffset(of: TestClock.local(2026, 10, 3), from: tuesday, calendar: calendar), -2)
    }

    // MARK: Month window

    func testMonthWindowStartsOneWeekBeforeTheCurrentWeek() {
        let window = CalendarPaging.monthWindow(around: tuesday, calendar: calendar)
        XCTAssertEqual(window.start, TestClock.local(2026, 10, 4))
        XCTAssertEqual(window.end, TestClock.local(2026, 11, 8)) // exclusive, after the 25 Oct clock change
        XCTAssertEqual(CalendarPaging.lastDay(of: window, calendar: calendar), TestClock.local(2026, 11, 7))
        XCTAssertEqual(CalendarPaging.rangeTitle(window, calendar: calendar, locale: english), "Oct 4 – Nov 7")
    }

    func testMonthWindowWithoutLeadStartsOnTheWeekItself() {
        let window = CalendarPaging.monthWindow(around: tuesday, leadWeeks: 0, weeks: 3, calendar: calendar)
        XCTAssertEqual(window.start, TestClock.local(2026, 10, 11))
        XCTAssertEqual(CalendarPaging.rangeTitle(window, calendar: calendar, locale: english), "Oct 11 – Oct 31")
    }

    func testReferenceMonthIsTheMonthOfTheMiddleDay() {
        let window = CalendarPaging.monthWindow(around: tuesday, calendar: calendar) // Oct 4 – Nov 7
        let month = CalendarPaging.referenceMonth(of: window, calendar: calendar)
        XCTAssertEqual(month?.start, TestClock.local(2026, 10, 1))
        XCTAssertEqual(month?.end, TestClock.local(2026, 11, 1))

        let later = CalendarPaging.monthWindow(around: TestClock.local(2026, 11, 3), calendar: calendar) // Oct 25 – Nov 28
        XCTAssertEqual(CalendarPaging.referenceMonth(of: later, calendar: calendar)?.start, TestClock.local(2026, 11, 1))
    }

    func testVisibleWeekCountClampsToRange() {
        XCTAssertEqual(CalendarPaging.visibleWeekCount(forHeight: 196, minimumRowHeight: 34, range: 3...5), 5)
        XCTAssertEqual(CalendarPaging.visibleWeekCount(forHeight: 140, minimumRowHeight: 34, range: 3...5), 4)
        XCTAssertEqual(CalendarPaging.visibleWeekCount(forHeight: 60, minimumRowHeight: 34, range: 3...5), 3)
        XCTAssertEqual(CalendarPaging.visibleWeekCount(forHeight: 0, minimumRowHeight: 34, range: 3...5), 5)
    }

    // MARK: Days

    func testDayIntervalOnTheLongDay() {
        let day = CalendarPaging.dayInterval(containing: TestClock.local(2026, 10, 25, 12), calendar: calendar)
        XCTAssertEqual(day.start, TestClock.local(2026, 10, 25))
        XCTAssertEqual(day.end, TestClock.local(2026, 10, 26))
        XCTAssertEqual(day.duration, 25 * 3600)
    }

    func testEventsOnTheLongDayIncludeLateEvening() {
        // 23:30 GMT on 25 Oct is 24.5 h after local midnight: a 86 400 s day would miss it.
        let late = TestEvents.make(id: "late", start: TestClock.local(2026, 10, 25, 23, 30),
                                   end: TestClock.local(2026, 10, 25, 23, 50))
        let nextDay = TestEvents.make(id: "next", start: TestClock.local(2026, 10, 26, 0, 30),
                                      end: TestClock.local(2026, 10, 26, 1, 0))
        let ids = CalendarPaging.events(on: TestClock.local(2026, 10, 25), from: [nextDay, late], calendar: calendar).map(\.id)
        XCTAssertEqual(ids, ["late"])
    }

    func testEventsOnDayPutMultiDayFirstThenAllDayThenByTime() {
        let lunch = TestEvents.make(id: "lunch", start: TestClock.local(2026, 10, 13, 12, 30),
                                    end: TestClock.local(2026, 10, 13, 13, 30))
        let reply = TestEvents.make(id: "reply", start: TestClock.local(2026, 10, 13, 9),
                                    end: TestClock.local(2026, 10, 13, 9, 30), kind: .task)
        let holiday = TestEvents.make(id: "holiday", start: TestClock.local(2026, 10, 13),
                                      end: TestClock.local(2026, 10, 14), allDay: true)
        let trip = TestEvents.make(id: "trip", start: TestClock.local(2026, 10, 12),
                                   end: TestClock.local(2026, 10, 15), allDay: true)
        let ids = CalendarPaging.events(on: tuesday, from: [lunch, reply, holiday, trip], calendar: calendar).map(\.id)
        XCTAssertEqual(ids, ["trip", "holiday", "reply", "lunch"])
        XCTAssertEqual(CalendarPaging.singleDayEvents(on: tuesday, from: [lunch, reply, holiday, trip], calendar: calendar)
            .map(\.id), ["holiday", "reply", "lunch"])
    }

    func testMultiDayDetection() {
        let oneAllDay = TestEvents.make(id: "a", start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 14),
                                        allDay: true)
        let twoAllDay = TestEvents.make(id: "b", start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 15),
                                        allDay: true)
        let overnight = TestEvents.make(id: "c", start: TestClock.local(2026, 10, 13, 23), end: TestClock.local(2026, 10, 14, 1))
        let conference = TestEvents.make(id: "d", start: TestClock.local(2026, 10, 13, 9), end: TestClock.local(2026, 10, 15, 17))
        // The all-day event on the 25-hour day is still one day.
        let longDay = TestEvents.make(id: "e", start: TestClock.local(2026, 10, 25), end: TestClock.local(2026, 10, 26),
                                      allDay: true)

        XCTAssertFalse(CalendarPaging.isMultiDay(oneAllDay, calendar: calendar))
        XCTAssertTrue(CalendarPaging.isMultiDay(twoAllDay, calendar: calendar))
        XCTAssertFalse(CalendarPaging.isMultiDay(overnight, calendar: calendar))
        XCTAssertTrue(CalendarPaging.isMultiDay(conference, calendar: calendar))
        XCTAssertFalse(CalendarPaging.isMultiDay(longDay, calendar: calendar))
    }

    // MARK: Week rows

    func testSpansClipToTheWeekAndStackInLanes() {
        let weekStart = TestClock.local(2026, 10, 18)
        // Fri 16 – Tue 20: started last week, columns 0...2.
        let carriedIn = TestEvents.make(id: "carried", start: TestClock.local(2026, 10, 16),
                                        end: TestClock.local(2026, 10, 21), allDay: true)
        // Thu 22 – Sat 24: free in lane 0 after `carried` ends.
        let trip = TestEvents.make(id: "trip", title: "Trip to San Diego", start: TestClock.local(2026, 10, 22),
                                   end: TestClock.local(2026, 10, 25), allDay: true)
        // Mon 19 – Fri 23: overlaps both, so lane 1.
        let sprint = TestEvents.make(id: "sprint", start: TestClock.local(2026, 10, 19),
                                     end: TestClock.local(2026, 10, 24), allDay: true)
        // Fri 23 – Tue 27: runs into next week.
        let carriedOut = TestEvents.make(id: "out", start: TestClock.local(2026, 10, 23),
                                         end: TestClock.local(2026, 10, 28), allDay: true)
        let lunch = TestEvents.make(id: "lunch", start: TestClock.local(2026, 10, 20, 12),
                                    end: TestClock.local(2026, 10, 20, 13))

        let spans = CalendarPaging.spans(inWeekStarting: weekStart, events: [trip, lunch, carriedOut, sprint, carriedIn],
                                         calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })

        XCTAssertEqual(spans.count, 4)
        XCTAssertNil(byID["lunch"])

        XCTAssertEqual(byID["carried"]?.firstColumn, 0)
        XCTAssertEqual(byID["carried"]?.lastColumn, 2)
        XCTAssertEqual(byID["carried"]?.lane, 0)
        XCTAssertEqual(byID["carried"]?.continuesBefore, true)
        XCTAssertEqual(byID["carried"]?.continuesAfter, false)

        XCTAssertEqual(byID["sprint"]?.firstColumn, 1)
        XCTAssertEqual(byID["sprint"]?.lastColumn, 5)
        XCTAssertEqual(byID["sprint"]?.lane, 1)

        XCTAssertEqual(byID["trip"]?.firstColumn, 4)
        XCTAssertEqual(byID["trip"]?.lastColumn, 6)
        XCTAssertEqual(byID["trip"]?.lane, 0)
        XCTAssertEqual(byID["trip"]?.columnCount, 3)

        XCTAssertEqual(byID["out"]?.firstColumn, 5)
        XCTAssertEqual(byID["out"]?.lastColumn, 6)
        XCTAssertEqual(byID["out"]?.lane, 2)
        XCTAssertEqual(byID["out"]?.continuesBefore, false)
        XCTAssertEqual(byID["out"]?.continuesAfter, true)
    }

    func testWeekLayoutPutsChipsInTheirColumns() {
        let weekStart = TestClock.local(2026, 10, 11)
        let reply = TestEvents.make(id: "reply", start: TestClock.local(2026, 10, 13, 9),
                                    end: TestClock.local(2026, 10, 13, 9, 30), kind: .task)
        let lunch = TestEvents.make(id: "lunch", start: TestClock.local(2026, 10, 13, 12, 30),
                                    end: TestClock.local(2026, 10, 13, 13, 30))
        let yoga = TestEvents.make(id: "yoga", start: TestClock.local(2026, 10, 17, 9),
                                   end: TestClock.local(2026, 10, 17, 10), kind: .routine)
        let nextWeek = TestEvents.make(id: "later", start: TestClock.local(2026, 10, 18, 9),
                                       end: TestClock.local(2026, 10, 18, 10))
        let trip = TestEvents.make(id: "trip", start: TestClock.local(2026, 10, 15),
                                   end: TestClock.local(2026, 10, 17), allDay: true)

        let layout = CalendarPaging.weekLayout(startingAt: weekStart, events: [yoga, lunch, nextWeek, trip, reply],
                                               calendar: calendar)
        XCTAssertEqual(layout.days.first, weekStart)
        XCTAssertEqual(layout.singles.map { $0.map(\.id) }, [[], [], ["reply", "lunch"], [], [], [], ["yoga"]])
        XCTAssertEqual(layout.spans.map(\.id), ["trip"])
        XCTAssertEqual(layout.laneCount, 1)
    }

    func testCellLayoutCollapsesThreeOrMoreChipsIntoPlusN() {
        func layout(chips: Int, spans: [CalendarPaging.WeekSpan] = []) -> CalendarPaging.WeekLayout {
            let events = (0..<chips).map {
                TestEvents.make(id: "e\($0)", start: TestClock.local(2026, 10, 13, 9 + $0),
                                end: TestClock.local(2026, 10, 13, 10 + $0))
            }
            return CalendarPaging.WeekLayout(days: [], spans: spans, singles: [[], [], events, [], [], [], []])
        }
        func cell(_ barLines: Int, _ chips: Int, _ more: Int) -> CalendarPaging.CellLayout {
            CalendarPaging.CellLayout(barLines: barLines, chips: chips, more: more)
        }

        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 2), lines: 2),
                       cell(0, 2, 0))
        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 3), lines: 2),
                       cell(0, 1, 2))
        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 5), lines: 2),
                       cell(0, 1, 4))
        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 1), lines: 0),
                       cell(0, 0, 0))

        let bar = CalendarPaging.WeekSpan(
            event: TestEvents.make(id: "trip", start: TestClock.local(2026, 10, 12), end: TestClock.local(2026, 10, 15),
                                   allDay: true),
            firstColumn: 1, lastColumn: 3, lane: 0, continuesBefore: false, continuesAfter: false
        )
        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 1, spans: [bar]), lines: 2),
                       cell(1, 1, 0))
        XCTAssertEqual(CalendarPaging.cellLayout(column: 2, in: layout(chips: 2, spans: [bar]), lines: 2),
                       cell(1, 0, 2))
        XCTAssertEqual(CalendarPaging.cellLayout(column: 5, in: layout(chips: 0, spans: [bar]), lines: 2),
                       cell(0, 0, 0))
    }

    // MARK: Scope

    func testScopeFittingAssistantRanges() {
        let oneDay = DateInterval(start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 14))
        XCTAssertEqual(CalendarScope.fitting(oneDay, calendar: calendar), .day)

        // The orchestrators build some ranges from 86 400 s multiples; clock changes must not tip them over.
        let longDay = DateInterval(start: TestClock.local(2026, 10, 25), duration: 86_400)   // ends 23:00 GMT
        let shortDay = DateInterval(start: TestClock.local(2027, 3, 28), duration: 86_400)   // ends 01:00 BST next day
        XCTAssertEqual(CalendarScope.fitting(longDay, calendar: calendar), .day)
        XCTAssertEqual(CalendarScope.fitting(shortDay, calendar: calendar), .day)

        let weekAcrossChange = DateInterval(start: TestClock.local(2026, 10, 19), duration: 7 * 86_400)
        XCTAssertEqual(CalendarScope.fitting(weekAcrossChange, calendar: calendar), .week)
        XCTAssertEqual(CalendarScope.fitting(CalendarPaging.weekInterval(containing: tuesday, calendar: calendar),
                                             calendar: calendar), .week)
        let threeDays = DateInterval(start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 16))
        XCTAssertEqual(CalendarScope.fitting(threeDays, calendar: calendar), .week)

        let october = DateInterval(start: TestClock.local(2026, 10, 1), end: TestClock.local(2026, 11, 1))
        XCTAssertEqual(CalendarScope.fitting(october, calendar: calendar), .month)
        let eightDays = DateInterval(start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 21))
        XCTAssertEqual(CalendarScope.fitting(eightDays, calendar: calendar), .month)
    }

    func testScopeRawValuesAreStable() {
        // Persisted with @AppStorage("quickCaptureMode").
        XCTAssertEqual(CalendarScope.allCases.map(\.rawValue), ["day", "week", "month"])
    }
}
