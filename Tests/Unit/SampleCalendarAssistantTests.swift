import XCTest

/// `ScheduleAssistant` on demo mode's router (accounts pinned to the samples, `CalendarRouter+Sample.swift`): Gemini
/// is told the calendars are fictional (`AssistantPrompt.demoModeBlock`) and sees only sample events; every write
/// stays in the cache with `demo-` ids and never reaches Google or the outbox; the replies say "on this device"
/// where they would name Google Calendar, and say what the sample calendars cannot do (Meet links, some repeats).
/// With a real calendar the prompt and the texts are as before.
final class SampleCalendarAssistantTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 22:50 BST, the fixture's now_local.
    private let now = TestClock.local(2026, 10, 13, 22, 50)
    private let realEmail = "kenny@example.com"
    private let realEventID = "therapy1"
    private let realTitle = "Therapy with Dr Lee"

    override func setUp() {
        super.setUp()
        SampleAssistantGeminiStub.recorder.reset()
    }

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let assistant: ScheduleAssistant
        let store: SharedStore
        let outbox: SyncOutbox
        let google: SampleAssistantGoogle
    }

    /// `sample`: demo mode's assistant. Its router's accounts are pinned to the samples (as
    /// `AccountStore.sampleCalendarsOnly()` is) and the cache holds the sample week. Otherwise the real account's
    /// calendar gets new events. Either way the accounts file holds a real account, and the cache a copy of one of
    /// its events (hidden in demo mode). Reminders are not rescheduled: a hostless test bundle has no notification
    /// center.
    private func makeRig(sample: Bool = true, askFirst: Bool = false) async -> Rig {
        let file = files.url("SampleCalendarAssistant-accounts")
        let live = AccountStore(fileURL: file, isDemoMode: { sample }, defaultCalendar: { nil })
        await live.upsert(SampleAccounts.account("111", email: realEmail))
        let accounts = sample ? AccountStore(fileURL: file, isDemoMode: { true }, defaultCalendar: { nil }) : live
        let store = SharedStore(fileURL: files.url("SampleCalendarAssistant-cache"), accounts: live)
        if sample {
            await store.replaceWindow(DemoData.seedWindow(now: now, clock: TestClock.clock),
                                      with: DemoData.events(now: now, clock: TestClock.clock))
        }
        await store.upsert([TestEvents.make(id: realEventID, title: realTitle, start: TestClock.local(2026, 10, 14, 9),
                                            end: TestClock.local(2026, 10, 14, 10),
                                            calendar: CalendarRef(accountID: "111", calendarID: realEmail))])

        let outbox = SyncOutbox(fileURL: files.url("SampleCalendarAssistant-outbox"))
        let google = SampleAssistantGoogle()
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: google, outbox: outbox)
        let preferences = PreferencesStore(fileURL: files.url("SampleCalendarAssistant-prefs"))
        if askFirst { await preferences.update { $0.autonomy = .askFirst } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SampleAssistantGeminiStub.self]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { true })
        let assistant = ScheduleAssistant(gemini: gemini, router: router, store: store, preferences: preferences,
                                          clock: TestClock.clock, rescheduleReminders: { _ in })
        return Rig(assistant: assistant, store: store, outbox: outbox, google: google)
    }

    /// What Gemini answers to "1個小時後買蛋給 Jocelyn" at 22:50: the call in `create_events.relative_time.json`.
    private func relativeTimeAnswer() throws -> String {
        let call = try Fixtures.call("create_events.relative_time.json")
        return SampleAssistantGeminiStub.call(call.name, String(decoding: call.args, as: UTF8.self))
    }

    private var requestBodies: [String] {
        SampleAssistantGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Nothing left this iPhone and nothing waits to be sent.
    private func assertNothingReachedGoogle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await rig.google.calls
        XCTAssertEqual(calls, 0, "no token or Calendar request", file: file, line: line)
        let waiting = await rig.outbox.items()
        XCTAssertTrue(waiting.isEmpty, "nothing in the outbox", file: file, line: line)
    }

    // MARK: Adding

    func testATimeCountedFromNowIsAddedOnThisIPhoneOnly() async throws {
        let rig = await makeRig()
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        let reply = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)

        XCTAssertTrue(reply.changed)
        XCTAssertEqual(reply.addedEvents.count, 1)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-"), event.id)
        XCTAssertEqual(event.calendarRef, DemoData.personalCalendar)
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 0, 20))
        XCTAssertEqual(event.reminderMinutes, [10, 0], "created at 22:50 for later the same day")
        XCTAssertFalse(event.isWaitingToSync)
        XCTAssertFalse(reply.waitingToSync)
        XCTAssertTrue(reply.text.hasPrefix("Added: 買蛋給 Jocelyn"), reply.text)
        XCTAssertFalse(reply.text.contains("Google Calendar"), reply.text)

        let cached = await rig.store.snapshot().events.filter { $0.title == "買蛋給 Jocelyn" }
        XCTAssertEqual(cached.map(\.id), [event.id])
        await assertNothingReachedGoogle(rig)
    }

    func testTheRequestSaysDemoModeAndHoldsOnlySampleEvents() async throws {
        let rig = await makeRig()
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        _ = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)

        let bodies = requestBodies
        XCTAssertEqual(bodies.count, 1)
        let body = try XCTUnwrap(bodies.first)
        XCTAssertTrue(body.contains("# DEMO MODE"), body)
        XCTAssertTrue(body.contains("fictional sample data kept on this iPhone"), body)
        // UPCOMING: the sample week.
        XCTAssertTrue(body.contains("demo-meeting-joe | Online meeting with Joe"), body)
        XCTAssertTrue(body.contains("demo-dentist | Dentist"), body)
        // The real account's event and address stay out, though both are on this iPhone.
        XCTAssertFalse(body.contains(realTitle), body)
        XCTAssertFalse(body.contains(realEventID), body)
        XCTAssertFalse(body.contains(realEmail), body)

        XCTAssertTrue(AssistantPrompt.demoModeBlock.hasPrefix("# DEMO MODE\n"))
        XCTAssertTrue(AssistantPrompt.demoModeBlock.hasSuffix(
            "Never say anything was added to, changed in or deleted from Google Calendar."))
    }

    func testAskMeFirstAddsTheBatchOnThisIPhone() async throws {
        let rig = await makeRig(askFirst: true)
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        let proposed = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)
        let batch = try XCTUnwrap(proposed.pendingEvents)
        XCTAssertEqual(batch.target, DemoData.personalCalendar)
        XCTAssertTrue(proposed.addedEvents.isEmpty)
        XCTAssertEqual(batch.previewEvents.first?.reminderMinutes, [10, 0])

        // Add a minute later, the same evening: created for later that day.
        let reply = try await rig.assistant.commitPendingEvents(batch, now: now.addingTimeInterval(60))
        XCTAssertEqual(reply.committedEventBatchID, batch.id)
        XCTAssertEqual(reply.addedEvents.count, 1)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-"), event.id)
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.reminderMinutes, [10, 0])
        XCTAssertTrue(reply.text.hasPrefix("Added: 買蛋給 Jocelyn"), reply.text)
        XCTAssertNotEqual(reply.text, ReplyFormatter.pendingEventsAdded(1))
        XCTAssertFalse(reply.text.contains("Google Calendar"), reply.text)
        await assertNothingReachedGoogle(rig)
    }

    func testAPlanIsAddedOnThisIPhone() async throws {
        let rig = await makeRig()
        let name = "create_long_term_plan.muscle.json"
        let call = try Fixtures.call(name)
        let args = try TestJSON.decode(LongTermPlanArgs.self, data: call.args)
        let builder = PlanDraftBuilder(mapper: CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy()))
        let draft = try builder.draft(from: args, argsJSON: call.args, id: "plan-muscle-6m", revision: 1,
                                      utterance: Fixtures.utterance(name))

        let reply = try await rig.assistant.commitPlan(draft)
        XCTAssertEqual(reply.committedPlanID, draft.id)
        XCTAssertEqual(reply.text, "Added “\(draft.title)” on this device.")
        XCTAssertNotEqual(reply.text, ReplyFormatter.planAdded(draft.title))
        let planned = await rig.store.snapshot().events.filter { $0.planID == draft.id }
        XCTAssertFalse(planned.isEmpty)
        XCTAssertTrue(planned.allSatisfy { $0.id.hasPrefix("demo-") && $0.calendarRef == DemoData.personalCalendar })
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Editing and deleting

    func testAnEditAndADeleteChangeOnlyThisIPhone() async throws {
        let rig = await makeRig()
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        let added = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)
        let id = try XCTUnwrap(added.addedEvents.first?.id)

        SampleAssistantGeminiStub.recorder.answer([SampleAssistantGeminiStub.call(
            "modify_event", #"{"event_id": "\#(id)", "changes": {"title": "買蛋和牛奶給 Jocelyn", "location": "Tesco"}}"#)])
        let edited = try await rig.assistant.handle("改成買蛋和牛奶，在 Tesco", now: now)
        XCTAssertTrue(edited.changed)
        XCTAssertTrue(edited.text.hasPrefix("Updated: 買蛋和牛奶給 Jocelyn"), edited.text)
        var cached = await rig.store.snapshot().events.filter { $0.id == id }
        XCTAssertEqual(cached.map(\.title), ["買蛋和牛奶給 Jocelyn"])
        XCTAssertEqual(cached.first?.location, "Tesco")
        XCTAssertEqual(cached.first?.start, TestClock.local(2026, 10, 13, 23, 50), "unchanged")
        XCTAssertEqual(cached.first?.reminderMinutes, [10, 0], "unchanged")

        SampleAssistantGeminiStub.recorder.answer([SampleAssistantGeminiStub.call(
            "delete_events", #"{"event_ids": ["\#(id)"]}"#)])
        let deleted = try await rig.assistant.handle("取消它", now: now)
        XCTAssertTrue(deleted.changed)
        XCTAssertNil(deleted.pendingDeletion, "one event: deleted without a tap")
        XCTAssertTrue(deleted.text.hasPrefix("Deleted 1 item"), deleted.text)
        XCTAssertTrue(deleted.text.contains("on this device."), deleted.text)
        XCTAssertFalse(deleted.text.contains("Google Calendar"), deleted.text)
        cached = await rig.store.snapshot().events.filter { $0.id == id }
        XCTAssertTrue(cached.isEmpty)
        await assertNothingReachedGoogle(rig)
    }

    func testABulkDeleteIsConfirmedOnThisIPhone() async throws {
        let rig = await makeRig()
        SampleAssistantGeminiStub.recorder.answer([SampleAssistantGeminiStub.call(
            "delete_events", #"{"event_ids": ["demo-dentist", "demo-concert"]}"#)])
        let asked = try await rig.assistant.handle("cancel the dentist and the concert", now: now)
        let pending = try XCTUnwrap(asked.pendingDeletion)
        XCTAssertEqual(Set(pending.eventIDs), ["demo-dentist", "demo-concert"])
        XCTAssertTrue(pending.refs.allSatisfy { $0.accountID == DemoData.personalAccountID })

        let done = try await rig.assistant.confirm(pending)
        XCTAssertTrue(done.changed)
        XCTAssertTrue(done.text.hasPrefix("Deleted 2 items"), done.text)
        XCTAssertTrue(done.text.contains("on this device."), done.text)
        XCTAssertFalse(done.text.contains("Google Calendar"), done.text)
        let left = await rig.store.snapshot().events.map(\.id)
        XCTAssertFalse(left.contains("demo-dentist"))
        XCTAssertFalse(left.contains("demo-concert"))
        XCTAssertTrue(left.contains(realEventID), "the hidden real event stays")
        await assertNothingReachedGoogle(rig)
    }

    // MARK: What the sample calendars cannot do

    func testAMeetLinkOrAnUnsupportedRepeatIsMentioned() async throws {
        let rig = await makeRig()
        SampleAssistantGeminiStub.recorder.answer([
            SampleAssistantGeminiStub.call("create_events", #"""
                {"events": [{"title": "Call with Joe", "start": "2026-10-14T15:00", "duration_minutes": 30,
                             "kind": "event", "add_video_conference": true}]}
                """#),
            SampleAssistantGeminiStub.call("create_events", #"""
                {"events": [{"title": "Book club", "start": "2026-10-20T19:00", "duration_minutes": 60, "kind": "event",
                             "recurrence": {"frequency": "MONTHLY"}}]}
                """#),
            SampleAssistantGeminiStub.call("create_events", #"""
                {"events": [{"title": "Piano lesson", "start": "2026-10-14T18:00", "duration_minutes": 45, "kind": "event",
                             "recurrence": {"frequency": "WEEKLY", "by_weekday": ["WE"]}}]}
                """#)
        ])

        let online = try await rig.assistant.handle("明天下午三點和 Joe 線上會議", now: now)
        XCTAssertEqual(online.addedEvents.count, 1)
        XCTAssertTrue(online.text.contains(ScheduleAssistant.sampleMeetNote), online.text)
        XCTAssertFalse(online.text.contains(ScheduleAssistant.sampleRepeatNote), online.text)

        let monthly = try await rig.assistant.handle("每個月 20 號晚上七點讀書會", now: now)
        XCTAssertEqual(monthly.addedEvents.count, 1, "added once")
        XCTAssertNil(monthly.addedEvents.first?.seriesID)
        XCTAssertTrue(monthly.text.contains(ScheduleAssistant.sampleRepeatNote), monthly.text)
        XCTAssertFalse(monthly.text.contains(ScheduleAssistant.sampleMeetNote), monthly.text)

        // A weekly series expands, so there is nothing to say.
        let weekly = try await rig.assistant.handle("每週三晚上六點鋼琴課", now: now)
        XCTAssertEqual(weekly.addedEvents.count, 26)
        XCTAssertFalse(weekly.text.contains(ScheduleAssistant.sampleRepeatNote), weekly.text)
        XCTAssertFalse(weekly.text.contains(ScheduleAssistant.sampleMeetNote), weekly.text)

        XCTAssertEqual(ScheduleAssistant.sampleMeetNote, "Demo mode doesn't create Google Meet links.")
        XCTAssertEqual(ScheduleAssistant.sampleRepeatNote,
                       "Demo mode repeats only daily and weekly events, so this one was added once.")
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Suggested notes

    func testSuggestedNotesAreKeptOnTheSampleEvents() async throws {
        let rig = await makeRig()
        SampleAssistantGeminiStub.recorder.answer([SampleAssistantGeminiStub.call("create_events", #"""
            {"events": [
              {"title": "Trip to Tokyo", "start": "2026-10-20", "end": "2026-10-24", "all_day": true, "kind": "event",
               "suggested_notes": ["Passport", "Yen cash"]},
              {"title": "Run", "start": "2026-10-14T07:00", "duration_minutes": 30, "kind": "routine",
               "recurrence": {"frequency": "WEEKLY", "by_weekday": ["WE"]}, "suggested_notes": ["Water"]}
            ]}
            """#)])
        let reply = try await rig.assistant.handle("下週二到週六去東京，每週三早上七點跑步", now: now)

        let trip = try XCTUnwrap(reply.addedEvents.first { $0.title == "Trip to Tokyo" })
        XCTAssertTrue(trip.id.hasPrefix("demo-"), trip.id)
        XCTAssertEqual(trip.suggestedNotes, ["Passport", "Yen cash"])
        let runs = reply.addedEvents.filter { $0.title == "Run" }
        XCTAssertEqual(runs.count, 26)
        XCTAssertTrue(runs.allSatisfy { $0.id.hasPrefix("demo-") && $0.suggestedNotes == ["Water"] })

        // Kept on the cached copies, so the event page shows them.
        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.first(where: { $0.id == trip.id })?.suggestedNotes, ["Passport", "Yen cash"])
        let cachedRuns = cached.filter { $0.title == "Run" }
        XCTAssertEqual(cachedRuns.count, 26)
        XCTAssertTrue(cachedRuns.allSatisfy { $0.suggestedNotes == ["Water"] })
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Real calendars (unchanged)

    func testARealCalendarKeepsThePromptAndTheTexts() async throws {
        let rig = await makeRig(sample: false)
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        let added = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)
        let event = try XCTUnwrap(added.addedEvents.first)
        XCTAssertFalse(event.id.hasPrefix("demo-"), event.id)
        XCTAssertEqual(event.accountID, "111")
        XCTAssertTrue(added.text.hasPrefix("Added: 買蛋給 Jocelyn"), added.text)
        let sent = await rig.google.calls
        XCTAssertGreaterThan(sent, 0, "sent to Google")

        SampleAssistantGeminiStub.recorder.answer([SampleAssistantGeminiStub.call(
            "delete_events", #"{"event_ids": ["\#(event.id)"]}"#)])
        let deleted = try await rig.assistant.handle("取消它", now: now)
        XCTAssertTrue(deleted.text.hasPrefix("Deleted 1 item"), deleted.text)
        XCTAssertTrue(deleted.text.contains("from Google Calendar."), deleted.text)

        let bodies = requestBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(bodies.contains { $0.contains("DEMO MODE") })
        XCTAssertTrue(bodies[0].contains(realTitle), "a real event is in UPCOMING")
    }

    func testARealCalendarStillSaysGoogleCalendarAfterAdd() async throws {
        let rig = await makeRig(sample: false, askFirst: true)
        try SampleAssistantGeminiStub.recorder.answer([relativeTimeAnswer()])
        let proposed = try await rig.assistant.handle("1個小時後買蛋給 Jocelyn", now: now)
        let batch = try XCTUnwrap(proposed.pendingEvents)

        let reply = try await rig.assistant.commitPendingEvents(batch)
        XCTAssertEqual(reply.addedEvents.count, 1)
        XCTAssertEqual(reply.addedEvents.first?.accountID, "111")
        XCTAssertEqual(reply.text, ReplyFormatter.pendingEventsAdded(1))
    }
}

/// Answers each Gemini request with the next queued response (a plain reply once none is left) and keeps every
/// request body.
private final class SampleAssistantGeminiStub: URLProtocol {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Data] = []
        private var queued: [String] = []

        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return recorded }

        /// The answers to the next requests, in order.
        func answer(_ responses: [String]) {
            lock.lock()
            queued += responses
            lock.unlock()
        }

        func reset() {
            lock.lock()
            recorded = []
            queued = []
            lock.unlock()
        }

        /// Records `body` and returns the answer for this request.
        func next(_ body: Data?) -> String {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(body ?? Data())
            if queued.isEmpty { return SampleAssistantGeminiStub.call("reply_to_user", #"{"message": "OK"}"#) }
            return queued.removeFirst()
        }
    }

    static let recorder = Recorder()

    /// A Gemini response with one function call; `args` is its JSON object.
    static func call(_ name: String, _ args: String) -> String {
        #"{"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "\#(name)", "args": \#(args)}}]}, "finishReason": "STOP"}]}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.recorder.next(Self.bodyData(of: request))
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://gemini.example.invalid")!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Counts every token request and Calendar API request. Google saves an insert as it was sent (the request body
/// comes back) and answers anything else with an empty list.
private actor SampleAssistantGoogle: CalendarTransport {
    private(set) var calls = 0

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        calls += 1
        return "test-token"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let url = request.url ?? URL(string: "https://www.googleapis.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (request.httpBody ?? Data(#"{"items":[]}"#.utf8), response)
    }
}
