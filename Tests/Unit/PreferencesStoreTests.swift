import XCTest

final class PreferencesStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var store: PreferencesStore!

    private let schoolRef = CalendarRef(accountID: "demo-school", calendarID: "example@yourmail.com")
    private let schoolLabel = "My calendar | example@yourmail.com"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreferencesStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("preferences.json")
        store = PreferencesStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func request(_ key: PreferenceKey, _ value: String) -> PreferenceChangeRequest {
        PreferenceChangeRequest(key: key, value: value)
    }

    @discardableResult
    private func applyByVoice(_ requests: [PreferenceChangeRequest], said utterance: String = "from now on") async -> PreferenceApplyResult {
        let ref = schoolRef
        return await store.apply(requests, source: .voice(utterance: utterance)) { text in
            text.localizedCaseInsensitiveContains("yourmail") ? CalendarChoice(ref: ref, label: text) : nil
        }
    }

    /// Five dismissals in a row of one reminder; returns what the fifth created.
    private func dismissFiveTimes(_ kind: ScheduleEvent.Kind, _ offset: Int, allDay: Bool = false) async -> LearnedSuggestion? {
        var created: LearnedSuggestion?
        for _ in 0..<LearnedSuggestion.dismissThreshold {
            created = await store.recordReminderOutcome(kind: kind, offsetMinutes: offset, isAllDay: allDay, dismissed: true)
        }
        return created
    }

    // MARK: Reading

    func testMissingFileReadsAsDefaults() async {
        XCTAssertEqual(store.current(), AppPreferences())
        let ledger = await store.ledger()
        let suggestions = await store.allSuggestions()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testUnreadableFileReadsAsDefaults() throws {
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(PreferencesStore(fileURL: fileURL).current(), AppPreferences())
    }

    func testTolerantFileDecoding() async throws {
        let json = #"""
        {"version": 9,
         "preferences": {"defaultEventMinutes": 30, "teleport": true},
         "ledger": [
           {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "key": "default_duration", "value": "30", "display": "30 min",
            "previousDisplay": "60 min", "source": {"type": "settings"}, "date": 1000},
           {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "key": "teleport_mode", "value": "on", "display": "On",
            "previousDisplay": "Off", "source": {"type": "voice", "utterance": "beam me up"}, "date": 2000}],
         "suggestions": [{"kind": "meeting"},
                         {"kind": "task", "offsetMinutes": 60, "status": "pending", "createdAt": 3000}],
         "dismissStreaks": {"task.60": 2}}
        """#
        try Data(json.utf8).write(to: fileURL)
        let reopened = PreferencesStore(fileURL: fileURL)
        XCTAssertEqual(reopened.current().defaultEventMinutes, 30)
        let ledger = await reopened.ledger()
        XCTAssertEqual(ledger.map(\.key), [.defaultDuration])
        XCTAssertEqual(ledger.first?.source, .settings)
        let pending = await reopened.pendingSuggestions()
        XCTAssertEqual(pending.map(\.streakKey), ["task.60"])
    }

    // MARK: update

    func testUpdateWritesCachesAndReturnsTheReceipt() async throws {
        let receipt = await store.update { $0.dailyReminderCap = 10; $0.speechOnDevice = false }
        let change = try XCTUnwrap(receipt?.changes.first)
        XCTAssertEqual(receipt?.changes.count, 1)
        XCTAssertEqual(receipt?.source, .settings)
        XCTAssertEqual(change.key, .dailyReminderCap)
        XCTAssertEqual(change.oldValue, "off")
        XCTAssertEqual(change.newValue, "10")
        XCTAssertEqual(change.oldDisplay, "Off")
        XCTAssertEqual(change.newDisplay, "10 a day")
        XCTAssertNil(change.replacedEntry)
        XCTAssertEqual(store.current().dailyReminderCap, 10)
        XCTAssertFalse(store.current().speechOnDevice)
        // Another process (a fresh instance) reads the file.
        let other = PreferencesStore(fileURL: fileURL)
        XCTAssertEqual(other.current().dailyReminderCap, 10)
        XCTAssertFalse(other.current().speechOnDevice)
    }

    func testUpdateWithoutAnyKeyChangeReturnsNilButSaves() async {
        let none = await store.update { _ in }
        XCTAssertNil(none)
        let speech = await store.update { $0.speechLanguage = .englishUK }
        XCTAssertNil(speech, "speech language is not a ledger key")
        XCTAssertEqual(PreferencesStore(fileURL: fileURL).current().speechLanguage, .englishUK)
        let ledger = await store.ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testLedgerKeepsOneLinePerKeyAndDropsItAtTheDefault() async {
        await store.update { $0.defaultEventMinutes = 30 }
        await store.update { $0.defaultEventMinutes = 45 }
        var ledger = await store.ledger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.first?.key, .defaultDuration)
        XCTAssertEqual(ledger.first?.value, "45")
        XCTAssertEqual(ledger.first?.display, "45 min")
        XCTAssertEqual(ledger.first?.previousDisplay, "30 min")
        XCTAssertEqual(ledger.first?.source, .settings)

        await store.update { $0.defaultEventMinutes = 60 }
        ledger = await store.ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testLedgerIsNewestFirst() async {
        await store.update { $0.weekStart = .monday }
        await store.update { $0.dailyReminderCap = 5 }
        let ledger = await store.ledger()
        XCTAssertEqual(ledger.map(\.key), [.dailyReminderCap, .weekStart])
    }

    func testReceiptRemembersTheLedgerLineItReplaced() async throws {
        await store.update { $0.defaultEventMinutes = 30 }
        let first = await store.ledger().first
        let receipt = await store.update(source: .voice(utterance: "make meetings 45 minutes by default")) {
            $0.defaultEventMinutes = 45
        }
        XCTAssertEqual(receipt?.changes.first?.replacedEntry, first)
        XCTAssertEqual(receipt?.source, .voice(utterance: "make meetings 45 minutes by default"))
    }

    // MARK: apply (update_preferences)

    func testApplyNormalisesAppliesAndRejects() async throws {
        let result = await applyByVoice([
            request(.quietHours, "22:00-08:00"),
            request(.routineReminders, "120"),
            request(.dailyReminderCap, "500"),
            request(.weekStart, "sunday") // already the value: dropped silently
        ], said: "8 點前不要提醒我")
        XCTAssertEqual(result.rejected, [PreferenceRejection(key: "daily_reminder_cap", value: "500",
                                                             reason: "daily_reminder_cap must be a number from 1 to 50 or off")])
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.changes.map(\.key), [.routineReminders, .quietHours])
        XCTAssertEqual(receipt.changes.map(\.newValue), ["120", "on 22:00-08:00"])
        XCTAssertEqual(receipt.changes.map(\.oldDisplay), ["30 min", "Off"])
        XCTAssertEqual(receipt.changes.map(\.newDisplay), ["2 h", "22:00–08:00"])
        XCTAssertEqual(receipt.changes.map(\.oldPromptValue), ["30", "off"])
        XCTAssertEqual(receipt.changes.map(\.newPromptValue), ["120", "22:00-08:00"])
        XCTAssertEqual(receipt.source, .voice(utterance: "8 點前不要提醒我"))
        XCTAssertEqual(store.current().quietHours, QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60))
        XCTAssertEqual(store.current().routineReminders, [120])
        XCTAssertTrue(receipt.affectsNotifications)
        let ledger = await store.ledger()
        XCTAssertEqual(Set(ledger.map(\.key)), [.routineReminders, .quietHours])
        XCTAssertTrue(ledger.allSatisfy { $0.source == .voice(utterance: "8 點前不要提醒我") })
    }

    func testApplyWithNothingNewReturnsNoReceipt() async {
        let result = await applyByVoice([request(.weekStart, "Sunday"), request(.autonomy, "add_directly")])
        XCTAssertNil(result.receipt)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testOnAndOffKeepTheStoredTimes() async {
        await applyByVoice([request(.quietHours, "23:00-06:00")])
        await applyByVoice([request(.quietHours, "off")])
        XCTAssertEqual(store.current().quietHours, QuietHours(isEnabled: false, startMinute: 23 * 60, endMinute: 6 * 60))
        await applyByVoice([request(.quietHours, "on")])
        XCTAssertEqual(store.current().quietHours, QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 6 * 60))
        await applyByVoice([request(.morningBriefing, "off")])
        XCTAssertEqual(store.current().morningBriefing, DailyTime(isEnabled: false, minuteOfDay: 7 * 60 + 30))
    }

    func testApplyResolvesTheDefaultCalendar() async throws {
        let result = await applyByVoice([request(.defaultCalendar, schoolLabel)], said: "以後用學校帳號")
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertEqual(result.receipt?.changes.first?.newDisplay, "My calendar · example@yourmail.com")
        XCTAssertEqual(store.current().defaultCalendar, schoolRef)
        XCTAssertEqual(store.current().defaultCalendarLabel, schoolLabel)
        XCTAssertEqual(store.current().promptValue(for: .defaultCalendar), schoolLabel)

        let miss = await applyByVoice([request(.defaultCalendar, "Work | boss@example.com")])
        XCTAssertNil(miss.receipt)
        XCTAssertEqual(miss.rejected.first?.key, "default_calendar")
        XCTAssertEqual(store.current().defaultCalendar, schoolRef)

        let automatic = await store.apply([request(.defaultCalendar, "automatic")], source: .voice(utterance: "x")) { _ in
            XCTFail("automatic needs no resolver")
            return nil
        }
        XCTAssertNotNil(automatic.receipt)
        XCTAssertNil(store.current().defaultCalendar)
        XCTAssertNil(store.current().defaultCalendarLabel)
        let ledger = await store.ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testVoiceSourceIsTrimmedForStorage() async throws {
        let long = String(repeating: "以後", count: 60)
        let result = await applyByVoice([request(.weekStart, "monday")], said: long)
        guard case .voice(let stored)? = result.receipt?.source else { return XCTFail("voice source expected") }
        XCTAssertEqual(stored.count, LedgerSource.maxUtteranceLength)
    }

    // MARK: undo

    func testUndoRestoresTheValueAndTheReplacedLine() async throws {
        await store.update { $0.defaultEventMinutes = 30 }
        let result = await applyByVoice([request(.defaultDuration, "45")])
        let receipt = try XCTUnwrap(result.receipt)
        var ledger = await store.ledger()
        XCTAssertEqual(ledger.first?.source, .voice(utterance: "from now on"))

        let undone = await store.undo(receipt)
        XCTAssertTrue(undone)
        XCTAssertEqual(store.current().defaultEventMinutes, 30)
        ledger = await store.ledger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.first?.source, .settings)
        XCTAssertEqual(ledger.first?.value, "30")
    }

    func testUndoBackToTheDefaultLeavesNoLine() async throws {
        let result = await applyByVoice([request(.autonomy, "ask_first")])
        let receipt = try XCTUnwrap(result.receipt)
        let undone = await store.undo(receipt)
        XCTAssertTrue(undone)
        XCTAssertEqual(store.current().autonomy, .addDirectly)
        let ledger = await store.ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testUndoIsRefusedAfterALaterChange() async throws {
        let result = await applyByVoice([request(.defaultDuration, "30")])
        let receipt = try XCTUnwrap(result.receipt)
        await store.update { $0.defaultEventMinutes = 90 }
        let undone = await store.undo(receipt)
        XCTAssertFalse(undone)
        XCTAssertEqual(store.current().defaultEventMinutes, 90)
    }

    func testUndoRestoresOnlyKeysNotChangedSince() async throws {
        let result = await applyByVoice([request(.defaultDuration, "30"), request(.weekStart, "monday")])
        let receipt = try XCTUnwrap(result.receipt)
        await store.update { $0.defaultEventMinutes = 90 }
        let undone = await store.undo(receipt)
        XCTAssertTrue(undone)
        XCTAssertEqual(store.current().defaultEventMinutes, 90)
        XCTAssertEqual(store.current().weekStart, .sunday)
    }

    // MARK: Deleting a ledger line

    func testDeletingALineResetsThatSettingToItsDefault() async throws {
        await applyByVoice([request(.quietHours, "22:00-08:00"), request(.taskReminders, "15")])
        let lines = await store.ledger()
        let line = try XCTUnwrap(lines.first { $0.key == .quietHours })
        await store.deleteLedgerEntry(id: line.id)
        XCTAssertEqual(store.current().quietHours, QuietHours())
        XCTAssertEqual(store.current().taskReminders, [15])
        let ledger = await store.ledger()
        XCTAssertEqual(ledger.map(\.key), [.taskReminders])
    }

    // MARK: Learned suggestions

    func testFiveDismissalsInARowCreateOneSuggestion() async throws {
        for _ in 1..<LearnedSuggestion.dismissThreshold {
            let created = await store.recordReminderOutcome(kind: .event, offsetMinutes: 1440, isAllDay: false, dismissed: true)
            XCTAssertNil(created)
        }
        let fifth = await store.recordReminderOutcome(kind: .event, offsetMinutes: 1440, isAllDay: false, dismissed: true)
        let suggestion = try XCTUnwrap(fifth)
        XCTAssertEqual(suggestion.streakKey, "event.1440")
        XCTAssertEqual(suggestion.status, .pending)
        XCTAssertEqual(suggestion.dismissCount, 5)
        XCTAssertFalse(suggestion.shownInChat)
        XCTAssertEqual(suggestion.question,
                       "You dismissed the “1 day before” reminder for events 5 times in a row. Stop sending it?")
        let pending = await store.pendingSuggestions()
        XCTAssertEqual(pending.map(\.id), [suggestion.id])
        XCTAssertEqual(store.current(), AppPreferences(), "nothing changes without a tap")
    }

    func testEngagingResetsTheStreak() async {
        for _ in 0..<4 {
            await store.recordReminderOutcome(kind: .deadline, offsetMinutes: 60, isAllDay: false, dismissed: true)
        }
        await store.recordReminderOutcome(kind: .deadline, offsetMinutes: 60, isAllDay: false, dismissed: false)
        for _ in 0..<4 {
            let created = await store.recordReminderOutcome(kind: .deadline, offsetMinutes: 60, isAllDay: false, dismissed: true)
            XCTAssertNil(created)
        }
        let fifth = await store.recordReminderOutcome(kind: .deadline, offsetMinutes: 60, isAllDay: false, dismissed: true)
        XCTAssertEqual(fifth?.streakKey, "deadline.60")
    }

    func testStreaksAreCountedPerKindAndOffset() async {
        for _ in 0..<3 {
            await store.recordReminderOutcome(kind: .event, offsetMinutes: 60, isAllDay: false, dismissed: true)
            await store.recordReminderOutcome(kind: .event, offsetMinutes: 30, isAllDay: false, dismissed: true)
        }
        let suggestions = await store.allSuggestions()
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testASuggestionIsNeverOfferedTwice() async throws {
        let created = await dismissFiveTimes(.task, 60)
        let first = try XCTUnwrap(created)
        await store.resolveSuggestion(id: first.id, accept: false)
        let again = await dismissFiveTimes(.task, 60)
        XCTAssertNil(again)
        let all = await store.allSuggestions()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .declined)
        XCTAssertEqual(store.current().taskReminders, [60], "Keep changes nothing")
    }

    func testNoSuggestionForAnOffsetThatIsNotADefault() async {
        let created = await dismissFiveTimes(.event, 15)
        XCTAssertNil(created)
    }

    func testAcceptingRemovesTheOffsetWithALearnedLine() async throws {
        let created = await dismissFiveTimes(.event, 1440)
        let suggestion = try XCTUnwrap(created)
        let accepted = await store.resolveSuggestion(id: suggestion.id, accept: true)
        let receipt = try XCTUnwrap(accepted)
        XCTAssertEqual(store.current().eventReminders, [60, 30, 0])
        XCTAssertEqual(receipt.source, .learned)
        XCTAssertEqual(receipt.changes.map(\.key), [.eventReminders])
        let ledger = await store.ledger()
        XCTAssertEqual(ledger.first?.source, .learned)
        XCTAssertEqual(ledger.first?.source.label, "Learned from your habits")
        let pending = await store.pendingSuggestions()
        XCTAssertTrue(pending.isEmpty)
        let all = await store.allSuggestions()
        XCTAssertEqual(all.first?.status, .accepted)
        let twice = await store.resolveSuggestion(id: suggestion.id, accept: true)
        XCTAssertNil(twice)
    }

    func testAllDaySuggestionTurnsTheAllDayReminderOff() async throws {
        let created = await dismissFiveTimes(.event, 900, allDay: true)
        let suggestion = try XCTUnwrap(created)
        XCTAssertEqual(suggestion.streakKey, "event.allday")
        XCTAssertEqual(suggestion.question,
                       "You dismissed the “The day before at 09:00” reminder for all-day events 5 times in a row. Stop sending it?")
        await store.resolveSuggestion(id: suggestion.id, accept: true)
        XCTAssertNil(store.current().allDayReminderMinutes)
    }

    func testChatShowsEachSuggestionOnce() async throws {
        let created = await dismissFiveTimes(.routine, 30)
        let suggestion = try XCTUnwrap(created)
        var toShow = await store.suggestionsToShowInChat()
        XCTAssertEqual(toShow.map(\.id), [suggestion.id])
        await store.markShownInChat([suggestion.id])
        toShow = await store.suggestionsToShowInChat()
        XCTAssertTrue(toShow.isEmpty)
        let pending = await store.pendingSuggestions()
        XCTAssertEqual(pending.map(\.id), [suggestion.id], "still listed in Settings until answered")
    }

    // MARK: Erase

    func testEraseAllDeletesEverything() async throws {
        await store.update { $0.weekStart = .monday }
        _ = await dismissFiveTimes(.event, 60)
        await store.eraseAll()
        XCTAssertEqual(store.current(), AppPreferences())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let ledger = await store.ledger()
        let suggestions = await store.allSuggestions()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: Cross-process notification

    func testWritesInvalidateOtherInstancesThroughDarwinNotifications() async throws {
        let other = PreferencesStore(fileURL: fileURL)
        XCTAssertEqual(other.current().weekStart, .sunday) // now cached
        let posted = expectation(description: ".preferences delivered")
        posted.assertForOverFulfill = false
        let observation = SharedChangeNotifier.observe(.preferences) { posted.fulfill() }
        await store.update { $0.weekStart = .monday }
        await fulfillment(of: [posted], timeout: 5)
        await MainActor.run {} // the same main-queue delivery invalidated `other`
        XCTAssertEqual(other.current().weekStart, .monday)
        withExtendedLifetime(observation) {}
    }
}
