import XCTest

/// The drawer's "Events" section and the events list: what has not ended, one row per series, sections by day
/// (midnight and DST included), the short list's order, search and the repeat summary.
final class EventDigestTests: XCTestCase {
    /// London, weeks from Sunday (the artboards' S M T W T F S).
    private let calendar = TestClock.clock.calendar
    /// Wednesday 2026-10-14 10:00 BST.
    private let now = TestClock.local(2026, 10, 14, 10, 0)
    private let english = Locale(identifier: "en_US")

    private func event(_ id: String, _ title: String = "Event", start: Date, minutes: Int = 60,
                       allDay: Bool = false, seriesID: String? = nil) -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes) * 60),
                        allDay: allDay, seriesID: seriesID)
    }

    private func allDay(_ id: String, _ title: String = "Trip", from first: Date, days: Int = 1) -> ScheduleEvent {
        let end = calendar.date(byAdding: .day, value: days, to: first)!
        return TestEvents.make(id: id, title: title, start: first, end: end, allDay: true)
    }

    // MARK: What is listed

    func testEndedEventsLeaveAndEventsUnderWayStay() {
        let ended = event("ended", start: TestClock.local(2026, 10, 14, 8, 0))
        let endsNow = event("endsNow", start: TestClock.local(2026, 10, 14, 9, 0))         // 09:00–10:00
        let running = event("running", start: TestClock.local(2026, 10, 14, 9, 30))        // 09:30–10:30
        let later = event("later", start: TestClock.local(2026, 10, 14, 15, 0))

        let rows = EventDigest.rows(from: [later, ended, endsNow, running], now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.id), ["running", "later"])
        XCTAssertEqual(rows.map(\.isHappeningNow), [true, false])
        XCTAssertEqual(rows.map(\.isSeries), [false, false])
        XCTAssertEqual(rows.map(\.occurrenceCount), [1, 1])

        // Evaluated again later (the list does every minute), what ended is gone.
        let afterwards = EventDigest.rows(from: [later, running], now: TestClock.local(2026, 10, 14, 10, 30), calendar: calendar)
        XCTAssertEqual(afterwards.map(\.id), ["later"])
    }

    func testDraftPreviewsAreLeftOut() {
        let preview = event(PlanDraft.eventIDPrefix + "plan-1", start: TestClock.local(2026, 10, 15, 9, 0))
        let real = event("real", start: TestClock.local(2026, 10, 15, 9, 0))
        XCTAssertTrue(preview.isDraft)
        XCTAssertEqual(EventDigest.rows(from: [preview, real], now: now, calendar: calendar).map(\.id), ["real"])
    }

    func testASeriesIsOneRowShowingItsNextOccurrence() {
        // Saturdays 09:00: Oct 10 is over, Oct 17, 24 and 31 are not.
        let yoga = [10, 17, 24, 31].map { day in
            event("yoga-\(day)", "Yoga", start: TestClock.local(2026, 10, day, 9, 0), seriesID: "yoga")
        }
        let dentist = event("dentist", "Dentist", start: TestClock.local(2026, 10, 16, 9, 30))

        let rows = EventDigest.rows(from: yoga.reversed() + [dentist], now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.id), ["dentist", "series:yoga"])
        let series = rows[1]
        XCTAssertTrue(series.isSeries)
        XCTAssertEqual(series.event.id, "yoga-17")
        XCTAssertEqual(series.occurrenceCount, 3)
        XCTAssertFalse(series.isHappeningNow)
        XCTAssertEqual(EventDigest.occurrences(of: series, in: yoga).map(\.id), ["yoga-10", "yoga-17", "yoga-24", "yoga-31"])
    }

    func testASeriesUnderWayShowsTheRunningOccurrence() {
        let gymNow = event("gym-14", "Gym", start: TestClock.local(2026, 10, 14, 9, 30), seriesID: "gym")
        let gymFriday = event("gym-16", "Gym", start: TestClock.local(2026, 10, 16, 18, 30), seriesID: "gym")
        let rows = EventDigest.rows(from: [gymFriday, gymNow], now: now, calendar: calendar)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.event.id, "gym-14")
        XCTAssertEqual(rows.first?.isHappeningNow, true)
        XCTAssertEqual(rows.first?.occurrenceCount, 2)
        // Under way beats "Repeating".
        XCTAssertEqual(EventDigest.sections(rows, now: now, calendar: calendar).map { $0.0 }, [.now])
    }

    // MARK: Sections

    func testSectionsAcrossMidnight() {
        // Wednesday 23:30.
        let lateNight = TestClock.local(2026, 10, 14, 23, 30)
        let party = event("party", "Party", start: TestClock.local(2026, 10, 14, 23, 0), minutes: 90) // to 00:30
        let holiday = allDay("holiday", "Holiday", from: TestClock.local(2026, 10, 14))
        let afterMidnight = event("early", "Early train", start: TestClock.local(2026, 10, 15, 0, 15))
        let thursdayNight = event("late", "Late call", start: TestClock.local(2026, 10, 15, 23, 59), minutes: 30)
        let friday = event("friday", "Friday lunch", start: TestClock.local(2026, 10, 16, 0, 0))
        let saturday = event("saturday", "Saturday brunch", start: TestClock.local(2026, 10, 17, 11, 0))
        let sunday = event("sunday", "Sunday walk", start: TestClock.local(2026, 10, 18, 9, 0)) // next week
        let weekly = event("sync-19", "Weekly sync", start: TestClock.local(2026, 10, 19, 10, 0), seriesID: "sync")

        let rows = EventDigest.rows(from: [sunday, weekly, saturday, friday, thursdayNight, afterMidnight, holiday, party],
                                    now: lateNight, calendar: calendar)
        let sections = EventDigest.sections(rows, now: lateNight, calendar: calendar)
        XCTAssertEqual(sections.map { $0.0 }, [.now, .today, .tomorrow, .thisWeek, .later, .repeating])
        XCTAssertEqual(sections.map { $0.1.map(\.id) }, [
            ["party"], ["holiday"], ["early", "late"], ["friday", "saturday"], ["sunday"], ["series:sync"]
        ])

        // Just after midnight the party is still on; Wednesday's holiday has ended; Thursday is today now.
        let pastMidnight = TestClock.local(2026, 10, 15, 0, 10)
        let next = EventDigest.sections(EventDigest.rows(from: [holiday, party, afterMidnight, thursdayNight],
                                                         now: pastMidnight, calendar: calendar),
                                        now: pastMidnight, calendar: calendar)
        XCTAssertEqual(next.map { $0.0 }, [.now, .today])
        XCTAssertEqual(next.map { $0.1.map(\.id) }, [["party"], ["early", "late"]])
    }

    func testSectionsAcrossTheAutumnClockChange() {
        // Saturday 2026-10-24 12:00 BST; Sunday 25 October has 25 hours (BST → GMT at 02:00).
        let mondayWeeks = WallClock(timeZone: TestClock.zone, firstWeekday: 2).calendar
        let saturday = TestClock.local(2026, 10, 24, 12, 0)
        let sundayLate = event("sunday-late", start: TestClock.local(2026, 10, 25, 23, 30), minutes: 20)
        let mondayEarly = event("monday-early", start: TestClock.local(2026, 10, 26, 0, 30))
        let sundayEarly = event("sunday-early", start: TestClock.local(2026, 10, 25, 1, 30))

        let rows = EventDigest.rows(from: [mondayEarly, sundayLate, sundayEarly], now: saturday, calendar: mondayWeeks)
        let sections = EventDigest.sections(rows, now: saturday, calendar: mondayWeeks)
        // 23:30 GMT on Sunday is more than 24 hours after Sunday 00:00 BST, and still Sunday.
        XCTAssertEqual(sections.map { $0.0 }, [.tomorrow, .later])
        XCTAssertEqual(sections.map { $0.1.map(\.id) }, [["sunday-early", "sunday-late"], ["monday-early"]])
        XCTAssertEqual(EventDigest.section(of: rows[1], now: saturday, calendar: mondayWeeks), .tomorrow)
    }

    func testSectionTitles() {
        XCTAssertEqual(ManagedEventSection.allCases.map(\.title), ["Now", "Today", "Tomorrow", "This week", "Later", "Repeating"])
    }

    // MARK: The drawer's short list

    func testUpcomingPutsWhatIsUnderWayFirstThenTheSoonest() {
        let holiday = allDay("holiday", "Holiday", from: TestClock.local(2026, 10, 14))
        let running = event("running", "Stand-up", start: TestClock.local(2026, 10, 14, 9, 45), minutes: 30)
        let lunch = event("lunch", "Lunch", start: TestClock.local(2026, 10, 14, 12, 30))
        let gym = (0..<3).map { week in
            event("gym-\(week)", "Gym", start: TestClock.local(2026, 10, 14 + 7 * week, 18, 30), seriesID: "gym")
        }
        let tomorrow = event("tomorrow", "Dentist", start: TestClock.local(2026, 10, 15, 9, 0))

        let rows = EventDigest.rows(from: gym + [tomorrow, lunch, running, holiday], now: now, calendar: calendar)
        XCTAssertEqual(EventDigest.upcoming(rows, limit: 4).map(\.id), ["running", "holiday", "lunch", "series:gym"])
        XCTAssertEqual(EventDigest.upcoming(rows, limit: 6).map(\.id), ["running", "holiday", "lunch", "series:gym", "tomorrow"])
        XCTAssertTrue(EventDigest.upcoming(rows, limit: 0).isEmpty)
        XCTAssertTrue(EventDigest.upcoming([], limit: 6).isEmpty)
    }

    // MARK: Search

    func testSearchLooksAtTitlePlaceAndNotes() {
        var flight = event("flight", "Flight to Tokyo", start: TestClock.local(2026, 10, 16, 9, 0))
        flight.location = "Heathrow Terminal 2"
        flight.notes = "Gate B\n帶護照"
        var lunch = event("lunch", "Lunch", start: TestClock.local(2026, 10, 16, 12, 30))
        lunch.location = "Café Lucia"
        let rows = EventDigest.rows(from: [flight, lunch], now: now, calendar: calendar)
        let flightRow = rows[0], lunchRow = rows[1]

        XCTAssertTrue(EventDigest.matches(flightRow, query: "tokyo"))
        XCTAssertTrue(EventDigest.matches(flightRow, query: "HEATHROW"))
        XCTAssertTrue(EventDigest.matches(flightRow, query: "護照"))
        XCTAssertTrue(EventDigest.matches(flightRow, query: "gate b"))
        XCTAssertTrue(EventDigest.matches(flightRow, query: "ｔｏｋｙｏ"), "full-width letters")
        XCTAssertTrue(EventDigest.matches(flightRow, query: "  "), "an empty query matches everything")
        XCTAssertTrue(EventDigest.matches(lunchRow, query: "cafe lucia"), "accents and every word")
        XCTAssertFalse(EventDigest.matches(lunchRow, query: "cafe tokyo"))
        XCTAssertFalse(EventDigest.matches(lunchRow, query: "passport"))
    }

    // MARK: Repeat summary

    private func summary(_ events: [ScheduleEvent]) -> String {
        EventDigest.repeatSummary(for: events[events.count / 2], occurrences: events, calendar: calendar, locale: english)
    }

    private func series(_ days: [Date], hour: Int, minute: Int = 0, allDay: Bool = false) -> [ScheduleEvent] {
        days.enumerated().map { index, day in
            let start = allDay ? day : TestClock.clock.combine(day: day, time: (hour: hour, minute: minute))!
            return TestEvents.make(id: "s-\(index)", title: "Series", start: start,
                                   end: start.addingTimeInterval(allDay ? 86_400 : 3_600), allDay: allDay, seriesID: "s")
        }
    }

    private func days(from first: Date, count: Int, every step: Int = 1, where keep: (Date) -> Bool = { _ in true }) -> [Date] {
        (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 * step, to: first) }.filter(keep)
    }

    func testRepeatSummaryReadsTheDates() {
        let start = TestClock.local(2026, 10, 1)
        // Saturdays (Oct 3 is a Saturday), across the clock change.
        XCTAssertEqual(summary(series(days(from: TestClock.local(2026, 10, 3), count: 8, every: 7), hour: 9)), "Every Sat 09:00")
        // Every day; every weekday; every second Tuesday.
        XCTAssertEqual(summary(series(days(from: start, count: 10), hour: 7)), "Every day 07:00")
        let weekdays = days(from: start, count: 21) { ![1, 7].contains(self.calendar.component(.weekday, from: $0)) }
        XCTAssertEqual(summary(series(weekdays, hour: 8)), "Every weekday 08:00")
        XCTAssertEqual(summary(series(days(from: TestClock.local(2026, 10, 6), count: 5, every: 14), hour: 10)),
                       "Every 2 weeks on Tue 10:00")
        // Monday, Wednesday and Friday at 18:30 with a week off: still weekly.
        let gymDays = days(from: TestClock.local(2026, 10, 5), count: 42) { day in
            let weekday = self.calendar.component(.weekday, from: day)
            let away = day >= TestClock.local(2026, 10, 19) && day < TestClock.local(2026, 10, 26)
            return [2, 4, 6].contains(weekday) && !away
        }
        let gym = summary(series(gymDays, hour: 18, minute: 30))
        XCTAssertTrue(gym.hasPrefix("Every Mon, Wed"), gym)
        XCTAssertTrue(gym.hasSuffix("Fri 18:30"), gym)
        // Every third day; monthly on the 15th (all-day: no time); yearly.
        XCTAssertEqual(summary(series(days(from: start, count: 5, every: 3), hour: 12)), "Every 3 days 12:00")
        let fifteenths = (0..<4).map { calendar.date(byAdding: .month, value: $0, to: TestClock.local(2026, 10, 15))! }
        XCTAssertEqual(summary(series(fifteenths, hour: 0, allDay: true)), "Every month on day 15")
        let birthdays = (0..<3).map { calendar.date(byAdding: .year, value: $0, to: TestClock.local(2026, 11, 2))! }
        XCTAssertEqual(summary(series(birthdays, hour: 0, allDay: true)), "Every year")
    }

    func testRepeatSummaryFallsBackWhenItCannotTell() {
        let one = series([TestClock.local(2026, 10, 17)], hour: 9)
        XCTAssertEqual(EventDigest.repeatSummary(for: one[0], occurrences: one, calendar: calendar, locale: english), "Repeats")
        let irregular = series([TestClock.local(2026, 10, 1), TestClock.local(2026, 10, 2), TestClock.local(2026, 11, 20)], hour: 9)
        XCTAssertEqual(summary(irregular), "Repeats")
    }
}
