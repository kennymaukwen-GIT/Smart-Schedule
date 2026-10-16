import XCTest

/// Demo mode's offline rules for a time counted from now, as Gemini's prompt rule 7 has it: "1個小時後買蛋給 Jocelyn"
/// said at 22:50 is "買蛋給 Jocelyn" at 23:50 with a reminder at the start. Also: demo deletes only ever offer sample
/// events, never the hidden copies of the user's real ones still in the cache.
final class DemoAssistantFromNowTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 22:50:37 BST: the seconds show that the start counts from the minute it was said.
    private let now = TestClock.local(2026, 10, 13, 22, 50).addingTimeInterval(37)

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    /// Demo mode on (sample calendars, only `demo-` events shown), default settings in a file of their own.
    private func make() -> (assistant: DemoAssistant, preferences: PreferencesStore, store: SharedStore) {
        let accounts = AccountStore(fileURL: files.url("DemoAssistantFromNowTests-accounts"), isDemoMode: { true },
                                    defaultCalendar: { nil })
        let store = SharedStore(fileURL: files.url("DemoAssistantFromNowTests-cache"), accounts: accounts)
        let preferences = PreferencesStore(fileURL: files.url("DemoAssistantFromNowTests-prefs"))
        // No notification center in a hostless test bundle.
        let assistant = DemoAssistant(store: store, clock: TestClock.clock, preferences: preferences,
                                      rescheduleReminders: { _ in })
        return (assistant, preferences, store)
    }

    private func ask(_ assistant: DemoAssistant, _ text: String) async throws -> Reply {
        try await assistant.handle(text, focusEventID: nil, now: now)
    }

    // MARK: Added at once

    func testOneHourFromNowStartsAnHourAfterTheMinuteItWasSaid() async throws {
        let (assistant, preferences, store) = make()
        let reply = try await ask(assistant, "1個小時後買蛋給 Jocelyn")

        XCTAssertFalse(reply.needsClarification, reply.text)
        XCTAssertTrue(reply.changed)
        XCTAssertEqual(reply.addedEvents.count, 1)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertEqual(reply.created.map(\.id), [event.id])
        XCTAssertEqual(event.title, "買蛋給 Jocelyn", "the time phrase is not in the title")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.end, event.start.addingTimeInterval(TimeInterval(AppPreferences().defaultEventMinutes) * 60))
        XCTAssertEqual(event.reminderMinutes, [0], "a reminder at the start")
        XCTAssertTrue(event.id.hasPrefix("demo-chat-"), event.id)
        XCTAssertEqual(event.calendarRef, DemoData.personalCalendar)
        XCTAssertTrue(reply.text.contains(DemoAssistant.demoNote), reply.text)

        let cached = await store.snapshot().events
        XCTAssertEqual(cached.map(\.id), [event.id])
        XCTAssertNil(reply.preferenceReceipt)
        XCTAssertEqual(preferences.current(), AppPreferences())
    }

    func testPastMidnightIsTheNextDay() async throws {
        let reply = try await ask(make().assistant, "兩小時後打給媽媽")

        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertEqual(event.title, "打給媽媽")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 14, 0, 50))
        XCTAssertEqual(event.reminderMinutes, [0])
    }

    /// 提醒我 and 以後 here are about this one event: no preference changes, no default length of 2 hours.
    func testATimeFromNowIsAnEventNotAPreference() async throws {
        let (assistant, preferences, _) = make()

        let water = try await ask(assistant, "半小時後提醒我喝水")
        XCTAssertNil(water.preferenceReceipt, water.text)
        XCTAssertTrue(water.rejectedPreferences.isEmpty)
        let event = try XCTUnwrap(water.addedEvents.first)
        XCTAssertEqual(event.title, "喝水")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 20))
        XCTAssertEqual(event.reminderMinutes, [0])

        let meeting = try await ask(assistant, "兩個小時以後開會")
        XCTAssertNil(meeting.preferenceReceipt, meeting.text)
        XCTAssertEqual(meeting.addedEvents.map(\.title), ["開會"])
        XCTAssertEqual(meeting.addedEvents.first?.start, TestClock.local(2026, 10, 14, 0, 50))

        XCTAssertEqual(preferences.current(), AppPreferences())
    }

    func testEnglishTimesFromNow() async throws {
        let eggs = try await ask(make().assistant, "in an hour buy eggs")
        XCTAssertEqual(eggs.addedEvents.map(\.title), ["Buy eggs"])
        XCTAssertEqual(eggs.addedEvents.first?.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(eggs.addedEvents.first?.reminderMinutes, [0])

        let mom = try await ask(make().assistant, "call mom 2 hours from now")
        XCTAssertEqual(mom.addedEvents.map(\.title), ["Call mom"])
        XCTAssertEqual(mom.addedEvents.first?.start, TestClock.local(2026, 10, 14, 0, 50))

        let leave = try await ask(make().assistant, "in an hour and a half leave")
        XCTAssertEqual(leave.addedEvents.map(\.title), ["Leave"])
        XCTAssertEqual(leave.addedEvents.first?.start, TestClock.local(2026, 10, 14, 0, 20))
    }

    // MARK: Parsing

    func testAmountsCountedFromNow() {
        let cases: [(text: String, minutes: Int)] = [
            ("1個小時後買蛋給 Jocelyn", 60), ("一小時後打給媽媽", 60), ("兩小時後打給媽媽", 120), ("兩個小時以後開會", 120),
            ("半小時後提醒我喝水", 30), ("半個小時後喝水", 30), ("一個半小時後出門", 90), ("兩個半小時後出門", 150),
            ("10 分鐘後開會", 10), ("二十分鐘後吃藥", 20), ("120 分鐘後開會", 120), ("一個鐘頭後打電話", 60),
            ("1个小时后买蛋", 60), ("in an hour buy eggs", 60), ("buy eggs in 30 minutes", 30),
            ("in half an hour stretch", 30), ("in an hour and a half leave", 90), ("in 2h gym", 120),
            ("call mom 2 hours from now", 120), ("an hour from now: pay bills", 60)
        ]
        for entry in cases {
            XCTAssertEqual(DemoAssistant.fromNow(in: entry.text)?.minutes, entry.minutes, entry.text)
        }
        XCTAssertEqual(DemoAssistant.fromNow(in: "1個小時後買蛋給 Jocelyn")?.leftover, "買蛋給 Jocelyn")
        XCTAssertEqual(DemoAssistant.fromNow(in: "call mom 2 hours from now")?.leftover, "call mom")
    }

    /// Clock times followed by 後, moves, reminder lead times and lengths are not counted from now; nor is
    /// "in a minute" (English minutes need digits) or more than a day.
    func testOtherAmountsAreNotCountedFromNow() {
        for text in ["三點後打給 Joe", "3點10分後", "下午兩點半後", "15:00後開會", "延後 1 小時", "提前 2 小時提醒",
                     "明天開會 2 小時", "以後提前半小時提醒我", "10 點後別提醒我", "push it an hour later",
                     "remind me an hour before", "in a minute", "48 小時後", "lunch for 2 hours tomorrow 1pm"] {
            XCTAssertNil(DemoAssistant.fromNow(in: text), text)
        }
    }

    // MARK: Unchanged

    func testADayWithoutATimeStillAsksAndAMoveStillShifts() async throws {
        let asked = try await ask(make().assistant, "明天開會")
        XCTAssertTrue(asked.needsClarification)
        XCTAssertEqual(asked.text, "明天的「開會」要排在幾點？")
        XCTAssertTrue(asked.addedEvents.isEmpty)

        let (assistant, _, store) = make()
        let gym = TestEvents.make(id: "demo-gym-fromnow", title: "Gym", start: TestClock.local(2026, 10, 14, 7, 0),
                                  end: TestClock.local(2026, 10, 14, 8, 0), kind: .routine,
                                  calendar: DemoData.gymCalendar)
        await store.upsert([gym])
        let shifted = try await ask(assistant, "下一個行程延後 30 分鐘")
        XCTAssertTrue(shifted.changed, shifted.text)
        XCTAssertTrue(shifted.addedEvents.isEmpty)
        let moved = await store.event(id: gym.id)
        XCTAssertEqual(moved?.start, TestClock.local(2026, 10, 14, 7, 30))
        XCTAssertEqual(moved?.end, TestClock.local(2026, 10, 14, 8, 30))
        let cached = await store.snapshot().events
        XCTAssertEqual(cached.map(\.id), [gym.id], "a move adds nothing")
    }

    // MARK: "Ask me first"

    func testAskFirstKeepsTheReminderAtTheStart() async throws {
        let (assistant, preferences, store) = make()
        await preferences.update { $0.autonomy = .askFirst }

        let reply = try await ask(assistant, "1個小時後買蛋給 Jocelyn")
        let batch = try XCTUnwrap(reply.pendingEvents)
        XCTAssertTrue(reply.addedEvents.isEmpty)
        XCTAssertFalse(reply.changed)
        let args = try TestJSON.object(batch.argsJSON)
        let draft = try XCTUnwrap((args["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(draft["title"] as? String, "買蛋給 Jocelyn")
        XCTAssertEqual(draft["start"] as? String, "2026-10-13T23:50")
        XCTAssertEqual(draft["reminder_minutes"] as? [Int], [0])
        XCTAssertEqual(batch.previewEvents.first?.start, TestClock.local(2026, 10, 13, 23, 50))
        let nothing = await store.snapshot().events
        XCTAssertTrue(nothing.isEmpty, "nothing is written before Add")

        let added = try await ask(assistant, "好")
        XCTAssertEqual(added.committedEventBatchID, batch.id)
        let event = try XCTUnwrap(added.addedEvents.first)
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.reminderMinutes, [0])
        XCTAssertTrue(DemoData.isDemoID(event.id), event.id)
    }

    // MARK: Deleting: sample data only

    /// The cache can still hold the user's real events (hidden in demo mode); "cancel the dentist" never offers them.
    func testDeletingNeverOffersTheUsersRealEvents() async throws {
        let (assistant, _, store) = make()
        let realCalendar = CalendarRef(accountID: "109876543210", calendarID: "someone@example.com")
        let real = TestEvents.make(id: "k2v9q0abc", title: "Dentist", start: TestClock.local(2026, 10, 14, 9, 0),
                                   end: TestClock.local(2026, 10, 14, 10, 0), calendar: realCalendar)
        await store.upsert([real])

        let none = try await ask(assistant, "cancel the dentist")
        XCTAssertNil(none.pendingDeletion, none.text)

        let sample = TestEvents.make(id: "demo-dentist-fromnow", title: "Dentist",
                                     start: TestClock.local(2026, 10, 16, 9, 30), end: TestClock.local(2026, 10, 16, 10, 30),
                                     calendar: DemoData.personalCalendar)
        await store.upsert([sample])
        let reply = try await ask(assistant, "cancel the dentist")
        XCTAssertEqual(reply.pendingDeletion?.eventIDs, [sample.id], "the sooner real Dentist is never picked")
        XCTAssertNil(reply.pendingDeletion?.planID)
    }

    /// "Delete the plan" picks the sample plan even when a real plan's nudge was stored after it.
    func testDeletingAPlanNeverOffersTheUsersRealPlan() async throws {
        let (assistant, _, store) = make()
        let realCalendar = CalendarRef(accountID: "109876543210", calendarID: "someone@example.com")
        let realSession = TestEvents.make(id: "r7session", title: "Run", start: TestClock.local(2026, 10, 14, 7, 0),
                                          end: TestClock.local(2026, 10, 14, 8, 0), kind: .routine, planID: "realplan1",
                                          calendar: realCalendar)
        await store.upsert([realSession])
        await store.addNudge(PlanNudge(planID: "realplan1", hour: 7, minute: 0, message: "Stretch",
                                       endsOn: TestClock.local(2026, 12, 31)))

        let none = try await ask(assistant, "delete the plan")
        XCTAssertNil(none.pendingDeletion, none.text)

        let goal = try await ask(assistant, "I want to be muscular in 6 months")
        let draft = try XCTUnwrap(goal.planDraft, goal.text)
        let committed = try await ask(assistant, "好")
        XCTAssertEqual(committed.committedPlanID, draft.id)
        // A real plan's nudge stored after the sample plan's.
        await store.addNudge(PlanNudge(planID: "realplan2", hour: 8, minute: 0, message: "Walk",
                                       endsOn: TestClock.local(2026, 12, 31)))

        let reply = try await ask(assistant, "delete the plan")
        let pending = try XCTUnwrap(reply.pendingDeletion, reply.text)
        XCTAssertEqual(pending.planID, draft.id)
        XCTAssertFalse(pending.eventIDs.isEmpty)
        XCTAssertTrue(pending.eventIDs.allSatisfy(DemoData.isDemoID), "\(pending.eventIDs)")
    }
}
