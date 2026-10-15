import XCTest

/// Replies the chat renders as structured rows instead of prose: events just added and agendas.
final class DemoAssistantReplyTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private var storeFiles: [URL] = []

    override func tearDown() {
        for url in storeFiles { try? FileManager.default.removeItem(at: url) }
        storeFiles = []
        super.tearDown()
    }

    private func makeAssistant() -> DemoAssistant {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DemoAssistantReplyTests-\(UUID().uuidString).json")
        let preferencesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoAssistantReplyTests-prefs-\(UUID().uuidString).json")
        storeFiles += [url, preferencesURL]
        // Default settings in a file of its own; no notification center in a hostless test bundle.
        return DemoAssistant(store: SharedStore(fileURL: url), clock: TestClock.clock,
                             preferences: PreferencesStore(fileURL: preferencesURL), rescheduleReminders: { _ in })
    }

    private func ask(_ assistant: DemoAssistant, _ text: String) async throws -> Reply {
        try await assistant.handle(text, focusEventID: nil, now: now)
    }

    // MARK: Added events

    func testCapturedEventIsListedForTheConfirmationRow() async throws {
        let assistant = makeAssistant()
        let reply = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")

        XCTAssertEqual(reply.addedEvents.count, 1)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertEqual(reply.created, reply.addedEvents)
        XCTAssertEqual(event.title, "Lunch with Andrew")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 14, 13, 0))
        XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 14, 0))
        XCTAssertNil(reply.agenda)
        // The text version: title, then the day and a 24-hour range.
        XCTAssertTrue(reply.text.hasPrefix("Added: Lunch with Andrew · "), reply.text)
        XCTAssertTrue(reply.text.contains("13:00–14:00"), reply.text)
        XCTAssertTrue(reply.text.contains(DemoAssistant.demoNote), reply.text)
    }

    func testMissingTimeIsAskedInTheUsersLanguage() async throws {
        let english = try await ask(makeAssistant(), "Dentist tomorrow")
        XCTAssertEqual(english.text, "What time should I schedule “Dentist” tomorrow?")
        XCTAssertTrue(english.needsClarification)
        XCTAssertTrue(english.addedEvents.isEmpty)

        let assistant = makeAssistant()
        let chinese = try await ask(assistant, "明天午餐")
        XCTAssertEqual(chinese.text, "明天的「午餐」要排在幾點？")
        XCTAssertEqual(chinese.suggestions, ["12:00", "12:30", "13:00"], "lunchtime, not the whole day")

        let answer = try await ask(assistant, "12:30")
        XCTAssertEqual(answer.addedEvents.map(\.title), ["午餐"])
        XCTAssertEqual(answer.addedEvents.first?.start, TestClock.local(2026, 10, 14, 12, 30))
    }

    /// Only a day, or only a part of the day, is not a time: nothing is added until the user says when.
    func testADayOrAPartOfTheDayAloneIsAskedAbout() async throws {
        let dayOnly = try await ask(makeAssistant(), "明天開線上會議")
        XCTAssertEqual(dayOnly.text, "明天的「開線上會議」要排在幾點？")
        XCTAssertEqual(dayOnly.suggestions, ["09:00", "14:00", "19:00"])
        XCTAssertTrue(dayOnly.needsClarification)
        XCTAssertTrue(dayOnly.addedEvents.isEmpty)

        let assistant = makeAssistant()
        let afternoon = try await ask(assistant, "明天下午開線上會議")
        XCTAssertEqual(afternoon.text, "明天下午的「開線上會議」要排在幾點？")
        XCTAssertEqual(afternoon.suggestions, ["13:00", "14:00", "15:00"])
        XCTAssertTrue(afternoon.addedEvents.isEmpty)
        // A bare hour answers in that part of the day.
        let answer = try await ask(assistant, "兩點")
        XCTAssertEqual(answer.addedEvents.map(\.title), ["開線上會議"])
        XCTAssertEqual(answer.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))

        let tonight = try await ask(makeAssistant(), "今晚吃火鍋")
        XCTAssertEqual(tonight.text, "今天晚上的「吃火鍋」要排在幾點？")
        XCTAssertEqual(tonight.suggestions, ["18:00", "19:00", "20:00"])

        let english = try await ask(makeAssistant(), "Dentist tomorrow afternoon")
        XCTAssertEqual(english.text, "What time should I schedule “Dentist” tomorrow afternoon?")
        XCTAssertEqual(english.suggestions, ["13:00", "14:00", "15:00"])

        let dinner = try await ask(makeAssistant(), "Dinner with Ann tonight")
        XCTAssertEqual(dinner.text, "What time should I schedule “Dinner with Ann” tonight?")
        XCTAssertEqual(dinner.suggestions, ["18:00", "19:00", "20:00"])

        // A clock time is enough on its own.
        let timed = try await ask(makeAssistant(), "明天下午兩點開線上會議")
        XCTAssertEqual(timed.addedEvents.map(\.title), ["開線上會議"])
        XCTAssertEqual(timed.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))
    }

    /// The answer completes the event asked about: its title, day and part of the day, and the request in its notes.
    func testTheAnswerCompletesTheEventAskedAbout() async throws {
        // "at 7" reads as 19:00 only when no part of the day says otherwise.
        let run = makeAssistant()
        let morning = try await ask(run, "Run tomorrow morning")
        XCTAssertEqual(morning.text, "What time should I schedule “Run” tomorrow morning?")
        let seven = try await ask(run, "at 7")
        XCTAssertEqual(seven.addedEvents.map(\.title), ["Run"])
        XCTAssertEqual(seven.addedEvents.first?.start, TestClock.local(2026, 10, 14, 7, 0))

        let breakfast = makeAssistant()
        _ = try await ask(breakfast, "Breakfast with Ann tomorrow")
        let breakfastAt7 = try await ask(breakfast, "at 7")
        XCTAssertEqual(breakfastAt7.addedEvents.first?.start, TestClock.local(2026, 10, 14, 7, 0))

        let dentist = makeAssistant()
        _ = try await ask(dentist, "Dentist tomorrow afternoon")
        let dentistAt3 = try await ask(dentist, "at 3")
        XCTAssertEqual(dentistAt3.addedEvents.first?.start, TestClock.local(2026, 10, 14, 15, 0))

        // A bare number answers the question; it is no event of its own.
        let bare = makeAssistant()
        _ = try await ask(bare, "Dentist tomorrow afternoon")
        let two = try await ask(bare, "2")
        XCTAssertEqual(two.addedEvents.map(\.title), ["Dentist"])
        XCTAssertEqual(two.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))
        let dayOnly = makeAssistant()
        _ = try await ask(dayOnly, "Dentist tomorrow")
        let dayOnlyTwo = try await ask(dayOnly, "2")
        XCTAssertEqual(dayOnlyTwo.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))
        let alone = try await ask(makeAssistant(), "2")
        XCTAssertTrue(alone.addedEvents.isEmpty)

        // A bare Chinese hour answering a question without a part of the day reads like "at 2".
        let meeting = makeAssistant()
        _ = try await ask(meeting, "明天開會")
        let meetingAt2 = try await ask(meeting, "兩點")
        XCTAssertEqual(meetingAt2.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))

        // Only a part of the day narrows the question; the event's notes keep the request.
        let narrowed = makeAssistant()
        _ = try await ask(narrowed, "明天開會")
        let afternoon = try await ask(narrowed, "下午")
        XCTAssertEqual(afternoon.text, "明天下午的「開會」要排在幾點？")
        XCTAssertEqual(afternoon.suggestions, ["13:00", "14:00", "15:00"])
        XCTAssertTrue(afternoon.addedEvents.isEmpty)
        let answer = try await ask(narrowed, "兩點")
        XCTAssertEqual(answer.addedEvents.map(\.title), ["開會"])
        XCTAssertEqual(answer.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))
        XCTAssertEqual(answer.addedEvents.first?.notes, CalendarEventMapper.provenancePrefix + "明天開會 → 兩點")

        let lunch = makeAssistant()
        _ = try await ask(lunch, "Dentist tomorrow")
        let atLunch = try await ask(lunch, "lunch")
        XCTAssertEqual(atLunch.text, "What time should I schedule “Dentist” tomorrow at lunch?")
        XCTAssertEqual(atLunch.suggestions, ["12:00", "12:30", "13:00"])

        let online = makeAssistant()
        _ = try await ask(online, "明天下午開線上會議")
        let tapped = try await ask(online, "14:00")
        XCTAssertEqual(tapped.addedEvents.first?.notes, CalendarEventMapper.provenancePrefix + "明天下午開線上會議 → 14:00")
    }

    /// 下午茶 and 線上午餐會 are events, not the afternoon or the morning.
    func testPartOfTheDayWordsInsideAnEventName() async throws {
        let tea = makeAssistant()
        let question = try await ask(tea, "明天下午茶")
        XCTAssertEqual(question.text, "明天的「下午茶」要排在幾點？")
        XCTAssertEqual(question.suggestions, ["13:00", "14:00", "15:00"])
        let answer = try await ask(tea, "兩點")
        XCTAssertEqual(answer.addedEvents.map(\.title), ["下午茶"])
        XCTAssertEqual(answer.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))

        let lunch = makeAssistant()
        let online = try await ask(lunch, "明天線上午餐會")
        XCTAssertEqual(online.text, "明天的「線上午餐會」要排在幾點？")
        XCTAssertEqual(online.suggestions, ["12:00", "12:30", "13:00"])
        let one = try await ask(lunch, "一點")
        XCTAssertEqual(one.addedEvents.map(\.title), ["線上午餐會"])
        XCTAssertEqual(one.addedEvents.first?.start, TestClock.local(2026, 10, 14, 13, 0))
    }

    /// The English question reads naturally with or without a day.
    func testEnglishTimeQuestions() async throws {
        let phrases = [
            ("Gym in the morning", "What time should I schedule “Gym” in the morning?"),
            ("Call mom this evening", "What time should I schedule “Call mom” tonight?"),
            ("Dentist this afternoon", "What time should I schedule “Dentist” this afternoon?"),
            ("Study at night", "What time should I schedule “Study” in the evening?"),
            ("Gym tomorrow evening", "What time should I schedule “Gym” tomorrow evening?")
        ]
        for (request, question) in phrases {
            let reply = try await ask(makeAssistant(), request)
            XCTAssertEqual(reply.text, question, request)
            XCTAssertTrue(reply.needsClarification, request)
        }
        // Another day: "on Fri, Oct 16 in the morning" (the date as the device's region writes it).
        let friday = try await ask(makeAssistant(), "Gym Friday morning")
        XCTAssertTrue(friday.text.hasPrefix("What time should I schedule “Gym” on "), friday.text)
        XCTAssertTrue(friday.text.hasSuffix(" in the morning?"), friday.text)
        XCTAssertEqual(friday.suggestions, ["08:00", "09:00", "10:00"])
    }

    /// The zh-Hant translations of the example prompts (Localizable.xcstrings) must do what the English ones do.
    func testChineseExamplePromptsWork() async throws {
        let assistant = makeAssistant()

        let lunch = try await ask(assistant, "明天下午 1 點 Andrew 午餐")
        XCTAssertEqual(lunch.addedEvents.map(\.title), ["Andrew 午餐"])
        XCTAssertEqual(lunch.addedEvents.first?.start, TestClock.local(2026, 10, 14, 13, 0))

        let pushed = try await ask(assistant, "下一個行程延後 30 分鐘")
        XCTAssertTrue(pushed.changed)
        XCTAssertTrue(pushed.text.hasPrefix("Updated: Andrew 午餐 · "), pushed.text)
        XCTAssertTrue(pushed.text.hasSuffix("13:30–14:30"), pushed.text)

        let today = try await ask(assistant, "顯示今天的行程")
        XCTAssertEqual(today.agenda?.range.start, TestClock.local(2026, 10, 13))

        let plan = try await ask(assistant, "我想在 6 個月內增肌，幫我排每天的訓練")
        XCTAssertEqual(plan.planDraft?.title, "增肌計畫")
        XCTAssertEqual(plan.planDraft?.endDate, TestClock.local(2027, 4, 13))
    }

    // MARK: Agenda

    func testAgendaIsADigestOfTheDay() async throws {
        let assistant = makeAssistant()
        _ = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        _ = try await ask(assistant, "Dentist tomorrow 9am")

        let reply = try await ask(assistant, "show me my schedule for tomorrow")
        let agenda = try XCTUnwrap(reply.agenda)
        XCTAssertEqual(agenda.range, DateInterval(start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15)))
        XCTAssertEqual(reply.showRange, agenda.range)
        XCTAssertEqual(agenda.events.map(\.title), ["Dentist", "Lunch with Andrew"])
        XCTAssertTrue(agenda.title.hasPrefix("Tomorrow · "), agenda.title)
        XCTAssertTrue(reply.addedEvents.isEmpty)
        XCTAssertFalse(reply.changed)
        XCTAssertEqual(reply.text.components(separatedBy: "\n"),
                       [agenda.title, "• 09:00  Dentist", "• 13:00  Lunch with Andrew"])
    }

    func testEmptyAgendaSaysNothingScheduled() async throws {
        let reply = try await ask(makeAssistant(), "what's on today")
        let agenda = try XCTUnwrap(reply.agenda)
        XCTAssertTrue(agenda.events.isEmpty)
        XCTAssertTrue(agenda.title.hasPrefix("Today · "), agenda.title)
        XCTAssertEqual(reply.text, agenda.title + "\n" + ReplyFormatter.nothingScheduled)
    }

    func testWeekAgendaGroupsRowsByDay() async throws {
        let assistant = makeAssistant()
        _ = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        _ = try await ask(assistant, "Gym Friday 6pm")

        let reply = try await ask(assistant, "show me this week")
        let agenda = try XCTUnwrap(reply.agenda)
        // Sunday-first weeks, like the artboards.
        XCTAssertEqual(agenda.range, DateInterval(start: TestClock.local(2026, 10, 11), end: TestClock.local(2026, 10, 18)))
        XCTAssertTrue(agenda.title.hasPrefix("This week · "), agenda.title)
        XCTAssertEqual(agenda.events.map(\.title), ["Lunch with Andrew", "Gym"])

        let lines = reply.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5, reply.text) // title, day, row, day, row
        XCTAssertEqual(lines[2], "• 13:00  Lunch with Andrew")
        XCTAssertEqual(lines[4], "• 18:00  Gym")
    }
}
