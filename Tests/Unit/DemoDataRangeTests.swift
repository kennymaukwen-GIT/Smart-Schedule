import XCTest

/// Demo mode scrolls without end too: the weekly series exist for any range, one-off items only in the seed.
final class DemoDataRangeTests: XCTestCase {
    private let clock = TestClock.clock
    /// Tuesday 2026-10-13 10:15 BST.
    private let now = TestClock.local(2026, 10, 13, 10, 15)

    private func wallTime(_ event: ScheduleEvent) -> String {
        String(clock.promptDateTimeString(event.start).suffix(5))
    }

    func testWeeklySeriesFillARangeAYearAheadWithUniqueIDs() {
        // Fri 1 Oct – Mon 15 Nov 2027; London leaves BST on 31 Oct.
        let range = DateInterval(start: TestClock.local(2027, 10, 1), end: TestClock.local(2027, 11, 15))
        let events = DemoData.recurringEvents(in: range, clock: clock)

        XCTAssertEqual(events.count, 32)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
        XCTAssertTrue(events.allSatisfy { DemoData.isDemoID($0.id) && DemoData.isRecurringOccurrence($0) })
        XCTAssertTrue(events.allSatisfy { $0.intersects(range) })

        let gym = events.filter { $0.title == "Gym" }
        XCTAssertEqual(gym.count, 19)
        XCTAssertEqual(Set(gym.map(wallTime)), ["18:30"]) // on both sides of the DST change
        XCTAssertTrue(gym.contains { $0.id == "demo-gym-2027-10-01" && $0.seriesID == "demo-gym" })
        XCTAssertEqual(events.filter { $0.title == "Weekly team sync" }.count, 6)
        XCTAssertEqual(events.filter { $0.title == "Yoga" }.count, 7)

        // One-off items stay where the seed put them, near the real today.
        let oneOffs = DemoData.events(now: now, clock: clock).filter { !DemoData.isRecurringOccurrence($0) }
        XCTAssertFalse(oneOffs.isEmpty)
        XCTAssertTrue(Set(events.map(\.id)).isDisjoint(with: oneOffs.map(\.id)))
        XCTAssertFalse(events.contains { $0.id == DemoData.meetingID || $0.isAllDay })
    }

    func testOverlappingRangesProduceTheSameOccurrences() {
        let early = DateInterval(start: TestClock.local(2027, 10, 1), end: TestClock.local(2027, 10, 20))
        let late = DateInterval(start: TestClock.local(2027, 10, 10), end: TestClock.local(2027, 11, 1))
        let whole = DateInterval(start: early.start, end: late.end)

        let a = DemoData.recurringEvents(in: early, clock: clock)
        let b = DemoData.recurringEvents(in: late, clock: clock)
        let merged = Dictionary((a + b).map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            XCTAssertEqual(first, second) // the same occurrence, whichever range produced it
            return first
        })
        XCTAssertEqual(Set(merged.keys), Set(DemoData.recurringEvents(in: whole, clock: clock).map(\.id)))
        XCTAssertTrue(DemoData.recurringEvents(in: DateInterval(start: whole.start, duration: 0), clock: clock).isEmpty)
    }

    func testSeedIsOneOffsPlusTheSeriesOverItsWindow() {
        let window = DemoData.seedWindow(now: now, clock: clock)
        XCTAssertEqual(window, DateInterval(start: TestClock.local(2026, 10, 4), end: TestClock.local(2026, 11, 22)))

        let seed = DemoData.events(now: now, clock: clock)
        XCTAssertEqual(Set(seed.map(\.id)).count, seed.count)
        XCTAssertTrue(seed.allSatisfy { $0.start >= window.start && $0.end <= window.end })
        XCTAssertTrue(seed.contains { $0.id == DemoData.meetingID })
        XCTAssertTrue(seed.contains { $0.id == "demo-trip-san-diego" })

        // Gym and Yoga pause during the trip (Thu 22 – Sat 24 Oct); the series is otherwise the plain one.
        let trip = DateInterval(start: TestClock.local(2026, 10, 22), end: TestClock.local(2026, 10, 25))
        let series = DemoData.recurringEvents(in: window, clock: clock, pausedDuring: trip)
        XCTAssertEqual(Set(seed.filter(DemoData.isRecurringOccurrence).map(\.id)), Set(series.map(\.id)))
        XCTAssertFalse(series.contains { $0.id == "demo-gym-2026-10-23" || $0.id == "demo-yoga-2026-10-24" })
        XCTAssertTrue(series.contains { $0.id == "demo-gym-2026-10-21" })
    }

    // MARK: Sample accounts

    func testSampleAccountsAndWhereEachSampleEventLives() {
        let accounts = DemoData.accounts
        XCTAssertEqual(accounts.map(\.email), ["example@gmail.com", "example@yourmail.com"])
        XCTAssertTrue(accounts.allSatisfy { $0.isDemo && $0.canListCalendars && !$0.needsReconnect })
        XCTAssertEqual(accounts[0].calendars.map(\.id), [DemoData.personalCalendar, DemoData.gymCalendar])
        XCTAssertEqual(accounts[0].calendars.map(\.googleColorHex), ["#039BE5", "#0B8043"])
        XCTAssertEqual(accounts[1].calendars.map(\.id), [DemoData.schoolCalendar])
        XCTAssertEqual(accounts[1].primaryCalendar?.googleColorHex, "#7986CB")
        XCTAssertTrue(accounts.flatMap(\.calendars).allSatisfy { $0.isWritable && $0.isVisible && $0.notificationsEnabled })
        XCTAssertEqual(accounts[0].primaryCalendar?.id, DemoData.defaultCalendar)
        XCTAssertEqual(accounts[1].calendars.first?.promptLabel, "My calendar | example@yourmail.com")

        let seed = DemoData.events(now: now, clock: clock)
        XCTAssertTrue(seed.allSatisfy { $0.calendarRef != nil })
        func calendar(_ title: String) -> Set<CalendarRef?> {
            Set((seed + DemoData.recurringEvents(in: DemoData.seedWindow(now: now, clock: clock), clock: clock))
                .filter { $0.title == title }.map(\.calendarRef))
        }
        XCTAssertEqual(calendar("Gym"), [DemoData.gymCalendar])
        XCTAssertEqual(calendar("Yoga"), [DemoData.gymCalendar])
        XCTAssertEqual(calendar("Weekly team sync"), [DemoData.schoolCalendar])
        XCTAssertEqual(calendar("Deadline for Plan 5008"), [DemoData.schoolCalendar])
        XCTAssertEqual(calendar("Lunch"), [DemoData.personalCalendar])
        XCTAssertEqual(calendar("Pay bills"), [DemoData.personalCalendar])

        // Tasks and deadlines keep their own colour; the rest follow their calendar's (and a local override).
        let sync = seed.first { $0.title == "Weekly team sync" }
        XCTAssertEqual(sync?.colorHex, "#7986CB")
        XCTAssertEqual(sync?.usesCalendarColor, true)
        let bills = seed.first { $0.title == "Pay bills" }
        XCTAssertEqual(bills?.colorHex, DemoData.taskHex)
        XCTAssertEqual(bills?.usesCalendarColor, false)
    }

    func testTheSampleWeekIgnoresWeekStart() {
        let mondayFirst = WallClock(timeZone: TestClock.zone, firstWeekday: 2)
        XCTAssertEqual(DemoData.seedWindow(now: now, clock: mondayFirst), DemoData.seedWindow(now: now, clock: clock))
    }
}
