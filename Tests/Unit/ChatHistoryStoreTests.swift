import XCTest

/// The app conversation across launches: cards survive, retention and the 200-message cap prune it.
final class ChatHistoryStoreTests: XCTestCase {
    private let now = TestClock.utc(2026, 10, 13, 9, 0)
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func record(_ text: String, daysAgo: Double = 0, role: ChatRecord.Role = .user) -> ChatRecord {
        ChatRecord(date: now.addingTimeInterval(-daysAgo * 86_400), role: role, text: text)
    }

    func testCardsSurviveARoundTrip() async throws {
        let store = ChatHistoryStore(fileURL: files.url("ChatHistoryStoreTests"))
        let lunch = TestEvents.make(id: "ss1", title: "Lunch", start: TestClock.local(2026, 10, 14, 13),
                                    end: TestClock.local(2026, 10, 14, 14))
        let batch = PendingEventBatch(id: "batch-abcdefgh", createdAt: now, utterance: "lunch", seed: "s",
                                      argsJSON: Data("{}".utf8), previewEvents: [lunch])
        let receipt = PreferenceChangeReceipt(
            id: UUID(), date: now, source: .voice(utterance: "8 點前不要提醒我"),
            changes: [PreferenceChange(key: .quietHours, oldValue: "off 22:00-07:00", newValue: "on 22:00-08:00",
                                       oldDisplay: "Off", newDisplay: "22:00–08:00", replacedEntry: nil)])
        let records = [
            record("Lunch tomorrow 1pm"),
            ChatRecord(date: now, role: .assistant, text: "Added", suggestions: ["14:00"], addedEvents: [lunch],
                       preferenceReceipt: receipt, preferenceUndone: false,
                       pendingEvents: batch, pendingEventsStatus: "pending")
        ]
        await store.save(records, retention: .month, now: now)
        let loaded = await store.load(retention: .month, now: now)
        XCTAssertEqual(loaded, records)
    }

    func testAddingIsSavedAsPending() async {
        let store = ChatHistoryStore(fileURL: files.url("ChatHistoryStoreTests"))
        var reply = record("Plan", role: .assistant)
        reply.planStatus = "adding"
        await store.save([reply], retention: .forever, now: now)
        let loaded = await store.load(retention: .forever, now: now)
        XCTAssertEqual(loaded.first?.planStatus, "pending")
    }

    func testRetentionDropsOldMessages() async {
        let url = files.url("ChatHistoryStoreTests")
        let store = ChatHistoryStore(fileURL: url)
        let records = [record("40 days", daysAgo: 40), record("10 days", daysAgo: 10), record("today")]
        await store.save(records, retention: .forever, now: now)

        let month = await store.load(retention: .month, now: now)
        XCTAssertEqual(month.map(\.text), ["10 days", "today"])
        // Pruned on disk too: a longer retention does not bring it back.
        let forever = await store.load(retention: .forever, now: now)
        XCTAssertEqual(forever.map(\.text), ["10 days", "today"])

        let week = await store.load(retention: .week, now: now)
        XCTAssertEqual(week.map(\.text), ["today"])
    }

    func testKeepsTheNewestTwoHundred() async {
        let store = ChatHistoryStore(fileURL: files.url("ChatHistoryStoreTests"))
        let records = (0..<250).map { index in
            ChatRecord(date: now.addingTimeInterval(Double(index)), role: .user, text: "m\(index)")
        }
        await store.save(records, retention: .forever, now: now)
        let loaded = await store.load(retention: .forever, now: now)
        XCTAssertEqual(loaded.count, ChatHistoryStore.maxRecords)
        XCTAssertEqual(loaded.first?.text, "m50")
        XCTAssertEqual(loaded.last?.text, "m249")
    }

    func testClearAndErase() async {
        let url = files.url("ChatHistoryStoreTests")
        let store = ChatHistoryStore(fileURL: url)
        await store.save([record("hello")], retention: .month, now: now)
        await store.clear()
        let cleared = await store.load(retention: .month, now: now)
        XCTAssertTrue(cleared.isEmpty)

        await store.save([record("hello")], retention: .month, now: now)
        await store.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let erased = await store.load(retention: .month, now: now)
        XCTAssertTrue(erased.isEmpty)
    }

