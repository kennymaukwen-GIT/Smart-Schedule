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
        storeFiles.append(url)
        // No notification center in a hostless test bundle.
        return DemoAssistant(store: SharedStore(fileURL: url), clock: TestClock.clock, rescheduleReminders: { _ in })
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
        XCTAssertEqual(chinese.suggestions, ["09:00", "14:00", "19:00"])

        let answer = try await ask(assistant, "14:00")
        XCTAssertEqual(answer.addedEvents.map(\.title), ["午餐"])
        XCTAssertEqual(answer.addedEvents.first?.start, TestClock.local(2026, 10, 14, 14, 0))
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
