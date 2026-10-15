import XCTest

/// End to end through `ScheduleAssistant` with two Google accounts: no account's email address reaches Gemini, neither
/// in the system prompt nor in the function results sent back on the next turn nor in the "AI suggestions" request
/// (docs/GEMINI_FUNCTION_CALLING.md §10.6). The replies on this iPhone keep the real addresses.
final class AccountEmailPrivacyTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private let personalEmail = "kenny@example.com"
    private let schoolEmail = "example@yourmail.com"

    override func setUp() {
        super.setUp()
        PrivacyGeminiStub.reset()
    }

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    func testNoAccountEmailReachesGemini() async throws {
        let (assistant, preferences, squash) = await makeAssistant()
        let schoolRef = CalendarRef(accountID: "acct-b", calendarID: schoolEmail)

        // 1. update_preferences with the second account's CALENDARS line.
        let first = try await assistant.handle("以後用第二個帳號", now: now)
        XCTAssertNotNil(first.preferenceReceipt)
        XCTAssertTrue(first.rejectedPreferences.isEmpty)
        XCTAssertEqual(preferences.current().defaultCalendar, schoolRef)
        XCTAssertEqual(preferences.current().defaultCalendarLabel, "My calendar | \(schoolEmail)", "the label stays on this iPhone")

        // 2. create_events: the school account's Google sign-in expired, so the write fails with its address.
        let second = try await assistant.handle("明天下午兩點開會", now: now)
        XCTAssertTrue(second.text.contains("Google sign-in for \(schoolEmail) expired"), second.text)

        // 3. reply_to_user.
        _ = try await assistant.handle("好", now: now)

        // 4. "AI suggestions" for an event whose place names the account.
        _ = try await assistant.suggestNotes(for: squash, now: now)

        let bodies = PrivacyGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self).lowercased() }
        XCTAssertEqual(bodies.count, 4)
        for (index, body) in bodies.enumerated() {
            XCTAssertFalse(body.contains(personalEmail), "request \(index + 1): \(body)")
            XCTAssertFalse(body.contains(schoolEmail), "request \(index + 1): \(body)")
        }
        // The prompt: CALENDARS by account number, the accounts' addresses in an event left out.
        XCTAssertTrue(bodies[0].contains("- my calendar | account 1"), bodies[0])
        XCTAssertTrue(bodies[0].contains("- gym | account 1"), bodies[0])
        XCTAssertTrue(bodies[0].contains("- my calendar | account 2"), bodies[0])
        XCTAssertTrue(bodies[0].contains("squash with [account 1 email]"), bodies[0])
        XCTAssertTrue(bodies[0].contains("court booked by [account 2 email]"), bodies[0])
        // The update_preferences result names the calendar as CALENDARS does; PREFERENCES follows.
        XCTAssertTrue(bodies[1].contains(#""new":"my calendar | account 2""#), bodies[1])
        XCTAssertTrue(bodies[1].contains(#""old":"automatic""#), bodies[1])
        XCTAssertTrue(bodies[1].contains("default_calendar: my calendar | account 2"), bodies[1])
        // The expired sign-in reaches Gemini without the address.
        XCTAssertTrue(bodies[2].contains("google sign-in for [account 2 email] expired"), bodies[2])
        // The note suggestion request: the place without the address.
        XCTAssertTrue(bodies[3].contains("location: court 3, ask for [account 1 email]"), bodies[3])
    }

    func testAnAmbiguousOrStaleAliasIsRefusedNotGuessed() async throws {
        // "My calendar" is both accounts' primary calendar; there is no Account 3 (any more).
        PrivacyGeminiStub.reset(responses: [PrivacyGeminiStub.preferences(value: "My calendar"),
                                            PrivacyGeminiStub.preferences(value: "My calendar | Account 3")])
        let (assistant, preferences, _) = await makeAssistant()
        for utterance in ["以後用我的行事曆", "以後用第三個帳號"] {
            let reply = try await assistant.handle(utterance, now: now)
            XCTAssertNil(reply.preferenceReceipt, utterance)
            XCTAssertEqual(reply.rejectedPreferences.map(\.key), ["default_calendar"], utterance)
            XCTAssertNil(preferences.current().defaultCalendar, utterance)
        }
        let bodies = PrivacyGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self).lowercased() }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(bodies[1].contains(personalEmail) || bodies[1].contains(schoolEmail), bodies[1])
    }

    func testTheUsersOwnWordsAreMatchedOnThisIPhone() async throws {
        // The user typed the address: Gemini sees "[Account 2 email]" and passes it on; the app finds the account.
        PrivacyGeminiStub.reset(responses: [PrivacyGeminiStub.preferences(value: "[Account 2 email]")])
        let (assistant, preferences, _) = await makeAssistant()
        let reply = try await assistant.handle("use \(schoolEmail) from now on", now: now)
        XCTAssertTrue(reply.rejectedPreferences.isEmpty)
        XCTAssertEqual(preferences.current().defaultCalendar, CalendarRef(accountID: "acct-b", calendarID: schoolEmail))

        let bodies = PrivacyGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self).lowercased() }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("use [account 2 email] from now on"), bodies[0])
        XCTAssertFalse(bodies[0].contains(schoolEmail), bodies[0])
    }

    func testPlaceholdersTheModelWritesAreFilledInOnThisIPhone() async throws {
        // "Same squash next Friday, and invite my school address": the model copies the placeholders it sees.
        PrivacyGeminiStub.reset(responses: [PrivacyGeminiStub.squashAgain, PrivacyGeminiStub.inviteQuestion])
        let (assistant, preferences, _) = await makeAssistant()
        await preferences.update { $0.autonomy = .askFirst } // the events wait as a batch: nothing needs Google

        let copy = try await assistant.handle("same squash next Friday", now: now)
        let batch = try XCTUnwrap(copy.pendingEvents)
        XCTAssertEqual(batch.previewEvents.first?.title, "Squash with \(personalEmail)")
        XCTAssertEqual(batch.previewEvents.first?.location, "Court 3, ask for \(personalEmail)")
        let args = try ScheduleAssistant.decodeCreateArgs(batch.argsJSON)
        XCTAssertEqual(args.events.first?.attendees, [schoolEmail], "what Add writes to Google Calendar")

        let question = try await assistant.handle("and my school address?", now: now)
        XCTAssertTrue(question.text.contains("Invite \(schoolEmail)?"), question.text)
        XCTAssertEqual(question.suggestions, ["Yes, invite \(schoolEmail)"])

        // Gemini still sees only the placeholders: its own turn, the PENDING EVENTS block and the function results.
        let bodies = PrivacyGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self).lowercased() }
        XCTAssertEqual(bodies.count, 2)
        for (index, body) in bodies.enumerated() {
            XCTAssertFalse(body.contains(personalEmail), "request \(index + 1): \(body)")
            XCTAssertFalse(body.contains(schoolEmail), "request \(index + 1): \(body)")
        }
        XCTAssertTrue(bodies[1].contains("squash with [account 1 email] | 2026-10-16t18:00"), bodies[1])
    }

    // MARK: Helpers

    /// Two accounts (personal with a Gym calendar, school), an event in Gym whose title, notes and place hold both
    /// addresses, and a Google that answers every write with an expired sign-in.
    private func makeAssistant() async -> (ScheduleAssistant, PreferencesStore, ScheduleEvent) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyGeminiStub.self]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { true })
        let preferences = PreferencesStore(fileURL: files.url("AccountEmailPrivacy-prefs"))
        let accounts = AccountStore(fileURL: files.url("AccountEmailPrivacy-accounts"), isDemoMode: { false },
                                    defaultCalendar: { preferences.current().defaultCalendar })
        let gym = SampleAccounts.calendar("acct-a", "gym-id", email: personalEmail, name: "Gym", role: "writer")
        await accounts.upsert(SampleAccounts.account("acct-a", email: personalEmail, extra: [gym]))
        await accounts.upsert(SampleAccounts.account("acct-b", email: schoolEmail))

        let store = SharedStore(fileURL: files.url("AccountEmailPrivacy-cache"), accounts: accounts)
        var squash = TestEvents.make(id: "sqsh1", title: "Squash with \(personalEmail)",
                                     start: TestClock.local(2026, 10, 14, 18), end: TestClock.local(2026, 10, 14, 19),
                                     calendar: gym.id)
        squash.notes = "Court booked by \(schoolEmail)"
        squash.location = "Court 3, ask for \(personalEmail)"
        await store.upsert([squash])

        // Every Google write fails as an expired sign-in of that account would.
        let transport = ExpiredSignInTransport(emails: ["acct-a": personalEmail, "acct-b": schoolEmail])
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: transport,
                                    outbox: SyncOutbox(fileURL: files.url("AccountEmailPrivacy-outbox")))
        let assistant = ScheduleAssistant(gemini: gemini, router: router, store: store, preferences: preferences,
                                          clock: TestClock.clock)
        return (assistant, preferences, squash)
    }
}

