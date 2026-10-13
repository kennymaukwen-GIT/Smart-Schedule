import XCTest

/// Text versions of replies (Siri, notifications, VoiceOver) and the date pieces the chat cards reuse.
/// Locales are explicit so the expected strings do not depend on the simulator's settings.
final class ReplyFormatterTests: XCTestCase {
    private let clock = TestClock.clock
    private let english = Locale(identifier: "en_US")
    private let chinese = Locale(identifier: "zh_Hant_TW")
    /// Tuesday 2026-10-13 10:15 BST.
    private let now = TestClock.local(2026, 10, 13, 10, 15)

    private var lunch: ScheduleEvent {
        TestEvents.make(id: "lunch", title: "Lunch with Andrew",
                        start: TestClock.local(2026, 10, 14, 13, 0), end: TestClock.local(2026, 10, 14, 14, 0))
    }

    private var gym: ScheduleEvent {
        TestEvents.make(id: "gym", title: "Gym",
                        start: TestClock.local(2026, 10, 16, 18, 0), end: TestClock.local(2026, 10, 16, 19, 0))
    }

    private func day(_ value: Int) -> DateInterval {
        DateInterval(start: TestClock.local(2026, 10, value), end: TestClock.local(2026, 10, value + 1))
    }

    // MARK: Dates and times

    func testDayLabels() {
        let wednesday = TestClock.local(2026, 10, 14)
        XCTAssertEqual(ReplyFormatter.dayLabel(wednesday, clock: clock, locale: english), "Wed, Oct 14")
        XCTAssertEqual(ReplyFormatter.dayLabel(wednesday, clock: clock, locale: chinese), "10月14日（週三）")
        XCTAssertEqual(ReplyFormatter.shortDate(wednesday, clock: clock, locale: english), "Oct 14")
        XCTAssertEqual(ReplyFormatter.shortDate(wednesday, clock: clock, locale: chinese), "10月14日")
    }

    func testTimesAreTwentyFourHourInTheClocksZone() {
        XCTAssertEqual(ReplyFormatter.clockTime(TestClock.local(2026, 10, 14, 13, 5), clock: clock), "13:05")
        XCTAssertEqual(ReplyFormatter.clockTime(TestClock.local(2026, 10, 14, 7, 0), clock: clock), "07:00")
        // 18:30 in London on both sides of the October clock change.
        XCTAssertEqual(ReplyFormatter.clockTime(TestClock.utc(2026, 10, 22, 17, 30), clock: clock), "18:30")
        XCTAssertEqual(ReplyFormatter.clockTime(TestClock.utc(2026, 10, 26, 18, 30), clock: clock), "18:30")
        XCTAssertEqual(ReplyFormatter.timeRange(lunch, clock: clock), "13:00–14:00")
    }

    func testWhen() {
        XCTAssertEqual(ReplyFormatter.when(lunch, clock: clock, locale: english), "Wed, Oct 14 · 13:00–14:00")
        XCTAssertEqual(ReplyFormatter.when(lunch, clock: clock, locale: chinese), "10月14日（週三）13:00–14:00")

        let holiday = TestEvents.make(id: "hol", title: "Holiday", start: TestClock.local(2026, 10, 16),
                                      end: TestClock.local(2026, 10, 17), allDay: true)
        XCTAssertEqual(ReplyFormatter.when(holiday, clock: clock, locale: english), "Fri, Oct 16 · " + ReplyFormatter.allDayLabel)

        let trip = TestEvents.make(id: "trip", title: "Trip", start: TestClock.local(2026, 10, 16),
                                   end: TestClock.local(2026, 10, 19), allDay: true)
        XCTAssertEqual(ReplyFormatter.when(trip, clock: clock, locale: english), "Fri, Oct 16 – Sun, Oct 18")
    }

    // MARK: Text versions

