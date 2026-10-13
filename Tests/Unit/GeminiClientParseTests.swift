import XCTest

final class GeminiClientParseTests: XCTestCase {
    private func parse(_ json: String) throws -> GeminiResponse {
        try GeminiClient.parse(Data(json.utf8))
    }

    private func blockedReason(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try parse(json)
            XCTFail("expected GeminiError.blocked", file: file, line: line)
        } catch GeminiError.blocked(let reason) {
            return reason
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return nil
    }

    func testFunctionCallWithThoughtSignatureSurvivesVerbatim() throws {
        let response = try parse("""
        {
          "candidates": [{
            "content": {
              "parts": [
                {"text": "hidden", "thought": true},
                {"functionCall": {"name": "create_events",
                                  "args": {"events": [{"title": "Gym", "start": "2026-10-14T07:00", "duration_minutes": 60}]}},
                 "thoughtSignature": "abc=="}
              ]
            },
            "finishReason": "STOP"
          }],
          "usageMetadata": {"totalTokenCount": 42}
        }
        """)

        XCTAssertNil(response.text) // thought text is never shown to the user
        XCTAssertEqual(response.functionCalls.count, 1)
        let call = try XCTUnwrap(response.functionCalls.first)
        XCTAssertEqual(call.name, AssistantFunction.createEvents.rawValue)
        XCTAssertNil(call.id)
        let args = try call.decode(CreateEventsArgs.self)
        XCTAssertEqual(args.events.first?.title, "Gym")
        XCTAssertEqual(args.events.first?.durationMinutes, 60)

        // Gemini 3 rejects the follow-up turn if the signature is dropped.
        let turn = try TestJSON.object(response.modelTurn.json)
        XCTAssertEqual(turn["role"] as? String, "model")
        let parts = try XCTUnwrap(turn["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["thought"] as? Bool, true)
        XCTAssertEqual(parts[1]["thoughtSignature"] as? String, "abc==")
        XCTAssertNotNil(parts[1]["functionCall"] as? [String: Any])
        XCTAssertTrue(String(decoding: response.modelTurn.json, as: UTF8.self).contains("thoughtSignature"))
    }

    func testFunctionCallIDAndSnakeCaseArgs() throws {
        let response = try parse("""
        {"candidates": [{"content": {"role": "model", "parts": [
          {"functionCall": {"id": "call-7", "name": "reply_to_user",
                            "args": {"message": "Which one?", "needs_clarification": true, "suggested_replies": ["Gym", "Lunch"]}}}
        ]}, "finishReason": "STOP"}]}
        """)
        let call = try XCTUnwrap(response.functionCalls.first)
        XCTAssertEqual(call.id, "call-7")
        let args = try call.decode(ReplyToUserArgs.self)
        XCTAssertEqual(args.message, "Which one?")
        XCTAssertEqual(args.needsClarification, true)
        XCTAssertEqual(args.suggestedReplies, ["Gym", "Lunch"])
    }

    func testSeveralCallsKeepOrder() throws {
        let response = try parse("""
        {"candidates": [{"content": {"parts": [
          {"functionCall": {"name": "query_schedule", "args": {"range_start": "2026-10-15"}}},
          {"functionCall": {"name": "reply_to_user", "args": {"message": "Here you go"}}}
        ]}}]}
        """)
        XCTAssertEqual(response.functionCalls.map(\.name), ["query_schedule", "reply_to_user"])
        XCTAssertEqual(try response.functionCalls[0].decode(QueryScheduleArgs.self).rangeStart, "2026-10-15")
    }

    func testPlainTextIsConcatenated() throws {
        let response = try parse("""
        {"candidates": [{"content": {"parts": [{"text": "Hello "}, {"text": "world"}]}, "finishReason": "STOP"}]}
        """)
        XCTAssertEqual(response.text, "Hello world")
        XCTAssertTrue(response.functionCalls.isEmpty)
    }

    func testBlockedPromptThrows() {
        XCTAssertEqual(blockedReason(#"{"promptFeedback": {"blockReason": "SAFETY"}}"#), "SAFETY")
    }

    func testMissingCandidatesThrowsBlocked() {
        XCTAssertEqual(blockedReason(#"{"candidates": []}"#), "no candidates")
    }

    func testEmptyContentWithNonStopFinishThrowsBlocked() {
        XCTAssertEqual(blockedReason(#"{"candidates": [{"content": {"parts": []}, "finishReason": "MAX_TOKENS"}]}"#),
                       "MAX_TOKENS")
    }

    func testNonObjectRootIsMalformed() {
        XCTAssertThrowsError(try parse("[]")) { error in
            guard case .malformed? = error as? GeminiError else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Turns sent back to Gemini

    func testUserTurnShape() throws {
        let json = try TestJSON.object(GeminiTurn.user("add gym tomorrow 7am").json)
        XCTAssertEqual(json["role"] as? String, "user")
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "add gym tomorrow 7am")
    }

    func testFunctionResponsesShape() throws {
        let turn = GeminiTurn.functionResponses([
            .init(name: "create_events", id: "call-1", responseJSON: Data(#"{"ok": true, "created": []}"#.utf8)),
            .init(name: "query_schedule", id: nil, responseJSON: Data(#"{"ok": true, "count": 2}"#.utf8))
        ])
        let json = try TestJSON.object(turn.json)
        XCTAssertEqual(json["role"] as? String, "user")
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)

        let first = try XCTUnwrap(parts[0]["functionResponse"] as? [String: Any])
        XCTAssertEqual(first["name"] as? String, "create_events")
        XCTAssertEqual(first["id"] as? String, "call-1")
        let firstResponse = try XCTUnwrap(first["response"] as? [String: Any])
        XCTAssertEqual(firstResponse["ok"] as? Bool, true)

        let second = try XCTUnwrap(parts[1]["functionResponse"] as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "query_schedule")
        XCTAssertNil(second["id"])
        XCTAssertEqual((second["response"] as? [String: Any])?["count"] as? Int, 2)
    }

    // MARK: Declarations resource

    func testFunctionDeclarationsShipInBundleAndMatchAssistantFunctions() throws {
        let url = try XCTUnwrap(Bundle(for: GeminiClient.self).url(forResource: "FunctionDeclarations", withExtension: "json"),
                                "Shared/AI/FunctionDeclarations.json must be a resource of the test bundle")
        let declarations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let names = declarations.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, 8)
        XCTAssertEqual(Set(names), Set(AssistantFunction.allCases.map(\.rawValue)))
        for declaration in declarations {
            XCTAssertNotNil(declaration["parameters"] as? [String: Any], "\(declaration["name"] ?? "?")")
        }

        let confirm = try XCTUnwrap(declarations.first { $0["name"] as? String == "confirm_plan" })
        let parameters = try XCTUnwrap(confirm["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["decision"])
        let decision = try XCTUnwrap((parameters["properties"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["enum"] as? [String], ["add", "discard"])
    }

    func testConfirmPlanCallDecodes() throws {
        let response = try parse("""
        {"candidates": [{"content": {"parts": [
          {"functionCall": {"name": "confirm_plan", "args": {"decision": "discard"}}}
        ]}, "finishReason": "STOP"}]}
        """)
        let call = try XCTUnwrap(response.functionCalls.first)
        XCTAssertEqual(AssistantFunction(rawValue: call.name), .confirmPlan)
        XCTAssertEqual(try call.decode(ConfirmPlanArgs.self).decision, "discard")
    }

    func testUpdatePreferencesCallDecodes() throws {
        let response = try parse("""
        {"candidates": [{"content": {"parts": [
          {"functionCall": {"name": "update_preferences", "args": {
            "changes": [{"key": "quiet_hours", "value": "22:00-08:00"}, {"key": "routine_reminders", "value": "120"}],
            "summary_for_user": "From now on, reminders before 08:00 arrive silently."}}}
        ]}, "finishReason": "STOP"}]}
        """)
        let call = try XCTUnwrap(response.functionCalls.first)
        XCTAssertEqual(AssistantFunction(rawValue: call.name), .updatePreferences)
        let args = try call.decode(UpdatePreferencesArgs.self)
        XCTAssertEqual(args.changes.map(\.key), ["quiet_hours", "routine_reminders"])
        XCTAssertEqual(args.changes.map(\.value), ["22:00-08:00", "120"])
        XCTAssertEqual(args.summaryForUser, "From now on, reminders before 08:00 arrive silently.")
    }

    // MARK: AI data-sharing consent

    /// A session whose every request is counted and fails, so a test can prove nothing was sent.
    private func countingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let offlineConfig = GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                             apiKey: "test-key", thinkingLevel: nil)

    func testWithoutConsentNothingIsSent() async {
        CountingURLProtocol.counter.reset()
        let client = GeminiClient(config: offlineConfig, session: countingSession(), consentCheck: { false })
        do {
            _ = try await client.generate(system: "system", history: [.user("Lunch with Andrew tomorrow 1pm")])
            XCTFail("expected GeminiError.consentRequired")
        } catch GeminiError.consentRequired {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(CountingURLProtocol.counter.value, 0, "no request may leave the device without consent")
    }

    func testWithConsentTheRequestIsSent() async {
        CountingURLProtocol.counter.reset()
        let client = GeminiClient(config: offlineConfig, session: countingSession(), consentCheck: { true })
        do {
            _ = try await client.generate(system: "system", history: [.user("hi")])
            XCTFail("the counting session always fails")
        } catch GeminiError.consentRequired {
            XCTFail("consent was granted")
        } catch {
            // The transport error of the counting session.
        }
        XCTAssertGreaterThan(CountingURLProtocol.counter.value, 0)
    }

    func testConsentErrorExplainsWhereToAllowSharing() {
        XCTAssertEqual(GeminiError.consentRequired.errorDescription,
                       "Allow AI data sharing in Settings › AI & privacy to use the assistant.")
    }
}

/// Counts requests and fails each one (no network in unit tests).
private final class CountingURLProtocol: URLProtocol {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
        func reset() { lock.lock(); count = 0; lock.unlock() }
    }

    static let counter = Counter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
