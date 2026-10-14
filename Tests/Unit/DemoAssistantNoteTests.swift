import XCTest

/// "加個備註：帶護照" / "add a note: bring passport" in demo mode: the note goes below the notes of the event the
/// reminder is about, the one named, or the one just added; a sentence that describes a new event stays a new event.
final class DemoAssistantNoteTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func makeAssistant() -> (DemoAssistant, SharedStore) {
        let store = SharedStore(fileURL: files.url("DemoAssistantNoteTests-cache"))
        // Default settings in a file of its own; no notification center in a hostless test bundle.
        let assistant = DemoAssistant(store: store, clock: TestClock.clock,
                                      preferences: PreferencesStore(fileURL: files.url("DemoAssistantNoteTests-prefs")),
                                      rescheduleReminders: { _ in })
        return (assistant, store)
    }

    private func dentist(notes: String? = nil) -> ScheduleEvent {
        var event = TestEvents.make(id: "demo-dentist", title: "Dentist", start: TestClock.local(2026, 10, 16, 9, 30),
                                    end: TestClock.local(2026, 10, 16, 10, 30), calendar: DemoData.personalCalendar)
        event.notes = notes
        return event
    }

    func testANoteGoesToTheEventJustAdded() async throws {
        let (assistant, store) = makeAssistant()
        let added = try await assistant.handle("Lunch with Andrew tomorrow 1pm", now: now)
        let lunch = try XCTUnwrap(added.addedEvents.first)

        let reply = try await assistant.handle("加個備註：帶護照", now: now)
        XCTAssertTrue(reply.changed)
        XCTAssertEqual(reply.text, "已在「Lunch with Andrew」加上備註：帶護照\n" + DemoAssistant.demoNote)
        let noted = await store.event(id: lunch.id)
        let notes = try XCTUnwrap(noted?.notes)
        XCTAssertTrue(notes.hasPrefix(CalendarEventMapper.provenancePrefix), notes)
        XCTAssertTrue(notes.hasSuffix("\n\n帶護照"), notes)
        XCTAssertEqual(EventNotes.withoutProvenance(notes), "帶護照")

        // A second note goes on the next line.
        _ = try await assistant.handle("add a note: gate B", now: now)
        let again = await store.event(id: lunch.id)
        let more = try XCTUnwrap(again?.notes)
        XCTAssertEqual(EventNotes.withoutProvenance(more), "帶護照\ngate B")
    }

    func testANoteGoesToTheEventNamedOrTheReminders() async throws {
        let (assistant, store) = makeAssistant()
        await store.upsert([dentist(notes: "Smile Dental, 2nd floor")])

        let named = try await assistant.handle("Add a note to the dentist: bring the forms.", now: now)
        XCTAssertEqual(named.text, "Added a note to “Dentist”: bring the forms\n" + DemoAssistant.demoNote)
        let notes = await store.event(id: "demo-dentist")?.notes
        XCTAssertEqual(notes, "Smile Dental, 2nd floor\nbring the forms")

        // Replying to the dentist's reminder: "it" is the dentist.
        let focused = try await assistant.handle("備註：帶健保卡", focusEventID: "demo-dentist", now: now)
        XCTAssertTrue(focused.changed)
        let more = await store.event(id: "demo-dentist")?.notes
        XCTAssertEqual(more, "Smile Dental, 2nd floor\nbring the forms\n帶健保卡")
    }

    func testWithoutAnEventItAsksWhichOne() async throws {
        let (assistant, _) = makeAssistant()
        let reply = try await assistant.handle("add a note: bring passport", now: now)
        XCTAssertFalse(reply.changed)
        XCTAssertTrue(reply.needsClarification)
        XCTAssertEqual(reply.text, "Which event is the note for? Try “add a note to the dentist: bring the forms”.")
    }

    func testANewEventWithANoteIsStillANewEvent() async throws {
        let (assistant, _) = makeAssistant()
        let reply = try await assistant.handle("明天下午 3 點開會，備註：帶簡報", now: now)
        XCTAssertEqual(reply.addedEvents.count, 1)
        XCTAssertEqual(reply.addedEvents.first?.start, TestClock.local(2026, 10, 14, 15, 0))
    }

    func testRecognisingANoteRequest() {
        XCTAssertTrue(DemoAssistant.noteRequest("加個備註：帶護照")! == (note: "帶護照", target: ""))
        XCTAssertTrue(DemoAssistant.noteRequest("看牙醫加備註 帶健保卡")! == (note: "帶健保卡", target: "看牙醫"))
        XCTAssertTrue(DemoAssistant.noteRequest("備註：帶護照。")! == (note: "帶護照", target: ""))
        XCTAssertTrue(DemoAssistant.noteRequest("Add a note to the dentist: bring the forms.")!
                      == (note: "bring the forms", target: "the dentist"))
        XCTAssertTrue(DemoAssistant.noteRequest("add a note saying bring passport")! == (note: "bring passport", target: ""))
        XCTAssertTrue(DemoAssistant.noteRequest("note: gate B")! == (note: "gate B", target: ""))
        XCTAssertNil(DemoAssistant.noteRequest("Lunch with Andrew tomorrow 1pm"))
        XCTAssertNil(DemoAssistant.noteRequest("take notes at the review tomorrow 3pm"))
        XCTAssertNil(DemoAssistant.noteRequest("add a note:"))
    }
}