    func testConfirmation() {
        XCTAssertEqual(ReplyFormatter.confirmation(for: [lunch], clock: clock, locale: english),
                       "Added: Lunch with Andrew · Wed, Oct 14 · 13:00–14:00")
        XCTAssertEqual(ReplyFormatter.confirmation(for: [lunch, gym], clock: clock, locale: english).components(separatedBy: "\n"),
                       ["Added 2 events:",
                        "• Lunch with Andrew · Wed, Oct 14 · 13:00–14:00",
                        "• Gym · Fri, Oct 16 · 18:00–19:00"])
        XCTAssertEqual(ReplyFormatter.confirmation(for: [], clock: clock), "")
    }

    func testUpdatedAndDeletePrompt() {
        XCTAssertEqual(ReplyFormatter.updated(lunch, clock: clock, locale: english),
                       "Updated: Lunch with Andrew · Wed, Oct 14 · 13:00–14:00")
        XCTAssertEqual(ReplyFormatter.updated(nil, clock: clock), "Updated.")
        XCTAssertEqual(ReplyFormatter.deletePrompt("Gym"), "Delete Gym? Tap Confirm.")
    }

    func testAgendaTitles() {
        func title(_ range: DateInterval) -> String {
            ReplyFormatter.agendaTitle(for: range, now: now, clock: clock, locale: english)
        }
        XCTAssertEqual(title(day(13)), "Today · Tue, Oct 13")
        XCTAssertEqual(title(day(14)), "Tomorrow · Wed, Oct 14")
        XCTAssertEqual(title(day(12)), "Yesterday · Mon, Oct 12")
        XCTAssertEqual(title(day(16)), "Fri, Oct 16")
        // The clocks go back on Oct 25: a 25-hour day is still one day.
        XCTAssertEqual(title(day(25)), "Sun, Oct 25")
        // Weeks start on Sunday.
        XCTAssertEqual(title(DateInterval(start: TestClock.local(2026, 10, 11), end: TestClock.local(2026, 10, 18))),
                       "This week · Oct 11 – Oct 17")
        XCTAssertEqual(title(DateInterval(start: TestClock.local(2026, 10, 20), end: TestClock.local(2026, 10, 23))),
                       "Oct 20 – Oct 22")
        XCTAssertEqual(ReplyFormatter.agendaTitle(for: day(14), now: now, clock: clock, locale: chinese),
                       ReplyFormatter.relativeDayName(TestClock.local(2026, 10, 14), now: now, clock: clock)! + " · 10月14日（週三）")
    }

    func testAgendaTextHasAlignedRows() {
        let holiday = TestEvents.make(id: "hol", title: "Holiday", start: TestClock.local(2026, 10, 14),
                                      end: TestClock.local(2026, 10, 15), allDay: true)
        let digest = AgendaDigest(range: day(14), title: "Tomorrow · Wed, Oct 14", events: [holiday, lunch])
        XCTAssertEqual(ReplyFormatter.agenda(digest, clock: clock, locale: english).components(separatedBy: "\n"),
                       ["Tomorrow · Wed, Oct 14", "• All day  Holiday", "• 13:00  Lunch with Andrew"])

        let empty = AgendaDigest(range: day(14), title: "Tomorrow · Wed, Oct 14", events: [])
        XCTAssertEqual(ReplyFormatter.agenda(empty, clock: clock), "Tomorrow · Wed, Oct 14\n" + ReplyFormatter.nothingScheduled)
    }

