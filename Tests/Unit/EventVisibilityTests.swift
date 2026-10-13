import XCTest

/// Which cached copies a surface shows: hidden and muted calendars, the Focus filter, demo mode, colour overrides
/// and one copy per meeting seen through several accounts.
final class EventVisibilityTests: XCTestCase {
    private let personal = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
    private let gym = CalendarRef(accountID: "111", calendarID: "gym@group.calendar.google.com")
    private let school = CalendarRef(accountID: "222", calendarID: "student@university.example.edu")
    private let shared = CalendarRef(accountID: "222", calendarID: "team@group.calendar.google.com")

    private func rules() -> VisibilityRules {
        var rules = VisibilityRules()
        for (rank, calendar) in [personal, gym, school, shared].enumerated() { rules.rank[calendar.key] = rank }
        rules.writable = [personal.key, gym.key, school.key]
        rules.calendarColors = [personal.key: "#039BE5", gym.key: "#0B8043", school.key: "#7986CB", shared.key: "#E67C73"]
        return rules
    }

    private func event(_ id: String, _ calendar: CalendarRef?, hour: Int = 9, uid: String? = nil,
                       organizer: Bool? = nil, usesCalendarColor: Bool? = nil) -> ScheduleEvent {
        TestEvents.make(id: id, start: TestClock.local(2026, 10, 14, hour), end: TestClock.local(2026, 10, 14, hour + 1),
                        colorHex: "#616161", calendar: calendar, iCalUID: uid, isOrganizer: organizer,
                        usesCalendarColor: usesCalendarColor)
    }

    private func ids(_ events: [ScheduleEvent], _ rules: VisibilityRules, _ audience: EventAudience = .display) -> [String] {
        EventVisibility.apply(events, rules: rules, audience: audience).map(\.id)
    }

    // MARK: Filters

    func testHiddenCalendarsAreLeftOutOfEveryAudience() {
        var rules = rules()
        rules.hidden = [gym.key]
        let events = [event("a", personal), event("b", gym, hour: 10)]
        XCTAssertEqual(ids(events, rules), ["a"])
        XCTAssertEqual(ids(events, rules, .reminders), ["a"])
    }

    func testMutedCalendarsShowButSendNoReminders() {
        var rules = rules()
        rules.muted = [school.key]
        let events = [event("a", personal), event("b", school, hour: 10)]
        XCTAssertEqual(ids(events, rules), ["a", "b"])
        XCTAssertEqual(ids(events, rules, .reminders), ["a"])
    }

    func testFocusFilterKeepsOnlyItsCalendarsButNeverHidesUnknownOnes() {
        var rules = rules()
        rules.focusAllowed = [school.key]
        let removed = CalendarRef(accountID: "333", calendarID: "gone@example.com")
        let events = [event("a", personal), event("b", school, hour: 10), event("c", nil, hour: 11), event("d", removed, hour: 12)]
        XCTAssertEqual(ids(events, rules), ["b", "c", "d"])
        XCTAssertEqual(ids(events, rules, .reminders), ["b", "c", "d"])
    }

    func testUnknownCalendarsAreVisibleAndReminded() {
        var rules = rules()
        rules.hidden = [gym.key]
        rules.muted = [personal.key]
        let unknown = CalendarRef(accountID: "999", calendarID: "elsewhere")
        XCTAssertEqual(ids([event("a", unknown), event("b", nil, hour: 10)], rules, .reminders), ["a", "b"])
    }

    func testDemoModeShowsOnlySampleEventsAndDrafts() {
        let sample = event(DemoData.idPrefix + "gym-2026-10-14", DemoData.gymCalendar)
        let google = event("abc", personal, hour: 10)
        let draft = event(PlanDraft.eventIDPrefix + "p-1", nil, hour: 11)
        var rules = rules()
        rules.isDemoMode = true
        XCTAssertEqual(ids([sample, google, draft], rules), [sample.id, draft.id])
        rules.isDemoMode = false
        XCTAssertEqual(ids([sample, google, draft], rules), [google.id, draft.id])
        rules.separatesDemoEvents = false
        XCTAssertEqual(ids([sample, google, draft], rules), [sample.id, google.id, draft.id])
    }

    func testCalendarColourAppliesOnlyToEventsWithoutTheirOwn() {
        var rules = rules()
        rules.calendarColors[personal.key] = "#D50000" // local override
        let plain = event("a", personal, usesCalendarColor: true)
        let coloured = event("b", personal, hour: 10, usesCalendarColor: false)
        let shown = EventVisibility.apply([plain, coloured], rules: rules, audience: .display)
        XCTAssertEqual(shown.map(\.colorHex), ["#D50000", "#616161"])
    }

    func testSortedByStart() {
        let events = [event("late", personal, hour: 15), event("early", school, hour: 8), event("mid", nil, hour: 11)]
        XCTAssertEqual(ids(events, rules()), ["early", "mid", "late"])
    }

    // MARK: De-duplication

    /// One meeting in two accounts: Google gives each attendee's copy the same iCalUID (and usually the same id).
    func testOrganizersCopyWins() {
        let attendee = event("m1", personal, uid: "uid-1@google.com", organizer: false)
        let organizer = event("m1", school, uid: "uid-1@google.com", organizer: true)
        let shown = EventVisibility.apply([attendee, organizer], rules: rules(), audience: .display)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.calendarRef, school)
    }

    func testThenAWritableCopyThenTheDefaultTargetThenAccountOrder() {
        let readOnly = event("x", shared, uid: "uid-2")
        let writable = event("y", school, uid: "uid-2")
        XCTAssertEqual(EventVisibility.apply([readOnly, writable], rules: rules(), audience: .display).map(\.calendarRef), [school])

        var rules = rules()
        let first = event("p", personal, uid: "uid-3")
        let second = event("q", school, uid: "uid-3")
        XCTAssertEqual(EventVisibility.apply([second, first], rules: rules, audience: .display).map(\.calendarRef), [personal])
        rules.defaultTarget = school.key
        XCTAssertEqual(EventVisibility.apply([first, second], rules: rules, audience: .display).map(\.calendarRef), [school])
    }

    func testTheSameRawIDIsNeverShownTwice() {
        // No iCalUID at all, different starts: still one id on screen (notification ids and selection use it).
        let a = event("same", personal, hour: 9)
        let b = event("same", gym, hour: 10)
        let shown = EventVisibility.apply([a, b], rules: rules(), audience: .display)
        XCTAssertEqual(shown.map(\.id), ["same"])
        XCTAssertEqual(shown.first?.calendarRef, personal)
    }

    func testInstancesOfASeriesStayApart() {
        // Every instance of a series shares the iCalUID; the start tells them apart.
        let monday = event("s_20261012T090000Z", personal, hour: 9, uid: "series-uid")
        let tuesday = event("s_20261013T090000Z", personal, hour: 10, uid: "series-uid")
        XCTAssertEqual(ids([monday, tuesday], rules()).count, 2)
    }

    func testHiddenWinnerLetsTheOtherCopyShow() {
        var rules = rules()
        let organizer = event("m", personal, uid: "uid-4", organizer: true)
        let attendee = event("m", school, uid: "uid-4", organizer: false)
        XCTAssertEqual(EventVisibility.apply([organizer, attendee], rules: rules, audience: .display).map(\.calendarRef), [personal])
        rules.hidden = [personal.key]
        XCTAssertEqual(EventVisibility.apply([organizer, attendee], rules: rules, audience: .display).map(\.calendarRef), [school])
    }
}
