import XCTest

/// Events made from the answer to Gemini's "what time?" keep the request in their notes, not only "14:00".
final class ClarifiedRequestTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)

    override func setUp() {
        super.setUp()
        ClarifyingGeminiStub.reset()
        DoubleReplyGeminiStub.reset()
    }

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    func testTheAnswersEventsKeepTheRequest() async throws {
        let assistant = await makeAssistant()
        let question = try await assistant.handle("明天下午開線上會議", now: now)
        XCTAssertTrue(question.needsClarification)
        XCTAssertNil(question.pendingEvents)

        let answer = try await assistant.handle("14:00", now: now)
        let batch = try XCTUnwrap(answer.pendingEvents)
        XCTAssertEqual(batch.utterance, "明天下午開線上會議 → 14:00")
        XCTAssertEqual(batch.previewEvents.first?.notes, CalendarEventMapper.provenancePrefix + "明天下午開線上會議 → 14:00")

        // The next request stands on its own again.
        let next = try await assistant.handle("後天上午十點看牙醫", now: now)
        XCTAssertEqual(next.pendingEvents?.utterance, "後天上午十點看牙醫")
        XCTAssertEqual(ClarifyingGeminiStub.requestCount, 3)
    }

    /// Gemini sends reply_to_user twice in one turn (the question, then a decline of the off-topic part): the reply
    /// keeps the question's needs_clarification and one-tap answers, and shows both texts.
    func testASecondReplyToUserKeepsTheQuestionAndItsAnswers() async throws {
        let assistant = await makeAssistant(stub: DoubleReplyGeminiStub.self)
        let reply = try await assistant.handle("明天下午開線上會議，順便告訴我今天的新聞", now: now)
        XCTAssertTrue(reply.needsClarification)
        XCTAssertEqual(reply.suggestions, ["13:00", "14:00", "15:00"])
        XCTAssertTrue(reply.text.contains("明天下午的「線上會議」要排在幾點？"), reply.text)
        XCTAssertTrue(reply.text.contains("我只能幫你處理行程和時間相關的事，新聞的部分幫不上忙。"), reply.text)
        XCTAssertNil(reply.pendingEvents)
        XCTAssertEqual(DoubleReplyGeminiStub.requestCount, 1)
    }

    // MARK: Helpers

    /// "Ask me first", so the events wait as a batch and nothing needs Google.
    private func makeAssistant(stub: AnyClass = ClarifyingGeminiStub.self) async -> ScheduleAssistant {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { true })
        let accounts = AccountStore(fileURL: files.url("ClarifiedRequest-accounts"), isDemoMode: { false },
                                    defaultCalendar: { nil })
        let store = SharedStore(fileURL: files.url("ClarifiedRequest-cache"), accounts: accounts)
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: nil,
                                    outbox: SyncOutbox(fileURL: files.url("ClarifiedRequest-outbox")))
        let preferences = PreferencesStore(fileURL: files.url("ClarifiedRequest-prefs"))
        await preferences.update { $0.autonomy = .askFirst }
        return ScheduleAssistant(gemini: gemini, router: router, store: store, preferences: preferences,
                                 clock: TestClock.clock)
    }
}

/// Gemini asks what time first, then creates the meeting at 14:00, then the dentist.
private final class ClarifyingGeminiStub: URLProtocol {
    private static let responses = [
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "reply_to_user", "args": {
          "message": "明天下午的「線上會議」要排在幾點？", "needs_clarification": true,
          "suggested_replies": ["13:00", "14:00", "15:00"]}}}]}, "finishReason": "STOP"}]}
        """#,
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "create_events", "args": {
          "events": [{"title": "線上會議", "start": "2026-10-14T14:00", "kind": "event"}]}}}]}, "finishReason": "STOP"}]}
        """#,
        #"""
        {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "create_events", "args": {
          "events": [{"title": "看牙醫", "start": "2026-10-15T10:00", "kind": "event"}]}}}]}, "finishReason": "STOP"}]}
        """#
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.lock.withLock { () -> Int in
            defer { Self.count += 1 }
            return Self.count
        }
        let body = Self.responses[min(index, Self.responses.count - 1)]
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://gemini.example.invalid")!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One turn with two reply_to_user calls: the question with its one-tap answers, then a decline without any.
private final class DoubleReplyGeminiStub: URLProtocol {
    private static let body = #"""
        {"candidates": [{"content": {"role": "model", "parts": [
          {"functionCall": {"name": "reply_to_user", "args": {
            "message": "明天下午的「線上會議」要排在幾點？", "needs_clarification": true,
            "suggested_replies": ["13:00", "14:00", "15:00"]}}},
          {"functionCall": {"name": "reply_to_user", "args": {
            "message": "我只能幫你處理行程和時間相關的事，新聞的部分幫不上忙。"}}}]}, "finishReason": "STOP"}]}
        """#

    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://gemini.example.invalid")!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
