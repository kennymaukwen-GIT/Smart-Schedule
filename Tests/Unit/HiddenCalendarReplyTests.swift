import XCTest

/// New events written to a calendar this iPhone hides: they still go there (Google has them either way) and the
/// reply says so, so the confirmation can offer Show.
final class HiddenCalendarReplyTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func makeAssistant(hidingPersonalCalendar hidden: Bool) async -> DemoAssistant {
        let accounts = AccountStore(fileURL: files.url("HiddenCalendarReplyTests-accounts"), isDemoMode: { true },
                                    defaultCalendar: { nil })
        if hidden { await accounts.setVisible(false, calendar: DemoData.personalCalendar) }
        let store = SharedStore(fileURL: files.url("HiddenCalendarReplyTests-cache"), accounts: accounts)
        // Default settings in a file of its own; no notification center in a hostless test bundle.
        return DemoAssistant(store: store, clock: TestClock.clock,
                             preferences: PreferencesStore(fileURL: files.url("HiddenCalendarReplyTests-prefs")),
                             rescheduleReminders: { _ in })
    }

    func testAnEventSavedToAHiddenCalendarSaysSoAndIsNotRedirected() async throws {
        let assistant = await makeAssistant(hidingPersonalCalendar: true)
        let reply = try await assistant.handle("Lunch with Andrew tomorrow 1pm", focusEventID: nil, now: now)

        XCTAssertEqual(reply.addedEvents.count, 1)
        XCTAssertEqual(reply.addedEvents.first?.calendarRef, DemoData.personalCalendar)
        XCTAssertEqual(reply.savedToHiddenCalendar, DemoData.personalCalendar)
        XCTAssertEqual(reply.savedToHiddenCalendarName, "My calendar")
    }

    func testAVisibleCalendarSaysNothing() async throws {
        let assistant = await makeAssistant(hidingPersonalCalendar: false)
        let reply = try await assistant.handle("Lunch with Andrew tomorrow 1pm", focusEventID: nil, now: now)

        XCTAssertEqual(reply.addedEvents.count, 1)
        XCTAssertNil(reply.savedToHiddenCalendar)
        XCTAssertNil(reply.savedToHiddenCalendarName)
    }

    func testTheSentenceForTextOnlySurfaces() {
        XCTAssertEqual(ScheduleAssistant.hiddenCalendarNote("Gym"), "Saved to «Gym» (hidden in Smart Schedules)")
    }
}
