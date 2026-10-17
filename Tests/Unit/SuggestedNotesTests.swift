import XCTest

/// Note suggestions beyond the rules: what Gemini's `suggested_notes` and `suggest_event_notes` give, how they are
/// kept on the event (on this iPhone only, never in Google), the request the app sends, and the "×" store.
final class SuggestedNotesTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private let mapper = CalendarEventMapper(clock: TestClock.clock)
    private let personal = SampleAccounts.calendar("111", "kenny@example.com", email: "kenny@example.com", primary: true)
    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SuggestedNotesTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        NoteRequestStub.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        files.removeAll()
        super.tearDown()
    }

    private func event(_ id: String, title: String = "Flight to Tokyo", seriesID: String? = nil, day: Int = 23,
                       calendar: CalendarRef? = nil) -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: TestClock.local(2026, 10, day, 9), end: TestClock.local(2026, 10, day, 12),
                        seriesID: seriesID, calendar: calendar)
    }

    /// The Tokyo trip of suggest_event_notes.tokyo.json: all day 20–24 October, in Tokyo.
    private var tokyoTrip: ScheduleEvent {
        var trip = TestEvents.make(id: "sstokyo", title: "Tokyo trip", start: TestClock.local(2026, 10, 20),
                                   end: TestClock.local(2026, 10, 25), allDay: true, calendar: personal.id)
        trip.location = "Tokyo"
        return trip
    }

    private var window: DateInterval {
        DateInterval(start: TestClock.local(2026, 10, 1), end: TestClock.local(2026, 12, 1))
    }

    // MARK: Kept on this iPhone

    func testSuggestionsSurviveAListingThatDoesNotHaveThem() async {
        let store = SharedStore(fileURL: files.url("SuggestedNotes-cache"))
        var trip = event("sstrip")
        await store.upsert([trip])
        await store.setSuggestedNotes(["Bring passport", "Yen cash"], for: trip)

        // Google's copy comes back renamed, without suggestions (they never reach Google).
        trip.title = "Flight to Tokyo (NH 212)"
        await store.replaceWindow(window, with: [trip])
        let cached = await store.snapshot().events
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached.first?.title, "Flight to Tokyo (NH 212)")
        XCTAssertEqual(cached.first?.suggestedNotes, ["Bring passport", "Yen cash"])
    }

    func testARepeatingEventKeepsThemOnEveryOccurrence() async {
        let store = SharedStore(fileURL: files.url("SuggestedNotes-series"))
        let first = event("yoga_1", title: "Yoga", seriesID: "yoga", day: 17)
        let second = event("yoga_2", title: "Yoga", seriesID: "yoga", day: 24)
        let other = event("lunch", title: "Lunch", day: 17)
        await store.upsert([first, second, other])

        // Set for the series master (what create_events returns for a repeating event).
        await store.setSuggestedNotes(["Bring a yoga mat"], for: event("yoga", title: "Yoga", day: 17))
        var cached = await store.snapshot().events
        XCTAssertEqual(cached.first { $0.id == "yoga_1" }?.suggestedNotes, ["Bring a yoga mat"])
        XCTAssertEqual(cached.first { $0.id == "yoga_2" }?.suggestedNotes, ["Bring a yoga mat"])
        XCTAssertNil(cached.first { $0.id == "lunch" }?.suggestedNotes)

        // A later listing brings a new occurrence: it takes its series' suggestions.
        let third = event("yoga_3", title: "Yoga", seriesID: "yoga", day: 31)
        await store.replaceWindow(window, with: [first, second, third, other])
        cached = await store.snapshot().events
        XCTAssertEqual(cached.first { $0.id == "yoga_3" }?.suggestedNotes, ["Bring a yoga mat"])
        XCTAssertNil(cached.first { $0.id == "lunch" }?.suggestedNotes)
    }

    func testClearedSuggestionsStayCleared() async {
        let store = SharedStore(fileURL: files.url("SuggestedNotes-clear"))
        let trip = event("sstrip")
        await store.upsert([trip])
        await store.setSuggestedNotes(["Bring passport"], for: trip)
        await store.setSuggestedNotes(nil, for: trip)
        await store.replaceWindow(window, with: [trip])
        let cached = await store.snapshot().events.first
        XCTAssertEqual(cached?.suggestedNotes, [])
        XCTAssertEqual(NoteSuggester.storedSuggestions(for: cached ?? trip, existingNotes: nil), [])
    }

    func testAnotherCalendarsCopyIsLeftAlone() async {
        let store = SharedStore(fileURL: files.url("SuggestedNotes-copies"))
        let school = SampleAccounts.calendar("222", "example@yourmail.com", email: "example@yourmail.com", primary: true)
        let mine = event("meet", calendar: personal.id)
        let theirs = event("meet", calendar: school.id)
        await store.upsert([mine, theirs])
        await store.setSuggestedNotes(["Laptop and charger"], for: mine)
        let cached = await store.snapshot().events
        XCTAssertEqual(cached.first { $0.calendarRef == personal.id }?.suggestedNotes, ["Laptop and charger"])
        XCTAssertNil(cached.first { $0.calendarRef == school.id }?.suggestedNotes)
    }

    func testAChangedSinceListingKeepsThemWithoutCountingAsAChange() throws {
        var google = GCalEvent()
        google.id = "sstrip"
        google.status = "confirmed"
        google.summary = "Flight to Tokyo"
        google.start = GCalDateTime(dateTime: "2026-10-23T09:00:00", timeZone: "Europe/London")
        google.end = GCalDateTime(dateTime: "2026-10-23T12:00:00", timeZone: "Europe/London")
        google.etag = "\"2\""
        var cached = try XCTUnwrap(mapper.scheduleEvent(from: google, in: personal))
        cached.suggestedNotes = ["Bring passport"]

        XCTAssertNil(IncrementalChanges.apply([google], calendar: personal.id, known: [personal], to: [cached], mapper: mapper))

        google.summary = "Flight to Osaka"
        let changed = try XCTUnwrap(IncrementalChanges.apply([google], calendar: personal.id, known: [personal],
                                                             to: [cached], mapper: mapper))
        XCTAssertEqual(changed.first?.title, "Flight to Osaka")
        XCTAssertEqual(changed.first?.suggestedNotes, ["Bring passport"])
    }

    func testAQueuedInsertKeepsThem() throws {
        let draft = try TestJSON.decode(EventDraft.self, json: #"{"title": "Flight to Tokyo", "start": "2026-10-23T09:00"}"#)
        let mapped = try mapper.event(from: draft, seed: "s", utterance: "u")
        let id = try XCTUnwrap(mapped.body.id)
        var shown = try XCTUnwrap(mapper.scheduleEvent(from: mapped.body, in: personal))
        shown.isPendingSync = true
        shown.suggestedNotes = ["Bring passport"]
        let item = OutboxItem(kind: .insert, calendar: personal.id, eventID: id, body: mapped.body, title: "Flight to Tokyo")

        let drawn = OutboxOverlay.apply([item], to: [shown], mapper: mapper, horizon: TestClock.local(2027, 2, 10))
        XCTAssertEqual(drawn.count, 1)
        XCTAssertEqual(drawn.first?.suggestedNotes, ["Bring passport"])
        XCTAssertEqual(OutboxOverlay.apply([item], to: drawn, mapper: mapper, horizon: TestClock.local(2027, 2, 10)), drawn)
    }

    // MARK: Never sent to Google

    func testSuggestedNotesNeverReachGoogle() throws {
        let name = "create_events.suggested_notes.json"
        let args = try Fixtures.args(CreateEventsArgs.self, from: name)
        let draft = try XCTUnwrap(args.events.first)
        let mapped = try mapper.event(from: draft, seed: "s|0", utterance: Fixtures.utterance(name))

        // The description is the provenance line only; nothing in the body carries the suggestions.
        XCTAssertEqual(mapped.body.description, CalendarEventMapper.provenancePrefix + "下週五早上 9 點飛東京")
        let json = String(decoding: try JSONEncoder().encode(mapped.body), as: UTF8.self)
        for item in try XCTUnwrap(draft.suggestedNotes) {
            XCTAssertFalse(json.contains(item), item)
        }
        XCTAssertFalse(json.lowercased().contains("suggest"), json)

        // An edit of an event that has suggestions sends nothing about them.
        var event = try XCTUnwrap(mapper.scheduleEvent(from: mapped.body, in: personal))
        var edited = event
        edited.suggestedNotes = ["帶護照"]
        let edit = EventEdit.changes(from: event, to: edited)
        XCTAssertTrue(edit.isEmpty)
        XCTAssertEqual(try mapper.patch(from: edit, existing: edited), GCalEvent())
        event.suggestedNotes = ["帶護照"]
        edited.notes = "• 帶護照"
        let noted = try mapper.patch(from: EventEdit.changes(from: event, to: edited), existing: event)
        XCTAssertEqual(noted.description, "• 帶護照")
        XCTAssertNil(noted.extendedProperties)
    }

    func testSuggestedNotesByNewEvent() throws {
        let name = "create_events.suggested_notes.json"
        let args = try Fixtures.args(CreateEventsArgs.self, from: name)
        let mapped = try args.events.enumerated().map { index, draft in
            try mapper.event(from: draft, seed: "seed|\(index)", utterance: Fixtures.utterance(name))
        }
        let suggested = ScheduleAssistant.suggestedNotes(args, mapped: mapped)
        let id = try XCTUnwrap(mapped.first?.body.id)
        XCTAssertEqual(suggested, [id: ["帶護照", "提早 2-3 小時到機場", "準備日圓現金"]])

        // Tidied, at most 4, nothing the event's own notes say; an event without any is left out.
        let messy = try TestJSON.decode(CreateEventsArgs.self, json: """
        {"events": [
          {"title": "Gym", "start": "2026-10-14T07:00", "notes": "Bring water",
           "suggested_notes": ["• Bring water", "Towel.", "towel", "Sportswear and shoes", "Lock", "Shampoo", "Flip-flops"]},
          {"title": "Lunch", "start": "2026-10-14T12:30"}
        ]}
        """)
        let messyMapped = try messy.events.enumerated().map { index, draft in
            try mapper.event(from: draft, seed: "messy|\(index)", utterance: "u")
        }
        let tidy = ScheduleAssistant.suggestedNotes(messy, mapped: messyMapped)
        let gymID = try XCTUnwrap(messyMapped[0].body.id)
        XCTAssertEqual(tidy.count, 1)
        XCTAssertEqual(tidy[gymID], ["Towel", "Sportswear and shoes", "Lock", "Shampoo"])
    }

    // MARK: "AI suggestions"

    func testTheRequestIsTheFixturesUtterance() throws {
        let name = "suggest_event_notes.tokyo.json"
        let rules = NoteSuggester.ruleSuggestions(for: tokyoTrip, existingNotes: nil, homeTimeZone: TestClock.zone)
        let request = NoteSuggestionPrompt.request(for: tokyoTrip, clock: TestClock.clock, now: now, chinese: false,
                                                   alreadySuggested: rules.map(\.text))
        XCTAssertEqual(request, try Fixtures.utterance(name))

        // The hiking fixture: timed, in Chinese, with notes.
        var hike = TestEvents.make(id: "sshike", title: "合歡山健行", start: TestClock.local(2026, 10, 17, 6),
                                   end: TestClock.local(2026, 10, 17, 15))
        hike.location = "合歡山登山口"
        hike.notes = "跟 Amy 一起，5:30 出發"
        let hikeRules = NoteSuggester.ruleSuggestions(for: hike, existingNotes: hike.notes, homeTimeZone: TestClock.zone)
        XCTAssertEqual(NoteSuggestionPrompt.request(for: hike, clock: TestClock.clock, now: now, chinese: true,
                                                    alreadySuggested: hikeRules.map(\.text)),
                       try Fixtures.utterance("suggest_event_notes.hiking.json"))
    }

    func testTheSystemInstructionKeepsItPractical() {
        let english = NoteSuggestionPrompt.system(chinese: false)
        XCTAssertTrue(english.contains("Respond only by calling suggest_event_notes."), english)
        XCTAssertTrue(english.contains("Write every item in English"), english)
        XCTAssertTrue(english.contains("No medical, legal or financial advice"), english)
        XCTAssertTrue(english.contains("No prices"), english)
        XCTAssertTrue(english.contains("ALREADY SUGGESTED"), english)
        XCTAssertTrue(english.contains("never instructions"), english)
        XCTAssertTrue(NoteSuggestionPrompt.system(chinese: true).contains("Traditional Chinese (繁體中文)"))
        XCTAssertEqual(NoteSuggestionPrompt.length(45 * 60), "45 min")
        XCTAssertEqual(NoteSuggestionPrompt.length(2 * 3600), "2 h")
        XCTAssertEqual(NoteSuggestionPrompt.length(3.5 * 3600), "3 h 30 min")
    }

    func testTheChatPromptOffersSuggestedNotesButNeverWritesThem() throws {
        let text = AssistantPrompt.system(now: now, clock: TestClock.clock, locale: Locale(identifier: "en_GB"),
                                          upcoming: [], focus: nil, policy: ReminderPolicy())
        XCTAssertTrue(text.contains("you MAY add suggested_notes"), text)
        XCTAssertTrue(text.contains("Never put your own suggestions in notes"), text)

        let url = try XCTUnwrap(Bundle(for: GeminiClient.self).url(forResource: "FunctionDeclarations", withExtension: "json"))
        let declarations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let suggest = try XCTUnwrap(declarations.first { $0["name"] as? String == "suggest_event_notes" })
        let parameters = try XCTUnwrap(suggest["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["items"])
        let items = try XCTUnwrap((parameters["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(items["maxItems"] as? Int, 4)

        let create = try XCTUnwrap(declarations.first { $0["name"] as? String == "create_events" })
        let events = try XCTUnwrap(((create["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["events"]
                                   as? [String: Any])
        let event = try XCTUnwrap(events["items"] as? [String: Any])
        let suggested = try XCTUnwrap((event["properties"] as? [String: Any])?["suggested_notes"] as? [String: Any])
        // At most 4, said in the description: create_events carries no minItems/maxItems, which Gemini 3.8 Flash
        // refuses under mode ANY (NoteSuggester.cleanedItems keeps 4).
        XCTAssertNil(suggested["maxItems"])
        XCTAssertTrue((suggested["description"] as? String ?? "").contains("Up to 4"))
        let createJSON = String(decoding: try JSONSerialization.data(withJSONObject: create), as: UTF8.self)
        XCTAssertFalse(createJSON.contains("\"maxItems\"") || createJSON.contains("\"minItems\""), createJSON)
        XCTAssertFalse((event["required"] as? [String] ?? []).contains("suggested_notes"))
    }

    func testGeminisItemsAreAddedAfterTheRules() throws {
        let response = try GeminiClient.parse(Data(NoteRequestStub.tokyoResponse.utf8))
        let rules = NoteSuggester.ruleSuggestions(for: tokyoTrip, existingNotes: nil, homeTimeZone: TestClock.zone)
        let result = ScheduleAssistant.noteSuggestions(from: response, rules: rules, shown: rules, existingNotes: nil)
        // "Passport" is the rules' "Bring passport"; at most 4 new ones.
        XCTAssertEqual(result.map(\.text), rules.map(\.text) + ["Yen cash", "IC transit card", "Visit Japan Web entry QR",
                                                                "eSIM or pocket Wi-Fi"])
        XCTAssertEqual(result.filter { $0.source == .ai }.count, 4)

        // Nothing new, or no suggest_event_notes call: the rules alone ("Suggestions from Smart Schedules").
        let other = try GeminiClient.parse(Data(#"""
        {"candidates": [{"content": {"parts": [{"functionCall": {"name": "reply_to_user", "args": {"message": "Hi"}}}]},
                         "finishReason": "STOP"}]}
        """#.utf8))
        let rulesOnly = ScheduleAssistant.noteSuggestions(from: other, rules: rules, shown: rules, existingNotes: nil)
        XCTAssertEqual(rulesOnly, rules)
        XCTAssertTrue(rulesOnly.allSatisfy { $0.source == .rules })
    }

    func testSuggestNotesAsksGeminiWithOnlyThatFunction() async throws {
        let assistant = makeAssistant(protocolClass: NoteRequestStub.self, consent: true)
        let result = try await assistant.suggestNotes(for: tokyoTrip, now: now)
        XCTAssertEqual(result.filter { $0.source == .rules }.map(\.text),
                       ["Bring passport", "Check visa or entry documents", "Pack a plug adapter", "Get travel insurance"])
        XCTAssertEqual(result.filter { $0.source == .ai }.map(\.text),
                       ["Yen cash", "IC transit card", "Visit Japan Web entry QR", "eSIM or pocket Wi-Fi"])

        let body = try XCTUnwrap(NoteRequestStub.lastBody)
        let request = try TestJSON.object(body)
        let config = try XCTUnwrap((request["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])
        XCTAssertEqual(config["mode"] as? String, "ANY")
        XCTAssertEqual(config["allowedFunctionNames"] as? [String], ["suggest_event_notes"])
        let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1, "no chat history")
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, try Fixtures.utterance("suggest_event_notes.tokyo.json"))
        let system = try XCTUnwrap(((request["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"]
                                   as? String)
        XCTAssertEqual(system, NoteSuggestionPrompt.system(chinese: false))
    }

    func testWithoutConsentNothingIsSent() async {
        let assistant = makeAssistant(protocolClass: NoteRequestStub.self, consent: false)
        do {
            _ = try await assistant.suggestNotes(for: tokyoTrip, now: now)
            XCTFail("expected GeminiError.consentRequired")
        } catch GeminiError.consentRequired {
            // expected: the page shows the consent sheet, then asks again
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(NoteRequestStub.requestCount, 0)
    }

    func testOfflineThrowsAURLError() async {
        let assistant = makeAssistant(protocolClass: OfflineNoteRequestStub.self, consent: true)
        do {
            _ = try await assistant.suggestNotes(for: tokyoTrip, now: now)
            XCTFail("expected a URLError")
        } catch is URLError {
            // expected: the page answers from the rules ("Suggestions from Smart Schedules")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testDemoModeAnswersFromTheRules() async throws {
        let store = SharedStore(fileURL: files.url("SuggestedNotes-demo"))
        let demo = DemoAssistant(store: store, clock: TestClock.clock,
                                 preferences: PreferencesStore(fileURL: files.url("SuggestedNotes-demo-prefs")),
                                 rescheduleReminders: { _ in })
        let result = try await demo.suggestNotes(for: event("demo-flight"))
        XCTAssertEqual(result.count, 7, "more than the page shows at once")
        XCTAssertEqual(result.first?.text, "Bring passport")
        XCTAssertTrue(result.allSatisfy { $0.source == .rules })
    }

    // MARK: "×"

    func testDismissalsAreKeptPerEvent() {
        XCTAssertFalse(NoteSuggestionDismissals.isDismissed(eventID: "yoga", in: defaults))
        NoteSuggestionDismissals.dismiss(eventID: "yoga", in: defaults)
        XCTAssertTrue(NoteSuggestionDismissals.isDismissed(eventID: "yoga", in: defaults))
        XCTAssertFalse(NoteSuggestionDismissals.isDismissed(eventID: "gym", in: defaults))
        NoteSuggestionDismissals.restore(eventID: "yoga", in: defaults)
        XCTAssertFalse(NoteSuggestionDismissals.isDismissed(eventID: "yoga", in: defaults))

        // A repeating event is one key for every occurrence.
        XCTAssertEqual(NoteSuggestionDismissals.key(for: event("yoga_3", seriesID: "yoga")), "yoga")
        XCTAssertEqual(NoteSuggestionDismissals.key(for: event("lunch")), "lunch")
    }

    func testDismissalsKeepTheNewest() {
        let start = TestClock.utc(2026, 10, 1)
        for index in 0..<(NoteSuggestionDismissals.maxEntries + 5) {
            NoteSuggestionDismissals.dismiss(eventID: "e\(index)", in: defaults, now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertFalse(NoteSuggestionDismissals.isDismissed(eventID: "e0", in: defaults))
        XCTAssertTrue(NoteSuggestionDismissals.isDismissed(eventID: "e\(NoteSuggestionDismissals.maxEntries + 4)", in: defaults))
        NoteSuggestionDismissals.reset(in: defaults)
        XCTAssertFalse(NoteSuggestionDismissals.isDismissed(eventID: "e\(NoteSuggestionDismissals.maxEntries + 4)", in: defaults))
    }

    // MARK: Helpers

    private func makeAssistant(protocolClass: AnyClass, consent: Bool) -> ScheduleAssistant {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { consent })
        let accounts = AccountStore(fileURL: files.url("SuggestedNotes-accounts"), isDemoMode: { false },
                                    defaultCalendar: { nil })
        let store = SharedStore(fileURL: files.url("SuggestedNotes-assistant-cache"), accounts: accounts)
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: nil,
                                    outbox: SyncOutbox(fileURL: files.url("SuggestedNotes-outbox")))
        return ScheduleAssistant(gemini: gemini, router: router, store: store,
                                 preferences: PreferencesStore(fileURL: files.url("SuggestedNotes-prefs")),
                                 clock: TestClock.clock)
    }
}

/// Answers every Gemini request with a suggest_event_notes call for the Tokyo trip, and keeps the last request body.
private final class NoteRequestStub: URLProtocol {
    static let tokyoResponse = #"""
    {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "suggest_event_notes", "args": {
      "items": ["Passport", "Yen cash", "IC transit card", "Visit Japan Web entry QR", "eSIM or pocket Wi-Fi"],
      "reason": "Five days in Tokyo."}}}]}, "finishReason": "STOP"}]}
    """#

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var body: Data?

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return body }

        func record(_ data: Data?) { lock.lock(); count += 1; body = data; lock.unlock() }
        func reset() { lock.lock(); count = 0; body = nil; lock.unlock() }
    }

    static let recorder = Recorder()
    static var requestCount: Int { recorder.requestCount }
    static var lastBody: Data? { recorder.lastBody }
    static func reset() { recorder.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(Self.bodyData(of: request))
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://gemini.example.invalid")!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.tokyoResponse.utf8))
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

/// No network.
private final class OfflineNoteRequestStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