/// Google answers every token request for an account with "sign-in expired" (`AuthError.reconnectNeeded`), which the
/// router does not queue: the error goes back to Gemini.
private struct ExpiredSignInTransport: CalendarTransport {
    let emails: [String: String]

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        throw AuthError.reconnectNeeded(email: emails[accountID ?? ""] ?? "")
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// Answers Gemini requests in turn and keeps every request body.
private final class PrivacyGeminiStub: URLProtocol {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Data] = []
        private var answers: [String] = []

        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return recorded }

        /// Records `body` and returns the answer for this request (the last one again once they run out).
        func next(_ body: Data?) -> String {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(body ?? Data())
            return answers[min(recorded.count - 1, answers.count - 1)]
        }

        func reset(_ responses: [String]) {
            lock.lock()
            recorded = []
            answers = responses
            lock.unlock()
        }
    }

    static let recorder = Recorder()

    static func preferences(value: String) -> String {
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "update_preferences", "args": {
          "changes": [{"key": "default_calendar", "value": "\#(value)"}],
          "summary_for_user": "以後新行程會加到這個行事曆。"}}}]}, "finishReason": "STOP"}]}
        """#
    }

    static let squashAgain = #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "create_events", "args": {
          "events": [{"title": "Squash with [Account 1 email]", "start": "2026-10-16T18:00", "duration_minutes": 60,
                      "kind": "event", "location": "Court 3, ask for [Account 1 email]",
                      "attendees": ["[Account 2 email]"]}]}}}]}, "finishReason": "STOP"}]}
        """#

    static let inviteQuestion = #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "reply_to_user", "args": {
          "message": "Invite [Account 2 email]?", "needs_clarification": true,
          "suggested_replies": ["Yes, invite [Account 2 email]"]}}}]}, "finishReason": "STOP"}]}
        """#

    static let conversation: [String] = [
        PrivacyGeminiStub.preferences(value: "My calendar | Account 2"),
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "create_events", "args": {
          "events": [{"title": "開會", "start": "2026-10-14T14:00", "kind": "event"}]}}}]}, "finishReason": "STOP"}]}
        """#,
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "reply_to_user", "args": {
          "message": "請先在設定裡重新連接第二個帳號。"}}}]}, "finishReason": "STOP"}]}
        """#,
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "suggest_event_notes", "args": {
          "items": ["Squash racket", "Water"]}}}]}, "finishReason": "STOP"}]}
        """#
    ]

    static func reset(responses: [String] = PrivacyGeminiStub.conversation) { recorder.reset(responses) }

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