    func testTolerantDecoding() async throws {
        let url = files.url("ChatHistoryStoreTests")
        // A newer version, an unreadable card on one record, a record that is not an object, unknown fields.
        let json = """
        {"version": 2, "future": 1, "records": [
          {"id": "8B6A8A43-3E8E-4E77-9A43-3C1E5F1F0001", "date": \(now.timeIntervalSince1970), "role": "user",
           "text": "hi", "planDraft": {"broken": true}, "mood": "happy"},
          42,
          {"date": \(now.timeIntervalSince1970), "role": "narrator", "text": "who?"}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let loaded = await ChatHistoryStore(fileURL: url).load(retention: .forever, now: now)
        XCTAssertEqual(loaded.map(\.text), ["hi", "who?"])
        XCTAssertNil(loaded.first?.planDraft)
        XCTAssertEqual(loaded.last?.role, .assistant)
    }

    func testMissingOrUnreadableFileReadsEmpty() async throws {
        let url = files.url("ChatHistoryStoreTests")
        let missing = await ChatHistoryStore(fileURL: url).load(retention: .month, now: now)
        XCTAssertTrue(missing.isEmpty)
        try Data("not json".utf8).write(to: url)
        let unreadable = await ChatHistoryStore(fileURL: url).load(retention: .month, now: now)
        XCTAssertTrue(unreadable.isEmpty)
        // An unreadable file is left alone, not wiped on load.
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }
}

/// "Export my data": everything kept on the device, never a sign-in token.
final class DataExportTests: XCTestCase {
    private let now = TestClock.utc(2026, 10, 13, 9, 0)

    private func sampleExport() -> DataExport {
        var account = SampleAccounts.account("sub-123", email: "kenny@example.com",
                                             extra: [SampleAccounts.calendar("sub-123", "gym-id", email: "kenny@example.com",
                                                                             name: "Gym", visible: false)])
        account.calendars[0].colorOverrideHex = "#7986CB"
        let event = TestEvents.make(id: "ss1", title: "Lunch", start: TestClock.local(2026, 10, 14, 13),
                                    end: TestClock.local(2026, 10, 14, 14))
        return DataExport(exportedAt: now,
                          app: DataExport.AppInfo(version: "0.1.0", build: "1"),
                          preferences: AppPreferences(),
                          assistantMemory: [],
                          learnedSuggestions: [],
                          accounts: [account],
                          aiConsent: AIConsent(status: .granted, version: 1, decidedAt: now),
                          cachedEvents: [event],
                          pendingPlan: nil,
                          pendingEvents: nil,
                          chatHistory: [ChatRecord(date: now, role: .user, text: "Lunch tomorrow 1pm")])
    }

    func testShapeAndExplicitNulls() throws {
        let object = try TestJSON.object(sampleExport().encoded())
        XCTAssertEqual(object["format"] as? String, "smart-schedule-export")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["exportedAt"] as? String, "2026-10-13T09:00:00Z")
        XCTAssertEqual((object["app"] as? [String: Any])?["version"] as? String, "0.1.0")
        XCTAssertTrue(object["pendingPlan"] is NSNull)
        XCTAssertTrue(object["pendingEvents"] is NSNull)
        for key in ["preferences", "assistantMemory", "learnedSuggestions", "accounts", "aiConsent", "cachedEvents", "chatHistory"] {
            XCTAssertNotNil(object[key], key)
        }
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.first?["email"] as? String, "kenny@example.com")
        let calendars = try XCTUnwrap(accounts.first?["calendars"] as? [[String: Any]])
        XCTAssertEqual(calendars.map { $0["name"] as? String }, ["kenny@example.com", "Gym"])
        XCTAssertEqual(calendars.first?["colorOverride"] as? String, "#7986CB")
        XCTAssertTrue(calendars.last?["colorOverride"] is NSNull)
        XCTAssertEqual(calendars.last?["visible"] as? Bool, false)
    }

    func testNoTokensOrAccountIdentifiers() throws {
        let text = String(decoding: try sampleExport().encoded(), as: UTF8.self).lowercased()
        for secret in ["token", "refresh", "sub-123", "grantedscopes", "auth/calendar"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testFileNameUsesTheLocalDay() {
        // 23:30 UTC on Oct 13 is already Oct 14 in Taipei.
        let late = TestClock.utc(2026, 10, 13, 23, 30)
        XCTAssertEqual(DataExport.fileName(for: late, timeZone: TimeZone(identifier: "UTC")!), "SmartSchedule-Export-2026-10-13.json")
        XCTAssertEqual(DataExport.fileName(for: late, timeZone: TimeZone(identifier: "Asia/Taipei")!),
                       "SmartSchedule-Export-2026-10-14.json")
    }
}
