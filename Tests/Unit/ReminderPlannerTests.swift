import UserNotifications
import XCTest

final class ReminderPlannerTests: XCTestCase {
    private let clock = TestClock.clock
    /// Wednesday 2026-10-14 10:00 BST.
    private let now = TestClock.local(2026, 10, 14, 10, 0)

    private func event(_ id: String,
                       _ title: String = "Event",
                       start: Date,
                       minutes: Double = 60,
                       kind: ScheduleEvent.Kind = .event,
                       reminders: [Int]? = nil) -> ScheduleEvent {
        var event = TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60), kind: kind)
        event.reminderMinutes = reminders
        return event
    }

    private func allDay(_ id: String, _ title: String, on day: Date, reminders: [Int]? = nil,
                        kind: ScheduleEvent.Kind = .event) -> ScheduleEvent {
        let end = clock.calendar.date(byAdding: .day, value: 1, to: day)!
        var event = TestEvents.make(id: id, title: title, start: day, end: end, allDay: true, kind: kind)
        event.reminderMinutes = reminders
        return event
    }

    private func plan(_ events: [ScheduleEvent],
                      briefing: [ScheduleEvent]? = nil,
                      nudges: [PlanNudge] = [],
                      preferences: AppPreferences = AppPreferences()) -> ReminderPlan {
        ReminderPlanner.plan(reminderEvents: events, briefingEvents: briefing ?? events, nudges: nudges,
                             preferences: preferences, now: now, clock: clock)
    }

    private func candidates(_ events: [ScheduleEvent], _ preferences: AppPreferences = AppPreferences()) -> [PlannedReminder] {
        ReminderPlanner.candidates(events: events, preferences: preferences, now: now, clock: clock)
            .sorted(by: ReminderPlanner.soonestFirst)
    }

    // MARK: Offsets

    func testDefaultOffsetsFireBeforeTheStart() {
        let meeting = event("m", start: TestClock.local(2026, 10, 15, 14))
        let reminders = candidates([meeting])
        XCTAssertEqual(reminders.map(\.minutes), [1440, 60, 30, 0])
        XCTAssertEqual(reminders.map(\.fire), [TestClock.local(2026, 10, 14, 14), TestClock.local(2026, 10, 15, 13),
                                               TestClock.local(2026, 10, 15, 13, 30), TestClock.local(2026, 10, 15, 14)])
        XCTAssertTrue(reminders.allSatisfy(\.fromDefaults))
        XCTAssertEqual(reminders.last?.identifier, "ss.reminder.m.0")
    }

    func testDefaultsComeFromPreferences() {
        var preferences = AppPreferences()
        preferences.eventReminders = [120]
        preferences.routineReminders = []
        let reminders = candidates([event("m", start: TestClock.local(2026, 10, 15, 14)),
                                    event("gym", start: TestClock.local(2026, 10, 15, 18), kind: .routine)], preferences)
        XCTAssertEqual(reminders.map(\.identifier), ["ss.reminder.m.120"])
    }

    func testExplicitRemindersWinAndEmptyMeansNone() {
        let explicit = event("a", start: TestClock.local(2026, 10, 15, 14), reminders: [10])
        let none = event("b", start: TestClock.local(2026, 10, 15, 15), reminders: [])
        let reminders = candidates([explicit, none])
        XCTAssertEqual(reminders.map(\.identifier), ["ss.reminder.a.10"])
        XCTAssertEqual(reminders.first?.fromDefaults, false)
    }

    func testPastCompletedAndDraftEventsGetNothing() {
        var done = event("done", start: TestClock.local(2026, 10, 15, 9), kind: .task)
        done.isCompleted = true
        let past = event("past", start: TestClock.local(2026, 10, 14, 9))
        let draft = event("draft-ev-batch-1", start: TestClock.local(2026, 10, 15, 9))
        // Starts in 20 min: only the 0-minute ping is still ahead.
        let soon = event("soon", start: TestClock.local(2026, 10, 14, 10, 20))
        XCTAssertEqual(candidates([done, past, draft, soon]).map(\.identifier), ["ss.reminder.soon.0"])
    }

    func testAllDayReminderIsTheDayBeforeAtNine() throws {
        let holiday = allDay("h", "Holiday", on: TestClock.local(2026, 10, 16))
        let reminder = try XCTUnwrap(candidates([holiday]).first)
        XCTAssertTrue(reminder.isAllDay)
        XCTAssertEqual(reminder.minutes, 900)
        XCTAssertEqual(reminder.fire, TestClock.local(2026, 10, 15, 9))
        XCTAssertEqual(reminder.level, .active)

        var off = AppPreferences()
        off.allDayReminderMinutes = nil
        XCTAssertTrue(candidates([holiday], off).isEmpty)
    }

    func testAllDayReminderKeepsWallClockAcrossDST() throws {
        // Monday 26 Oct 2026: the clocks went back on Sunday, the reminder is still at 09:00 local.
        let day = allDay("d", "Deadline", on: TestClock.local(2026, 10, 26), reminders: [900, 1500], kind: .deadline)
        let reminders = candidates([day])
        XCTAssertEqual(reminders.map(\.fire), [TestClock.local(2026, 10, 24, 23), TestClock.local(2026, 10, 25, 9)])
        XCTAssertEqual(ReminderPlanner.allDayFireDate(eventStart: TestClock.local(2026, 10, 26), minutes: 0, clock: clock),
                       TestClock.local(2026, 10, 26))
    }

    // MARK: Urgency and quiet hours

    func testAutomaticUrgencyIsTheOriginalRule() {
        let meeting = event("m", start: TestClock.local(2026, 10, 15, 14))
        let levels = Dictionary(uniqueKeysWithValues: candidates([meeting]).map { ($0.minutes, $0.level) })
        XCTAssertEqual(levels[1440], .active)
        XCTAssertEqual(levels[60], .active)
        XCTAssertEqual(levels[30], .timeSensitive)
        XCTAssertEqual(levels[0], .timeSensitive)
    }

    func testUrgencyPerKind() {
        var preferences = AppPreferences()
        preferences.deadlineUrgency = .timeSensitive
        preferences.eventUrgency = .normal
        preferences.taskUrgency = .quiet
        let reminders = candidates([
            event("d", start: TestClock.local(2026, 10, 16, 12), kind: .deadline, reminders: [1440]),
            event("e", start: TestClock.local(2026, 10, 16, 13), reminders: [0]),
            event("t", start: TestClock.local(2026, 10, 16, 14), kind: .task, reminders: [10])
        ], preferences)
        XCTAssertEqual(reminders.map(\.level), [.timeSensitive, .active, .passive])
    }

    func testQuietHoursAcrossMidnightDeliverSilentlyAndDropNothing() {
        var preferences = AppPreferences()
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        let early = event("early", start: TestClock.local(2026, 10, 15, 7), reminders: [30, 0])
        let late = event("late", start: TestClock.local(2026, 10, 15, 23), reminders: [10])
        let reminders = candidates([early, late], preferences)
        XCTAssertEqual(reminders.map(\.identifier), ["ss.reminder.early.30", "ss.reminder.early.0", "ss.reminder.late.10"])
        XCTAssertEqual(reminders.map(\.level), [.passive, .timeSensitive, .passive])
    }

    func testRequestsCarryLevelSoundAndUserInfo() throws {
        var preferences = AppPreferences()
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        let reminders = candidates([event("m", "Standup", start: TestClock.local(2026, 10, 15, 7), reminders: [30, 0])], preferences)
        let quiet = ReminderScheduler.request(for: reminders[0], clock: clock)
        XCTAssertEqual(quiet.identifier, "ss.reminder.m.30")
        XCTAssertEqual(quiet.content.interruptionLevel, .passive)
        XCTAssertNil(quiet.content.sound)
        XCTAssertEqual(quiet.content.categoryIdentifier, NotificationIDs.Category.eventReminder)
        XCTAssertEqual(quiet.content.subtitle, "In 30 min")
        XCTAssertEqual(quiet.content.body, "07:00")
        XCTAssertEqual(quiet.content.userInfo[NotificationIDs.UserInfo.eventID] as? String, "m")
        XCTAssertEqual(quiet.content.userInfo[NotificationIDs.UserInfo.kind] as? String, "event")
        XCTAssertEqual(quiet.content.userInfo[NotificationIDs.UserInfo.offset] as? Int, 30)
        XCTAssertEqual(quiet.content.userInfo[NotificationIDs.UserInfo.allDay] as? Bool, false)
        XCTAssertEqual(quiet.content.userInfo[NotificationIDs.UserInfo.fromDefaults] as? Bool, false)

        let loud = ReminderScheduler.request(for: reminders[1], clock: clock)
        XCTAssertEqual(loud.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(loud.content.sound)
        XCTAssertEqual(loud.content.relevanceScore, 1.0)

        let holiday = try XCTUnwrap(candidates([allDay("h", "Holiday", on: TestClock.local(2026, 10, 16))]).first)
        let allDayRequest = ReminderScheduler.request(for: holiday, clock: clock)
        XCTAssertEqual(allDayRequest.content.subtitle, "Tomorrow")
        XCTAssertEqual(allDayRequest.content.body, "All day")
        XCTAssertEqual(allDayRequest.content.userInfo[NotificationIDs.UserInfo.allDay] as? Bool, true)
        XCTAssertEqual(allDayRequest.content.userInfo[NotificationIDs.UserInfo.fromDefaults] as? Bool, true)
    }

    // MARK: Source modes

    func testGoogleOnlySchedulesNoRemindersButKeepsBriefingsAndNudges() {
        var preferences = AppPreferences()
        preferences.reminderSource = .google
        let tomorrow = event("m", start: TestClock.local(2026, 10, 15, 14))
        let nudge = PlanNudge(planID: "p", hour: 7, minute: 0, message: "Gym today", endsOn: TestClock.local(2027, 1, 1))
        let result = plan([tomorrow], nudges: [nudge], preferences: preferences)
        XCTAssertTrue(result.reminders.isEmpty)
        XCTAssertEqual(result.nudges, [nudge])
        XCTAssertEqual(result.briefings.map(\.identifier), ["ss.briefing.morning.2026-10-15"])
    }

    func testSmartScheduleOnlyStillSchedulesLocalReminders() {
        var preferences = AppPreferences()
        preferences.reminderSource = .smartSchedule
        XCTAssertEqual(plan([event("m", start: TestClock.local(2026, 10, 15, 14))], preferences: preferences).reminders.count, 4)
    }

    // MARK: Daily cap

    func testDailyCapKeepsTheMostImportantAndListsTheRestInTheMorningBriefing() throws {
        var preferences = AppPreferences()
        preferences.dailyReminderCap = 2
        let day = [
            event("task", "Reply to Joe", start: TestClock.local(2026, 10, 15, 12), kind: .task, reminders: [60]),
            event("meet", "Team sync", start: TestClock.local(2026, 10, 15, 15), reminders: [0]),
            event("due", "Essay due", start: TestClock.local(2026, 10, 15, 17), kind: .deadline, reminders: [60]),
            event("gym", "Gym", start: TestClock.local(2026, 10, 15, 18, 30), kind: .routine, reminders: [30])
        ]
        let result = plan(day, preferences: preferences)
        XCTAssertEqual(result.reminders.map(\.identifier), ["ss.reminder.meet.0", "ss.reminder.due.60"])
        XCTAssertEqual(result.capped["2026-10-15"]?.map(\.event.title), ["Reply to Joe", "Gym"])
        let morning = try XCTUnwrap(result.briefings.first { $0.identifier == "ss.briefing.morning.2026-10-15" })
        XCTAssertTrue(morning.content.body.hasSuffix("Not sent as reminders: Reply to Joe, Gym"))
    }

    func testCapPriorityOrder() {
        func reminder(_ kind: ScheduleEvent.Kind, _ minutes: Int, allDay: Bool = false) -> PlannedReminder {
            PlannedReminder(event: event("x", start: now, kind: kind), minutes: minutes, isAllDay: allDay,
                            fromDefaults: true, fire: now, level: .active)
        }
        XCTAssertEqual(ReminderPlanner.priority(reminder(.event, 0)), 0)
        XCTAssertEqual(ReminderPlanner.priority(reminder(.deadline, 60)), 1)
        XCTAssertEqual(ReminderPlanner.priority(reminder(.event, 60)), 2)
        XCTAssertEqual(ReminderPlanner.priority(reminder(.event, 0, allDay: true)), 2)
        XCTAssertEqual(ReminderPlanner.priority(reminder(.task, 0)), 3)
        XCTAssertEqual(ReminderPlanner.priority(reminder(.routine, 0)), 4)
    }

    func testCapTiesKeepTheEarlierAndCountsEachDaySeparately() {
        var preferences = AppPreferences()
        preferences.dailyReminderCap = 1
        let events = [
            event("a", start: TestClock.local(2026, 10, 15, 9), kind: .task, reminders: [0]),
            event("b", start: TestClock.local(2026, 10, 15, 8), kind: .task, reminders: [0]),
            event("c", start: TestClock.local(2026, 10, 16, 9), kind: .task, reminders: [0])
        ]
        XCTAssertEqual(plan(events, preferences: preferences).reminders.map(\.identifier),
                       ["ss.reminder.b.0", "ss.reminder.c.0"])
    }

    func testOverflowIsNotSentWhenTheMorningBriefingIsOff() {
        var preferences = AppPreferences()
        preferences.dailyReminderCap = 1
        preferences.morningBriefing.isEnabled = false
        let events = [
            event("a", start: TestClock.local(2026, 10, 15, 9), kind: .task, reminders: [0]),
            event("b", start: TestClock.local(2026, 10, 15, 10), kind: .task, reminders: [0])
        ]
        let result = plan(events, preferences: preferences)
        XCTAssertEqual(result.reminders.map(\.identifier), ["ss.reminder.a.0"])
        XCTAssertTrue(result.briefings.isEmpty)
        XCTAssertEqual(result.capped["2026-10-15"]?.count, 1)
    }

    // MARK: Briefings

    func testBriefingSlotsIdentifiersAndDays() throws {
        var preferences = AppPreferences()
        preferences.eveningPreview.isEnabled = true
        let events = (14...17).map { day in event("e\(day)", "Day \(day)", start: TestClock.local(2026, 10, day, 12)) }
        let briefings = plan(events, preferences: preferences).briefings
        // 07:30 today has passed; 21:00 today has not.
        XCTAssertEqual(briefings.map(\.identifier), [
            "ss.briefing.evening.2026-10-14", "ss.briefing.morning.2026-10-15", "ss.briefing.evening.2026-10-15",
            "ss.briefing.morning.2026-10-16", "ss.briefing.evening.2026-10-16"
        ])
        XCTAssertEqual(briefings.map(\.describedDay), ["2026-10-15", "2026-10-15", "2026-10-16", "2026-10-16", "2026-10-17"])
        XCTAssertEqual(briefings.first?.fire, TestClock.local(2026, 10, 14, 21))
        XCTAssertEqual(briefings.first?.content.title, "Tomorrow")
        XCTAssertEqual(briefings[1].content.title, "Today")
        XCTAssertEqual(briefings[1].content.body, "1 event, at 12:00\n12:00 Day 15")

        let request = ReminderScheduler.briefingRequest(briefings[1])
        XCTAssertEqual(request.content.categoryIdentifier, NotificationIDs.Category.compose)
        XCTAssertEqual(request.content.threadIdentifier, "ss.briefing")
        XCTAssertEqual(request.content.userInfo[NotificationIDs.UserInfo.briefingDay] as? String, "2026-10-15")
        XCTAssertEqual(request.content.interruptionLevel, .active)
        XCTAssertNil(request.content.sound)
    }

    func testDaysWithoutEventsGetNoBriefing() {
        let result = plan([event("e", start: TestClock.local(2026, 10, 16, 12))])
        XCTAssertEqual(result.briefings.map(\.identifier), ["ss.briefing.morning.2026-10-16"])
    }

    func testBriefingInsideQuietHoursIsPassive() throws {
        var preferences = AppPreferences()
        preferences.morningBriefing.minuteOfDay = 6 * 60 + 30
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        let briefing = try XCTUnwrap(plan([event("e", start: TestClock.local(2026, 10, 15, 12))], preferences: preferences).briefings.first)
        XCTAssertTrue(briefing.isQuiet)
        XCTAssertEqual(ReminderScheduler.briefingRequest(briefing).content.interruptionLevel, .passive)
    }

    func testBriefingsUseTheDisplayAudience() {
        // A calendar with notifications off still shows in the briefing.
        let muted = event("muted", "Muted calendar", start: TestClock.local(2026, 10, 15, 12))
        let result = plan([], briefing: [muted])
        XCTAssertTrue(result.reminders.isEmpty)
        XCTAssertEqual(result.briefings.first?.content.body, "1 event, at 12:00\n12:00 Muted calendar")
    }

    // MARK: The 64 budget

    func testBudgetFillsSixtyTwoSlotsSoonestFirst() {
        let events = (0..<40).map { index in
            event("e\(index)", start: TestClock.local(2026, 10, 15, 8).addingTimeInterval(Double(index) * 3 * 3600))
        }
        let nudges = (0..<3).map { PlanNudge(planID: "p\($0)", hour: 7, minute: $0, message: "Nudge", endsOn: TestClock.local(2027, 1, 1)) }
        let expired = PlanNudge(planID: "old", hour: 7, minute: 0, message: "Old", endsOn: TestClock.local(2026, 10, 1))
        let result = plan(events, nudges: nudges + [expired])
        XCTAssertEqual(result.nudges.map(\.planID), ["p0", "p1", "p2"])
        XCTAssertEqual(result.requestCount, ReminderPlanner.pendingLimit - ReminderPlanner.spareSlots)
        XCTAssertEqual(result.briefings.count, 2)
        XCTAssertEqual(result.reminders.count, 57)
        let all = ReminderPlanner.candidates(events: events, preferences: AppPreferences(), now: now, clock: clock)
        let latestKept = result.reminders.map(\.fire).max()!
        let dropped = all.filter { candidate in !result.reminders.contains { $0.identifier == candidate.identifier } }
        XCTAssertEqual(dropped.count, all.count - 57)
        XCTAssertTrue(dropped.allSatisfy { $0.fire >= latestKept })
        XCTAssertEqual(result.reminders.map(\.fire), result.reminders.map(\.fire).sorted())
    }

    func testRescheduleTouchesOnlyItsOwnRequests() {
        XCTAssertTrue(ReminderScheduler.isRescheduled("ss.reminder.m.30"))
        XCTAssertTrue(ReminderScheduler.isRescheduled("ss.nudge.plan1"))
        XCTAssertTrue(ReminderScheduler.isRescheduled("ss.briefing.morning.2026-10-15"))
        XCTAssertFalse(ReminderScheduler.isRescheduled("ss.reminder.snooze.ABC"))
        XCTAssertFalse(ReminderScheduler.isRescheduled("ss.followup.ABC"))
    }

    func testLeadTexts() {
        XCTAssertEqual(ReminderScheduler.leadText(0), "Starting now")
        XCTAssertEqual(ReminderScheduler.leadText(30), "In 30 min")
        XCTAssertEqual(ReminderScheduler.leadText(120), "In 2 h")
        XCTAssertEqual(ReminderScheduler.leadText(1440), "Tomorrow")
        XCTAssertEqual(ReminderScheduler.allDayLeadText(0), "Today")
        XCTAssertEqual(ReminderScheduler.allDayLeadText(900), "Tomorrow")
        XCTAssertEqual(ReminderScheduler.allDayLeadText(2000), "In 2 days")
    }
}
