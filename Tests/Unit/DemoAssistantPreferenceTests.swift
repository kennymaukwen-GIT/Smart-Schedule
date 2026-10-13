import XCTest

/// "Say it to change it" offline: lasting instructions become preference changes (never events), with a receipt for
/// the "Settings updated" card, and "Ask me first" keeps captured events waiting for Add.
final class DemoAssistantPreferenceTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func make() -> (assistant: DemoAssistant, preferences: PreferencesStore, store: SharedStore) {
        let preferences = PreferencesStore(fileURL: files.url("DemoAssistantPreferenceTests-prefs"))
        let store = SharedStore(fileURL: files.url("DemoAssistantPreferenceTests-cache"))
        // No notification center in a hostless test bundle.
        let assistant = DemoAssistant(store: store, clock: TestClock.clock, preferences: preferences,
                                      rescheduleReminders: { _ in })
        return (assistant, preferences, store)
    }

    private func ask(_ assistant: DemoAssistant, _ text: String) async throws -> Reply {
        try await assistant.handle(text, focusEventID: nil, now: now)
    }

    /// The change is a receipt, never an event.
    private func assertPreferenceReply(_ reply: Reply, key: PreferenceKey, store: SharedStore,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(reply.preferenceReceipt?.changes.map(\.key), [key], reply.text, file: file, line: line)
        XCTAssertTrue(reply.rejectedPreferences.isEmpty, file: file, line: line)
        XCTAssertTrue(reply.addedEvents.isEmpty, file: file, line: line)
        XCTAssertNil(reply.pendingEvents, file: file, line: line)
        XCTAssertFalse(reply.text.contains(DemoAssistant.demoNote), file: file, line: line)
        let events = await store.snapshot().events
        XCTAssertTrue(events.isEmpty, "no event was created", file: file, line: line)
    }

    // MARK: Quiet hours

    func testNoRemindersBeforeEightInChinese() async throws {
        for utterance in ["8 點前不要提醒我", "早上 8 點以前別提醒我"] {
            let (assistant, preferences, store) = make()
            let reply = try await ask(assistant, utterance)
            await assertPreferenceReply(reply, key: .quietHours, store: store)
            XCTAssertEqual(preferences.current().quietHours,
                           QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60), utterance)
            XCTAssertTrue(reply.text.hasPrefix("好的，以後 08:00 前的提醒會靜音送達。"), reply.text)
            // The text version of the card follows (Siri, notifications).
            XCTAssertTrue(reply.text.contains(ReplyFormatter.preferencesUpdated(try XCTUnwrap(reply.preferenceReceipt))))
        }
    }

    func testNoRemindersBeforeEightInEnglish() async throws {
        let (assistant, preferences, store) = make()
        let reply = try await ask(assistant, "don't remind me before 8am")
        await assertPreferenceReply(reply, key: .quietHours, store: store)
        XCTAssertEqual(preferences.current().quietHours, QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60))
        XCTAssertTrue(reply.text.hasPrefix("OK. From now on, reminders before 08:00 arrive silently."), reply.text)
    }

    func testQuietHoursKeepTheirCurrentStart() async throws {
        let (assistant, preferences, _) = make()
        await preferences.update { $0.quietHours = QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 6 * 60) }
        _ = try await ask(assistant, "8 點前不要提醒我")
        XCTAssertEqual(preferences.current().quietHours, QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 8 * 60))
    }

    func testNoRemindersAfterTenMeansTheEvening() async throws {
        let (assistant, preferences, store) = make()
        let reply = try await ask(assistant, "10 點後別提醒我")
        await assertPreferenceReply(reply, key: .quietHours, store: store)
        XCTAssertEqual(preferences.current().quietHours, QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60))
    }

    func testAnInvalidChangeIsRefusedWithAReason() async throws {
        let (assistant, preferences, _) = make()
        // Quiet hours 08:00–07:00 already: "until 08:00" would start and end at 08:00.
        await preferences.update { $0.quietHours = QuietHours(isEnabled: true, startMinute: 8 * 60, endMinute: 7 * 60) }
        let reply = try await ask(assistant, "8 點前不要提醒我")
        XCTAssertNil(reply.preferenceReceipt)
        XCTAssertEqual(reply.rejectedPreferences.map(\.key), ["quiet_hours"])
        XCTAssertTrue(reply.text.contains("I couldn't change"), reply.text)
        XCTAssertEqual(preferences.current().quietHours.endMinute, 7 * 60)
    }

    // MARK: Reminder rules

    func testGymReminderTwoHoursBefore() async throws {
        let cases = [("健身提前 2 小時提醒", "好的，以後健身和例行活動會提前 2 小時提醒。"),
                     ("以後健身都提前兩小時提醒我", "好的，以後健身和例行活動會提前 2 小時提醒。"),
                     ("remind me 2 hours before gym", "OK. From now on, workouts and other routines get a reminder 2 hours before.")]
        for (utterance, sentence) in cases {
            let (assistant, preferences, store) = make()
            let reply = try await ask(assistant, utterance)
            await assertPreferenceReply(reply, key: .routineReminders, store: store)
            XCTAssertEqual(preferences.current().routineReminders, [120], utterance)
            XCTAssertTrue(reply.text.hasPrefix(sentence), reply.text)
        }
    }

    func testAReminderForOneDatedEventIsNotAPreference() async throws {
        let (assistant, preferences, _) = make()
        let reply = try await ask(assistant, "remind me 2 hours before gym tomorrow")
        XCTAssertNil(reply.preferenceReceipt)
        XCTAssertEqual(preferences.current(), AppPreferences())
    }

    func testStopOneDefaultReminder() async throws {
        let (assistant, preferences, store) = make()
        let reply = try await ask(assistant, "別再提前一天提醒截止日")
        await assertPreferenceReply(reply, key: .deadlineReminders, store: store)
        XCTAssertEqual(preferences.current().deadlineReminders, [60])
    }

    // MARK: Calendar, length, language, autonomy

    func testSchoolAccountForNewEvents() async throws {
        let label = "My calendar | student@university.example.edu"
        for utterance in ["以後用學校帳號", "from now on use my school account"] {
            let (assistant, preferences, store) = make()
            let reply = try await ask(assistant, utterance)
            await assertPreferenceReply(reply, key: .defaultCalendar, store: store)
            XCTAssertEqual(preferences.current().defaultCalendar, DemoData.schoolCalendar, utterance)
            XCTAssertEqual(preferences.current().defaultCalendarLabel, label, utterance)

            // New events now land in the school calendar.
            let added = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
            XCTAssertEqual(added.addedEvents.first?.calendarRef, DemoData.schoolCalendar)
        }
    }

    func testNewEventsGoToThePersonalCalendarByDefault() async throws {
        let (assistant, _, _) = make()
        let reply = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        XCTAssertEqual(reply.addedEvents.first?.calendarRef, DemoData.defaultCalendar)
    }

    func testDefaultDuration() async throws {
        for utterance in ["以後會議預設 30 分鐘", "make meetings 30 minutes by default"] {
            let (assistant, preferences, store) = make()
            let reply = try await ask(assistant, utterance)
            await assertPreferenceReply(reply, key: .defaultDuration, store: store)
            XCTAssertEqual(preferences.current().defaultEventMinutes, 30, utterance)

            let added = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
            let event = try XCTUnwrap(added.addedEvents.first)
            XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 13, 30))
        }
    }

    func testReplyLanguage() async throws {
        let (assistant, preferences, store) = make()
        let english = try await ask(assistant, "以後用英文回覆")
        await assertPreferenceReply(english, key: .replyLanguage, store: store)
        XCTAssertEqual(preferences.current().replyLanguage, .english)
        XCTAssertTrue(english.text.hasPrefix("好的，以後用英文回覆。"), english.text)

        let chinese = try await ask(assistant, "always reply in Chinese")
        XCTAssertEqual(chinese.preferenceReceipt?.changes.map(\.key), [.replyLanguage])
        XCTAssertEqual(preferences.current().replyLanguage, .traditionalChinese)
    }

    func testAskFirst() async throws {
        for utterance in ["以後先問我再加", "ask me before adding events"] {
            let (assistant, preferences, store) = make()
            let reply = try await ask(assistant, utterance)
            await assertPreferenceReply(reply, key: .autonomy, store: store)
            XCTAssertEqual(preferences.current().autonomy, .askFirst, utterance)
        }
    }

    func testVoiceChangesAreRememberedAndCanBeUndone() async throws {
        let (assistant, preferences, _) = make()
        let reply = try await ask(assistant, "8 點前不要提醒我")
        let receipt = try XCTUnwrap(reply.preferenceReceipt)
        XCTAssertEqual(receipt.source, .voice(utterance: "8 點前不要提醒我"))
        let ledger = await preferences.ledger()
        XCTAssertEqual(ledger.map(\.key), [.quietHours])

        let undone = await preferences.undo(receipt)
        XCTAssertTrue(undone)
        XCTAssertEqual(preferences.current().quietHours, QuietHours())
    }

    func testOrdinaryInputIsNotAPreference() async throws {
        let (assistant, preferences, _) = make()
        for utterance in ["Lunch with Andrew tomorrow 1pm", "下一個行程延後 30 分鐘", "show me my schedule for tomorrow",
                          "明天下午 1 點 Andrew 午餐"] {
            let reply = try await ask(assistant, utterance)
            XCTAssertNil(reply.preferenceReceipt, utterance)
        }
        XCTAssertEqual(preferences.current(), AppPreferences())
    }

    // MARK: "Ask me first"

    func testAskFirstKeepsEventsWaitingUntilAdd() async throws {
        let (assistant, preferences, store) = make()
        await preferences.update { $0.autonomy = .askFirst }

        let reply = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        let batch = try XCTUnwrap(reply.pendingEvents)
        XCTAssertTrue(reply.addedEvents.isEmpty)
        XCTAssertFalse(reply.changed)
        let snapshotEvents = await store.snapshot().events
        XCTAssertTrue(snapshotEvents.isEmpty, "nothing is written before Add")
        let stored = await store.pendingEventBatch()
        XCTAssertEqual(stored, batch)
        XCTAssertTrue(batch.id.hasPrefix(PendingEventBatch.idPrefix))
        XCTAssertNil(batch.target, "demo batches have no Google target")
        let preview = try XCTUnwrap(batch.previewEvents.first)
        XCTAssertTrue(preview.isDraft)
        XCTAssertTrue(preview.id.hasPrefix("draft-ev-"))
        XCTAssertEqual(preview.start, TestClock.local(2026, 10, 14, 13, 0))
        XCTAssertTrue(reply.text.hasPrefix("Ready to add: Lunch with Andrew"), reply.text)
        XCTAssertTrue(reply.text.contains(ReplyFormatter.pendingEventsPrompt), reply.text)

        let added = try await assistant.commitPendingEvents(batch)
        XCTAssertEqual(added.committedEventBatchID, batch.id)
        XCTAssertEqual(added.addedEvents.map(\.title), ["Lunch with Andrew"])
        let event = try XCTUnwrap(added.addedEvents.first)
        XCTAssertTrue(DemoData.isDemoID(event.id))
        XCTAssertFalse(event.isDraft)
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 14, 13, 0))
        XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 14, 0))
        let cleared = await store.pendingEventBatch()
        XCTAssertNil(cleared)

        // A second Add (double tap, or the notification extension) writes nothing new.
        let again = try await assistant.commitPendingEvents(batch)
        XCTAssertEqual(again.addedEvents.map(\.id), [event.id])
        let events = await store.snapshot().events
        XCTAssertEqual(events.map(\.id), [event.id])
    }

    func testPendingEventsCanBeDiscardedOrApprovedInChat() async throws {
        let (assistant, preferences, store) = make()
        await preferences.update { $0.autonomy = .askFirst }

        let lunch = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        let first = try XCTUnwrap(lunch.pendingEvents)
        let dropped = await assistant.discardPendingEvents(first)
        XCTAssertEqual(dropped.discardedEventBatchID, first.id)
        let afterDiscard = await store.pendingEventBatch()
        XCTAssertNil(afterDiscard)

        let dentist = try await ask(assistant, "Dentist tomorrow 9am")
        let second = try XCTUnwrap(dentist.pendingEvents)
        XCTAssertNotEqual(second.id, first.id)
        let approved = try await ask(assistant, "好")
        XCTAssertEqual(approved.committedEventBatchID, second.id)
        XCTAssertEqual(approved.addedEvents.map(\.title), ["Dentist"])
        let events = await store.snapshot().events
        XCTAssertEqual(events.map(\.title), ["Dentist"])
    }
}