    func testAgendaTextGroupsDaysAndCapsRows() {
        let week = DateInterval(start: TestClock.local(2026, 10, 11), end: TestClock.local(2026, 10, 18))
        let digest = AgendaDigest(range: week, title: "This week", events: [lunch, gym])
        XCTAssertEqual(ReplyFormatter.agenda(digest, clock: clock, locale: english).components(separatedBy: "\n"),
                       ["This week", "Wed, Oct 14", "• 13:00  Lunch with Andrew", "Fri, Oct 16", "• 18:00  Gym"])

        let many = (0..<10).map { index in
            TestEvents.make(id: "e\(index)", title: "E\(index)",
                            start: TestClock.local(2026, 10, 14, 8 + index), end: TestClock.local(2026, 10, 14, 9 + index))
        }
        let lines = ReplyFormatter.agenda(AgendaDigest(range: day(14), title: "T", events: many), clock: clock)
            .components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 10) // title, 8 rows, "+2 more"
        XCTAssertEqual(lines[1], "• 08:00  E0")
        XCTAssertEqual(lines.last, "+2 more")
    }

    // MARK: Plan review

    func testPlanReviewTextsAreShortAndPlain() {
        let texts = [ReplyFormatter.planReviewPrompt, ReplyFormatter.planEditQuestion, ReplyFormatter.planDiscarded]
            + ReplyFormatter.planEditSuggestions
        for text in texts {
            XCTAssertFalse(text.contains("/"), text)
        }
        XCTAssertEqual(ReplyFormatter.planReviewPrompt.filter { ".!?".contains($0) }.count, 1, "one sentence")
        XCTAssertEqual(ReplyFormatter.planAdded("Muscle 6M"), "Added “Muscle 6M” to Google Calendar.")
    }

    // MARK: "Ask me first" and settings by voice

    private func batch(_ events: [ScheduleEvent]) -> PendingEventBatch {
        PendingEventBatch(id: "batch-abc12345", createdAt: now, utterance: "u", seed: "s",
                          argsJSON: Data("{}".utf8), previewEvents: events)
    }

    func testPendingEventsSummary() {
        XCTAssertEqual(ReplyFormatter.pendingEventsSummary(batch([lunch]), clock: clock, locale: english),
                       "Ready to add: Lunch with Andrew · Wed, Oct 14 · 13:00–14:00")
        XCTAssertEqual(ReplyFormatter.pendingEventsSummary(batch([gym, lunch]), clock: clock, locale: english)
                           .components(separatedBy: "\n"),
                       ["Ready to add 2 events:",
                        "• Lunch with Andrew · Wed, Oct 14 · 13:00–14:00",
                        "• Gym · Fri, Oct 16 · 18:00–19:00"])
        XCTAssertEqual(ReplyFormatter.pendingEventsSummary(batch([]), clock: clock, locale: english), "")
        XCTAssertEqual(ReplyFormatter.pendingEventsPrompt, "Tap Add to put it in your calendar, or Edit to change it.")
        XCTAssertEqual(ReplyFormatter.pendingEventsAdded(1), "Added 1 event to Google Calendar.")
        XCTAssertEqual(ReplyFormatter.pendingEventsAdded(3), "Added 3 events to Google Calendar.")
        XCTAssertFalse(ReplyFormatter.pendingEventsDiscarded.contains("/"))
    }

    func testPreferenceReceiptText() {
        let receipt = PreferenceChangeReceipt(
            id: UUID(), date: now, source: .voice(utterance: "8 點前不要提醒我"),
            changes: [PreferenceChange(key: .quietHours, oldValue: "off 22:00-07:00", newValue: "on 22:00-08:00",
                                       oldDisplay: "Off", newDisplay: "22:00–08:00", replacedEntry: nil)])
        XCTAssertEqual(ReplyFormatter.preferencesUpdated(receipt).components(separatedBy: "\n"),
                       ["Settings updated", "• \(PreferenceKey.quietHours.title): Off → 22:00–08:00"])
    }

    func testRejectedPreferencesNameTheSettingNotTheReason() {
        XCTAssertNil(ReplyFormatter.preferencesRejected([]))
        let text = ReplyFormatter.preferencesRejected([
            PreferenceRejection(key: "quiet_hours", value: "10pm", reason: "quiet_hours must be HH:mm-HH:mm or off"),
            PreferenceRejection(key: "quiet_hours", value: "x", reason: "again"),
            PreferenceRejection(key: "theme", value: "dark", reason: "unknown key")
        ])
        XCTAssertEqual(text, "I couldn't change \(PreferenceKey.quietHours.title), theme. You can change it in Settings.")
        XCTAssertFalse(text?.contains("HH:mm") ?? true)
    }
}
