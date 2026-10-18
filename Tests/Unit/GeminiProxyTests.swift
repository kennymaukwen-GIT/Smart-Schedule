import DeviceCheck
import XCTest

/// Gemini requests go to Smart Schedule's server with App Attest headers and never an API key; the body the
/// assertion signs is exactly the body sent; the server's 401s get one fresh assertion (or a new key). The
/// notification extension sends a session the app renews; the iOS 18 push-to-start registration (behind
/// `AppConstants.pushToStartEnabled`, off in version 1.0) reaches the server only with consent and is cleared when
/// consent goes or the data is erased; with it off, nothing is uploaded and erasing needs no request.
final class GeminiProxyTests: XCTestCase {
    private let config = GeminiConfig(baseURL: "https://ss.example.dev/v1beta", modelID: "test-model",
                                      apiKey: "must-not-be-sent", thinkingLevel: "low")

    override func setUp() {
        super.setUp()
        ProxyStub.reset()
    }

    private func client(_ attestation: FakeAttestation, config: GeminiConfig? = nil) -> GeminiClient {
        GeminiClient(config: config ?? self.config, session: stubSession(), consentCheck: { true }, attestation: attestation)
    }

    func testRequestsGoToTheServerWithAttestationAndNoKey() async throws {
        let attestation = FakeAttestation()
        ProxyStub.respond([(200, ProxyStub.okResponse)])
        _ = try await client(attestation).generate(system: "system", history: [.user("Lunch tomorrow 1pm")])

        let request = try XCTUnwrap(ProxyStub.requests.first)
        XCTAssertEqual(request.url, "https://ss.example.dev/v1beta/models/test-model:generateContent")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-1")
        XCTAssertNil(request.headers["x-goog-api-key"], "the server adds the key")
        XCTAssertFalse(request.url.contains("key="))
        let signed = await attestation.bodies
        XCTAssertEqual(signed, [request.body], "the assertion signs exactly the body that is sent")
        // The body is Gemini's own: generationConfig as before, and the content filter (safetySettings).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Set(json.keys),
                       ["systemInstruction", "contents", "tools", "toolConfig", "generationConfig", "safetySettings"])
        XCTAssertEqual((json["generationConfig"] as? [String: Any]).flatMap { $0["thinkingConfig"] as? [String: String] },
                       ["thinkingLevel": "low"])
    }

    // MARK: Content filter

    private let contentBlockedMessage = "I can't help with that. I can help with your events, times and plans."
    private let requestFailedMessage = "Something went wrong with that request. Please try again, or say it another way."

    /// Gemini 2.5 and 3 filter nothing unless a threshold is set: every request carries these four, dangerous content
    /// only when high (ordinary event titles in the prompt must not make requests fail).
    func testEveryRequestCarriesTheSafetySettings() async throws {
        ProxyStub.respond([(200, ProxyStub.okResponse)])
        _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("Chemistry exam Friday 9am")])
        let request = try XCTUnwrap(ProxyStub.requests.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let settings = try XCTUnwrap(json["safetySettings"] as? [[String: String]])
        XCTAssertEqual(settings, [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
            ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
            ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
        ])
        XCTAssertEqual(settings, GeminiClient.safetySettings)
    }

    /// Sends one request whose answer is `response` and returns the `GeminiError.blocked` it throws.
    private func blockedError(for response: String, file: StaticString = #filePath,
                              line: UInt = #line) async -> GeminiError? {
        ProxyStub.reset()
        ProxyStub.respond([(200, response)])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected GeminiError.blocked", file: file, line: line)
        } catch let error as GeminiError {
            guard case .blocked = error else {
                XCTFail("unexpected \(error)", file: file, line: line)
                return nil
            }
            XCTAssertEqual(ProxyStub.requests.count, 1, "not retried", file: file, line: line)
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return nil
    }

    /// A filtered prompt (promptFeedback.blockReason) or answer (a candidate without content): the reply says what
    /// the assistant can help with, never Gemini's reason.
    func testFilteredContentSaysWhatTheAssistantCanHelpWith() async throws {
        let filtered: [(response: String, reason: String)] = [
            (#"{"promptFeedback": {"blockReason": "SAFETY"}}"#, "SAFETY"),
            (#"{"candidates": [{"finishReason": "SAFETY", "index": 0}]}"#, "SAFETY"),
            (#"{"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}}"#, "PROHIBITED_CONTENT")
        ]
        for (response, expected) in filtered {
            let error = await blockedError(for: response)
            guard case let .blocked(reason)? = error else { continue }
            XCTAssertEqual(reason, expected, response)
            XCTAssertEqual(error?.errorDescription, contentBlockedMessage, response)
            XCTAssertEqual(error?.localizedDescription, contentBlockedMessage, "what the chat shows")
            XCTAssertFalse(error?.localizedDescription.contains(reason) ?? true, "no raw reason in the reply")
        }
    }

    /// An answer cut short (MAX_TOKENS) with no call and no text is not about what was asked: try again.
    func testAnAnswerCutShortAsksToTryAgain() async throws {
        let cutShort = #"{"candidates": [{"content": {"role": "model", "parts": []}, "finishReason": "MAX_TOKENS"}]}"#
        let error = await blockedError(for: cutShort)
        guard case let .blocked(reason)? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(reason, "MAX_TOKENS")
        XCTAssertEqual(error?.errorDescription, requestFailedMessage)
        XCTAssertEqual(error?.localizedDescription, requestFailedMessage)

        let empty = await blockedError(for: #"{"candidates": []}"#)
        guard case let .blocked(emptyReason)? = empty else { return XCTFail("got \(String(describing: empty))") }
        XCTAssertEqual(emptyReason, "no candidates")
        XCTAssertEqual(empty?.errorDescription, requestFailedMessage)
    }

    func testWhichBlockReasonsMeanTheContentWasFiltered() {
        for reason in ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY", "RECITATION"] {
            XCTAssertTrue(GeminiError.isContentBlock(reason: reason), reason)
            XCTAssertEqual(GeminiError.blocked(reason: reason).errorDescription, contentBlockedMessage, reason)
        }
        for reason in ["MAX_TOKENS", "MALFORMED_FUNCTION_CALL", "OTHER", "no candidates", "FINISH_REASON_UNSPECIFIED",
                       "BLOCK_REASON_UNSPECIFIED", "STOP", "SOMETHING_NEW", ""] {
            XCTAssertFalse(GeminiError.isContentBlock(reason: reason), reason)
            XCTAssertEqual(GeminiError.blocked(reason: reason).errorDescription, requestFailedMessage, reason)
        }
    }

    func testAStaleCounterGetsOneFreshAssertion() async throws {
        let attestation = FakeAttestation()
        ProxyStub.respond([(401, #"{"error":"stale_counter"}"#), (200, ProxyStub.okResponse)])
        _ = try await client(attestation).generate(system: "system", history: [.user("hi")])
        XCTAssertEqual(ProxyStub.requests.map { $0.headers["Authorization"] }, ["Bearer test-1", "Bearer test-2"])
        let resets = await attestation.resets
        XCTAssertEqual(resets, 0, "the key is fine: two requests crossed")
    }

    func testAnUnknownKeyIsAttestedAgain() async throws {
        let attestation = FakeAttestation()
        ProxyStub.respond([(401, #"{"error":"unknown_key"}"#), (200, ProxyStub.okResponse)])
        _ = try await client(attestation).generate(system: "system", history: [.user("hi")])
        XCTAssertEqual(ProxyStub.requests.count, 2)
        let resets = await attestation.resets
        XCTAssertEqual(resets, 1)
    }

    func testARejectedRetryIsNotRetriedForever() async {
        let attestation = FakeAttestation()
        ProxyStub.respond([(401, #"{"error":"invalid_assertion"}"#), (401, #"{"error":"invalid_assertion"}"#)])
        do {
            _ = try await client(attestation).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.server(let status) {
            XCTAssertEqual(status, 401, "the server's own error")
            XCTAssertEqual(AttestationError.server(status: status).errorDescription, requestFailedMessage, "not the status")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 2)
    }

    /// The server's per-minute limit: no retries seconds later, and a localized message instead of its JSON.
    func testTheServersRateLimitIsNotRetried() async {
        ProxyStub.respond([(429, #"{"error":"rate_limited"}"#, ["Retry-After": "42"]), (200, ProxyStub.okResponse, [:])])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.rateLimited {
            XCTAssertEqual(AttestationError.rateLimited.errorDescription, "Too many requests. Wait a minute and try again.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 1)
    }

    /// A limit until the next UTC day (Retry-After of hours) says "tomorrow", not "wait a minute".
    func testADailyLimitSaysTomorrow() async {
        ProxyStub.respond([(429, #"{"error":"rate_limited"}"#, ["Retry-After": "36000"])])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.dailyLimit {
            XCTAssertEqual(AttestationError.dailyLimit.errorDescription, "Today's limit is used up. Try again tomorrow.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 1)
    }

    /// invalid_attestation (POST /attest refused the key: a build attesting in App Attest's development environment, as
    /// Debug builds did before project.yml set production, against a Worker that checks production, or an APPLE_TEAM_ID
    /// that is not the build's team): it says the app could not be verified, not "something went wrong, try again". A
    /// 401 code this build does not know still is the general error.
    func testARejectedAttestationSaysTheAppCouldNotBeVerified() throws {
        let rejected = AttestedRequest.failure(status: 401, data: Data(#"{"error":"invalid_attestation"}"#.utf8),
                                               response: nil)
        guard case .attestationRejected? = rejected else { return XCTFail("got \(String(describing: rejected))") }
        XCTAssertEqual(rejected?.errorDescription,
                       "The Smart Schedules server couldn't verify this copy of the app, so the assistant is unavailable.")
        let unknown = AttestedRequest.failure(status: 401, data: Data(#"{"error":"something_new"}"#.utf8), response: nil)
        guard case .server(status: 401)? = unknown else { return XCTFail("got \(String(describing: unknown))") }
    }

    /// server_misconfigured (a missing secret on the server): retrying cannot help, and it is not a passing error.
    func testAServerThatIsNotSetUpIsNotRetried() async {
        ProxyStub.respond([(500, #"{"error":"server_misconfigured"}"#), (200, ProxyStub.okResponse)])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.serverNotReady {
            XCTAssertEqual(ProxyStub.requests.count, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// 503 server_busy (a KV write collided): retried after its Retry-After, signed again.
    func testABusyServerIsTriedAgain() async throws {
        let attestation = FakeAttestation()
        ProxyStub.respond([(503, #"{"error":"server_busy"}"#, ["Retry-After": "1"]), (200, ProxyStub.okResponse, [:])])
        _ = try await client(attestation).generate(system: "system", history: [.user("hi")])
        XCTAssertEqual(ProxyStub.requests.map { $0.headers["Authorization"] }, ["Bearer test-1", "Bearer test-2"])
    }

    /// Smart Schedule's own endpoints map the server's codes the same way.
    func testServerClientPostsJSONAndExplainsTheServersErrors() async throws {
        let server = ServerClient(origin: URL(string: "https://ss.example.dev"), attestation: FakeAttestation(),
                                  session: stubSession())
        ProxyStub.respond([(200, #"{"ok":true,"events":0}"#, [:]),
                           (500, #"{"error":"server_misconfigured"}"#, [:]),
                           (429, #"{"error":"rate_limited"}"#, ["Retry-After": "7200"])])
        _ = try await server.post("devices/push-to-start", json: Data("{}".utf8))
        let request = try XCTUnwrap(ProxyStub.requests.first)
        XCTAssertEqual(request.url, "https://ss.example.dev/devices/push-to-start")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-1")
        do {
            _ = try await server.post("devices/push-to-start", json: Data("{}".utf8))
            XCTFail("expected an error")
        } catch AttestationError.serverNotReady {}
        do {
            _ = try await server.post("devices/push-to-start", json: Data("{}".utf8))
            XCTFail("expected an error")
        } catch AttestationError.dailyLimit {}
    }

    /// A model the server no longer takes from the notification extension: nothing to retry, the app needs an update.
    func testARefusedSessionScopeAsksForAnUpdate() async {
        ProxyStub.respond([(403, #"{"error":"session_scope"}"#)])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.updateRequired {
            XCTAssertEqual(ProxyStub.requests.count, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Google's own errors still pass through as before: the payload keeps Google's status and message, the reply
    /// shows neither.
    func testGooglesErrorsKeepTheirMessage() async {
        ProxyStub.respond([(400, #"{"error":{"code":400,"message":"Invalid JSON payload"}}"#)])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch let error as GeminiError {
            guard case let .http(status, message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "Invalid JSON payload")
            XCTAssertEqual(error.localizedDescription, requestFailedMessage, "what the chat shows")
            XCTAssertFalse(error.localizedDescription.contains("Invalid JSON payload"))
            XCTAssertFalse(error.localizedDescription.contains("400"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 1, "a 4xx is not retried")
    }

    private let busyMessage = "The assistant is busy right now. Please try again in a moment."

    /// Google overloaded or out of quota (429, 5xx, after `send`'s two retries) passes: "busy, try again in a moment".
    /// Any other status is a request that went wrong. Neither shows Google's status or English message.
    func testGooglesErrorsAreShownAsBusyOrAsARequestThatWentWrong() {
        let google = "Resource has been exhausted (e.g. check quota)."
        for status in [429, 500, 502, 503, 504, 599] {
            let error = GeminiError.http(status: status, message: google)
            XCTAssertTrue(GeminiError.isBusy(status: status), "\(status)")
            XCTAssertEqual(error.errorDescription, busyMessage, "\(status)")
            XCTAssertEqual(error.localizedDescription, busyMessage, "\(status)")
            XCTAssertFalse(error.localizedDescription.contains(google), "\(status)")
            XCTAssertFalse(error.localizedDescription.contains("\(status)"), "\(status)")
            // Smart Schedules' own server says the same, without its status.
            XCTAssertEqual(AttestationError.server(status: status).errorDescription, busyMessage, "\(status)")
        }
        for status in [0, 400, 401, 403, 404, 413, 428, 499] {
            let error = GeminiError.http(status: status, message: google)
            XCTAssertFalse(GeminiError.isBusy(status: status), "\(status)")
            XCTAssertEqual(error.errorDescription, requestFailedMessage, "\(status)")
            XCTAssertFalse(error.localizedDescription.contains(google), "\(status)")
            XCTAssertEqual(AttestationError.server(status: status).errorDescription, requestFailedMessage, "\(status)")
        }
    }

    /// A response that can't be read: the reply asks to try again; the detail stays in the payload.
    func testAnUnreadableResponseAsksToTryAgain() async {
        XCTAssertEqual(GeminiError.malformed("root is not an object").errorDescription, requestFailedMessage)
        XCTAssertEqual(GeminiError.malformed("bad base URL").localizedDescription, requestFailedMessage)

        ProxyStub.respond([(200, "[]")])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch let error as GeminiError {
            guard case let .malformed(detail) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(detail, "root is not an object")
            XCTAssertEqual(error.localizedDescription, requestFailedMessage, "what the chat shows")
            XCTAssertFalse(error.localizedDescription.contains("Gemini"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGoogleItselfIsNeverCalledFromTheApp() async {
        let attestation = FakeAttestation()
        let direct = GeminiConfig(baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "test-model",
                                  apiKey: nil, thinkingLevel: nil)
        // Google itself (it would need an API key in the app), or GEMINI_BASE_URL not set at all.
        for config in [direct, GeminiConfig(baseURL: "", modelID: "test-model", apiKey: nil, thinkingLevel: nil)] {
            do {
                _ = try await client(attestation, config: config).generate(system: "system", history: [.user("hi")])
                XCTFail("expected an error")
            } catch AttestationError.notConfigured {
                // expected
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(ProxyStub.requests.isEmpty)
        let signed = await attestation.bodies
        XCTAssertTrue(signed.isEmpty)
    }

    /// 401 attestation_required: no credential the server accepts (a simulator build without the dev token, or an
    /// extension without a session) is not the server's general error ("something went wrong, try again").
    func testNoAcceptedCredentialIsNotATransientError() async {
        ProxyStub.respond([(401, #"{"error":"attestation_required"}"#)])
        do {
            _ = try await client(FakeAttestation()).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch AttestationError.unsupported {
            // expected in the app (the extension gets sessionMissing)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 1, "not retried")
    }

    // MARK: Endpoint and token

    func testServerOriginComesFromTheBaseURL() {
        XCTAssertEqual(ServerEndpoint.origin(of: "https://ss.example.dev/v1beta"), URL(string: "https://ss.example.dev"))
        XCTAssertEqual(ServerEndpoint.origin(of: "http://localhost:8787/v1beta"), URL(string: "http://localhost:8787"))
        XCTAssertEqual(ServerEndpoint.origin(of: "http://127.0.0.1:8787/v1beta"), URL(string: "http://127.0.0.1:8787"))
        XCTAssertNil(ServerEndpoint.origin(of: "http://ss.example.dev/v1beta"), "plain http only for a Worker on this Mac")
        XCTAssertNil(ServerEndpoint.origin(of: "https://generativelanguage.googleapis.com/v1beta"))
        XCTAssertNil(ServerEndpoint.origin(of: "https://GenerativeLanguage.GoogleAPIs.com/v1beta"))
        XCTAssertNil(ServerEndpoint.origin(of: ""))
    }

    func testBearerTokenIsTheKeyIDBytesThenTheAssertion() throws {
        let raw = Data((0..<32).map { UInt8($0) })
        let token = try XCTUnwrap(AppAttestClient.bearerToken(keyID: raw.base64EncodedString(), assertion: Data([0xA1, 0x02])))
        XCTAssertEqual(Data(base64Encoded: token), raw + Data([0xA1, 0x02]))
        XCTAssertNil(AppAttestClient.bearerToken(keyID: Data([1, 2, 3]).base64EncodedString(), assertion: Data()),
                     "a key ID is a 32-byte hash")
    }

    func testDebugBuildsWithoutAppAttestSendNoAssertion() async throws {
        try XCTSkipIf(DCAppAttestService.shared.isSupported, "a device with App Attest")
        // The test bundle has no SSDevToken, so nothing is added; a Debug build with one sends X-Dev-Token.
        let headers = try await AppAttestClient(origin: nil, bundleID: "com.smartschedule.tests").headers(for: Data())
        XCTAssertEqual(headers, [:])
    }

    // MARK: The notification extension's session

    /// App Attest does not work in app extensions: the extension sends the session the app got for it.
    func testTheExtensionSendsItsSessionAndNeverAttests() async throws {
        let clock = TestNow(Date(timeIntervalSince1970: 1_800_000_000))
        let store = MemorySessionStore(ServerSession(token: "tok", expiresAt: clock.now.addingTimeInterval(86_400)))
        let client = AppAttestClient(origin: URL(string: "https://ss.example.dev"), bundleID: "com.smartschedule.tests.ext",
                                     isExtension: true, sessions: store, now: { clock.now })
        let headers = try await client.headers(for: Data("{}".utf8))
        XCTAssertEqual(headers, ["Authorization": "Session tok"])

        // Expired: not sent. (Release throws sessionMissing, "Open Smart Schedules once…"; this Debug test bundle
        // has no SSDevToken, so nothing is added.)
        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        let expired = try await client.headers(for: Data())
        XCTAssertEqual(expired, [:])

        // The extension never asks for a session itself.
        await client.refreshSessionIfNeeded(consented: true)
        XCTAssertTrue(ProxyStub.requests.isEmpty)
    }

    func testARefusedSessionIsForgotten() async throws {
        let store = MemorySessionStore(ServerSession(token: "tok", expiresAt: .distantFuture))
        let client = AppAttestClient(origin: URL(string: "https://ss.example.dev"), session: stubSession(),
                                     bundleID: "com.smartschedule.tests.ext", isExtension: true, sessions: store)
        ProxyStub.respond([(401, #"{"error":"invalid_session"}"#), (401, #"{"error":"invalid_session"}"#)])
        let (_, response) = try await AttestedRequest.send(URLRequest(url: URL(string: "https://ss.example.dev/v1beta/x")!),
                                                            body: Data("{}".utf8), attestation: client, session: stubSession())
        XCTAssertEqual(response?.statusCode, 401)
        XCTAssertEqual(ProxyStub.requests.map { $0.headers["Authorization"] }, ["Session tok", nil])
        XCTAssertNil(store.load(), "the app gets a new one when it next runs")
    }

    func testTheAppRenewsTheExtensionsSessionBeforeItRunsOut() async throws {
        try XCTSkipIf(DCAppAttestService.shared.isSupported, "a device with App Attest would attest for real")
        let clock = TestNow(Date(timeIntervalSince1970: 1_800_000_000)) // 2027-01-15 08:00 UTC
        let store = MemorySessionStore(nil)
        let client = AppAttestClient(origin: URL(string: "https://ss.example.dev"), session: stubSession(),
                                     bundleID: "com.smartschedule.tests", isExtension: false, sessions: store,
                                     now: { clock.now })
        ProxyStub.respond([(200, #"{"token":"t1","expiresAt":"2027-01-22T08:00:00Z"}"#),
                           (200, #"{"token":"t2","expiresAt":"2027-01-26T09:00:00Z"}"#)])

        await client.refreshSessionIfNeeded(consented: false)
        XCTAssertTrue(ProxyStub.requests.isEmpty, "nothing goes to the server without AI consent")

        await client.refreshSessionIfNeeded(consented: true)
        XCTAssertEqual(ProxyStub.requests.map(\.url), ["https://ss.example.dev/session"])
        XCTAssertEqual(store.load(), ServerSession(token: "t1", expiresAt: Date(timeIntervalSince1970: 1_800_604_800)))

        clock.now = Date(timeIntervalSince1970: 1_800_000_000 + 3 * 86_400) // 4 days left
        await client.refreshSessionIfNeeded(consented: true)
        XCTAssertEqual(ProxyStub.requests.count, 1, "more than 3 days left: kept")

        clock.now = Date(timeIntervalSince1970: 1_800_000_000 + 4 * 86_400 + 3_600) // under 3 days left
        await client.refreshSessionIfNeeded(consented: true)
        XCTAssertEqual(ProxyStub.requests.count, 2)
        XCTAssertEqual(store.load()?.token, "t2")

        await client.forgetAll()
        XCTAssertNil(store.load())
    }

    // MARK: Push-to-start upload (iOS 18, AppConstants.pushToStartEnabled)

    private let flight = PushToStartRegistrar.Event(eventID: "e1", title: "Flight", eventStart: Date(timeIntervalSince1970: 1_800_003_600),
                                                    leadTime: 30, triggerAt: Date(timeIntervalSince1970: 1_800_001_800),
                                                    attributesJSON: #"{"eventID":"e1"}"#, contentStateJSON: "{}")

    /// A registration file and App Group stand-in of its own, holding `events` with a push token.
    private func registration(_ name: String, events: [PushToStartRegistrar.Event],
                              token: Data? = Data([0x01])) async throws -> (URL, UserDefaults) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("p2s-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GeminiProxyTests.\(name)"))
        defaults.removePersistentDomain(forName: "GeminiProxyTests.\(name)")
        await PushToStartRegistrar.sync(token: token, upcomingEvents: events, fileURL: file, defaults: defaults)
        return (file, defaults)
    }

    /// Version 1.0 (`AppConstants.pushToStartEnabled` false): the app installs no uploader, so even a registration an
    /// earlier build left on this iPhone never goes up, with consent or without, and nothing waits to be retried.
    func testWithPushToStartOffNothingIsUploaded() async throws {
        let (file, defaults) = try await registration("off", events: [flight])
        let uploads = UploadRecorder()
        addTeardownBlock { PushToStartRegistrar.install(enabled: false) { _ in false } }

        PushToStartRegistrar.install(enabled: false, upload: uploads.accept)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, fileURL: file, defaults: defaults)
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false, fileURL: file, defaults: defaults)
        XCTAssertTrue(uploads.sent.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: PushToStartRegistrar.uploadPendingKey))
        XCTAssertFalse(defaults.bool(forKey: PushToStartRegistrar.serverHasEventsKey))

        // The same calls reach the uploader once it is installed with push-to-start on (a later version).
        PushToStartRegistrar.install(enabled: true, upload: uploads.accept)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.map { $0.events.count }, [1])

        // Turned off again, the uploader is gone: withdrawing consent cannot reach the server either.
        PushToStartRegistrar.install(enabled: false, upload: uploads.accept)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 1)
    }

    /// "Erase all data" with push-to-start off: what an earlier build left in the App Group (the registration and its
    /// flags) goes without any request, so it works offline.
    func testForgetLocallyRemovesTheRegistrationWithoutARequest() async throws {
        let (file, defaults) = try await registration("forget", events: [flight])
        defaults.set(true, forKey: PushToStartRegistrar.serverHasEventsKey)
        defaults.set(true, forKey: PushToStartRegistrar.uploadPendingKey)
        XCTAssertNotNil(PushToStartRegistrar.pending(fileURL: file))

        await PushToStartRegistrar.forgetLocally(fileURL: file, defaults: defaults)
        XCTAssertNil(PushToStartRegistrar.pending(fileURL: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.object(forKey: PushToStartRegistrar.serverHasEventsKey))
        XCTAssertNil(defaults.object(forKey: PushToStartRegistrar.uploadPendingKey))
        XCTAssertTrue(ProxyStub.requests.isEmpty, "no request")
    }

    func testTheRegistrationIsUploadedOnlyWithConsentAndClearedWhenItIsWithdrawn() async throws {
        let (file, defaults) = try await registration("upload", events: [flight])
        let uploads = UploadRecorder()

        // No consent, nothing on the server yet: nothing leaves the iPhone.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertTrue(uploads.sent.isEmpty)

        // Consent: the registration as it is.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.last?.events.map(\.eventID), ["e1"])
        XCTAssertNotNil(uploads.sent.last?.token)

        // Unchanged and accepted: not sent again.
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 1)

        // Consent withdrawn: an empty registration clears the titles on the server, once, and the push token too.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 2)
        XCTAssertEqual(uploads.sent.last?.events, [])
        XCTAssertNil(uploads.sent.last?.token)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 2)
    }

    /// The consent switch changes nothing in the registration file, yet the server must get or lose the events.
    func testAConsentChangeAloneUploadsOrClears() async throws {
        let (file, defaults) = try await registration("consent", events: [flight])
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertTrue(uploads.sent.isEmpty)

        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.map { $0.events.count }, [1], "consent given: the events go up")

        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.map { $0.events.count }, [1, 0], "consent withdrawn: the server forgets them")
    }

    /// The server may have stored events whose answer never arrived: withdrawing consent still clears them.
    func testEventsSentWithoutAnAnswerAreStillCleared() async throws {
        let (file, defaults) = try await registration("lost", events: [flight])
        let lost = UploadRecorder(accepting: false)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: lost.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(lost.sent.count, 1)

        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.map(\.events), [[]])
    }

    func testAFailedUploadIsTriedAgain() async throws {
        let (file, defaults) = try await registration("retry", events: [flight])
        let failing = UploadRecorder(accepting: false)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: failing.accept, fileURL: file, defaults: defaults)
        let working = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: true, upload: working.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(working.sent.count, 1, "the failed upload is retried although nothing changed")
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: true, upload: working.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(working.sent.count, 1)
    }

    /// The token only goes up with events: the upload that clears the last of them takes the token away too, so
    /// withdrawing consent or erasing afterwards finds nothing left on the server.
    func testThePushTokenNeverStaysOnTheServerWithoutEvents() async throws {
        let (file, defaults) = try await registration("token-only", events: [flight])
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertNotNil(uploads.sent.last?.token)

        let changed = await PushToStartRegistrar.sync(token: Data([0x01]), upcomingEvents: [], fileURL: file, defaults: defaults)
        await PushToStartRegistrar.uploadIfNeeded(changed: changed, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 2)
        XCTAssertEqual(uploads.sent.last?.events, [])
        XCTAssertNil(uploads.sent.last?.token)

        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        await PushToStartRegistrar.eraseAll(upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 2, "nothing left on the server to clear")
    }

    func testNoTitlesGoUpBeforeIOSHandsOutAPushToken() async throws {
        let (file, defaults) = try await registration("notoken", events: [flight], token: nil)
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertTrue(uploads.sent.isEmpty, "the server could not start anything with them")
    }

    func testEraseAllClearsTheServerThenForgetsTheRegistration() async throws {
        let (file, defaults) = try await registration("erase", events: [flight])
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        let deviceID = try XCTUnwrap(uploads.sent.last?.deviceID)

        await PushToStartRegistrar.eraseAll(upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.last?.events, [])
        XCTAssertNil(uploads.sent.last?.token)
        XCTAssertEqual(uploads.sent.last?.deviceID, deviceID)
        XCTAssertNil(PushToStartRegistrar.pending(fileURL: file))
        await PushToStartRegistrar.sync(token: Data([0x01]), upcomingEvents: [], fileURL: file, defaults: defaults)
        XCTAssertNotEqual(PushToStartRegistrar.pending(fileURL: file)?.deviceID, deviceID, "a new install ID")
    }

    func testEraseAllOfflineClearsTheServerOnTheNextRun() async throws {
        let (file, defaults) = try await registration("erase-offline", events: [flight])
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        let deviceID = try XCTUnwrap(uploads.sent.last?.deviceID)

        await PushToStartRegistrar.eraseAll(upload: UploadRecorder(accepting: false).accept, fileURL: file, defaults: defaults)
        let left = try XCTUnwrap(PushToStartRegistrar.pending(fileURL: file))
        XCTAssertEqual(left.events, [])
        XCTAssertNil(left.token)
        XCTAssertEqual(left.deviceID, deviceID, "kept, so the next run clears the same registration")

        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.last?.events, [])
        XCTAssertEqual(uploads.sent.last?.deviceID, deviceID)
        XCTAssertEqual(uploads.sent.count, 2)
    }

    /// An upload already sending titles finishes before "Erase all data" clears the server, so it cannot store them
    /// again afterwards.
    func testEraseWaitsForAnUploadAlreadyUnderWay() async throws {
        let (file, defaults) = try await registration("erase-race", events: [flight])
        let gate = UploadGate()
        let first = Task {
            await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: gate.upload, fileURL: file, defaults: defaults)
        }
        for _ in 0..<200 where gate.sent.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(gate.sent.count, 1, "the upload is under way")
        let erase = Task { await PushToStartRegistrar.eraseAll(upload: gate.upload, fileURL: file, defaults: defaults) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gate.sent.count, 1, "the erase waits for it")
        gate.open()
        await first.value
        await erase.value
        XCTAssertEqual(gate.sent.map { $0.events.count }, [1, 0], "cleared after the titles went up")
        XCTAssertNil(PushToStartRegistrar.pending(fileURL: file))
    }

    /// A background refresh that runs out of time cancels its upload, even one still queued behind another: it is
    /// not sent, and stays pending for the next run.
    func testACancelledUploadIsNotSentAndStaysPending() async throws {
        let (fileA, defaultsA) = try await registration("cancel-a", events: [flight])
        let (fileB, defaultsB) = try await registration("cancel-b", events: [flight])
        let gate = UploadGate()
        let first = Task {
            await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: gate.upload, fileURL: fileA, defaults: defaultsA)
        }
        for _ in 0..<200 where gate.sent.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let queued = UploadRecorder()
        let second = Task {
            await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: queued.accept, fileURL: fileB, defaults: defaultsB)
        }
        second.cancel()
        gate.open()
        await first.value
        await second.value
        XCTAssertTrue(queued.sent.isEmpty, "cancelled: not sent")
        XCTAssertTrue(defaultsB.bool(forKey: PushToStartRegistrar.uploadPendingKey), "retried on the next run")
        XCTAssertEqual(gate.sent.count, 1, "the upload already under way was not affected")
    }

    /// Pending is set before the upload: a process ended during it (suspended, then terminated) sends it again
    /// next time although the registration file no longer changes.
    func testAnUploadStaysPendingUntilTheServerAccepts() async throws {
        let (file, defaults) = try await registration("cut-short", events: [flight])
        let seen = UploadRecorder()
        let pendingDuringUpload = FlagProbe()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: { registration in
            pendingDuringUpload.value = defaults.bool(forKey: PushToStartRegistrar.uploadPendingKey)
            return await seen.accept(registration)
        }, fileURL: file, defaults: defaults)
        XCTAssertTrue(pendingDuringUpload.value, "marked before the upload, so an end mid-upload leaves it pending")
    }

    /// A backup restored to another iPhone brings the flags (App Group defaults) but not the registration file:
    /// that phone starts over under a new ID and leaves the old phone's registration alone.
    func testARestoredBackupStartsOverWithoutTouchingTheOldPhone() async throws {
        let (file, defaults) = try await registration("restore", events: [flight])
        let uploads = UploadRecorder()
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        let oldID = try XCTUnwrap(uploads.sent.last?.deviceID)
        try FileManager.default.removeItem(at: file) // excluded from the backup

        // iOS 26 on the new phone: nothing registered here, so nothing is cleared.
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 1)

        // iOS 18 on the new phone: a new ID; no clearing upload under the old one.
        await PushToStartRegistrar.sync(token: nil, upcomingEvents: [flight], fileURL: file, defaults: defaults)
        XCTAssertNotEqual(PushToStartRegistrar.pending(fileURL: file)?.deviceID, oldID)
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 1)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyStub.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Test doubles

private actor FakeAttestation: AttestationProviding {
    private(set) var bodies: [Data] = []
    private(set) var resets = 0

    func headers(for body: Data) async throws -> [String: String] {
        bodies.append(body)
        return ["Authorization": "Bearer test-\(bodies.count)"]
    }

    func reset() async { resets += 1 }
}

private final class MemorySessionStore: SessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ServerSession?

    init(_ session: ServerSession?) { self.session = session }

    func load() -> ServerSession? { lock.withLock { session } }
    func save(_ session: ServerSession?) { lock.withLock { self.session = session } }
}

/// Holds the first upload until `open()`; later ones go straight through.
private final class UploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [PushToStartRegistrar.Registration] = []
    private var isOpen = false
    private var blocked: CheckedContinuation<Void, Never>?

    var sent: [PushToStartRegistrar.Registration] { lock.withLock { registrations } }

    var upload: @Sendable (PushToStartRegistrar.Registration) async -> Bool {
        { [self] registration in
            let holds = lock.withLock { () -> Bool in
                registrations.append(registration)
                return registrations.count == 1 && !isOpen
            }
            if holds {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        if isOpen { return true }
                        blocked = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            return true
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            defer { blocked = nil }
            return blocked
        }
        continuation?.resume()
    }
}

private final class FlagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// A clock a test moves forward.
private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class UploadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [PushToStartRegistrar.Registration] = []
    private let accepting: Bool

    init(accepting: Bool = true) { self.accepting = accepting }

    var sent: [PushToStartRegistrar.Registration] { lock.withLock { registrations } }

    var accept: @Sendable (PushToStartRegistrar.Registration) async -> Bool {
        { [self] registration in
            lock.withLock { registrations.append(registration) }
            return accepting
        }
    }
}

private final class ProxyStub: URLProtocol {
    static let okResponse = #"""
    {"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "reply_to_user", "args": {"text": "OK"}}}]}, "finishReason": "STOP"}]}
    """#

    struct Recorded {
        let url: String
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Recorded] = []
        var responses: [(Int, String, [String: String])] = []
    }

    private static let state = State()

    static var requests: [Recorded] { state.lock.withLock { state.requests } }
    static func respond(_ responses: [(Int, String)]) { respond(responses.map { ($0.0, $0.1, [:]) }) }
    /// With response headers (Retry-After).
    static func respond(_ responses: [(Int, String, [String: String])]) { state.lock.withLock { state.responses = responses } }
    static func reset() { state.lock.withLock { state.requests = []; state.responses = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET",
                                headers: request.allHTTPHeaderFields ?? [:], body: Self.bodyData(of: request))
        let (status, body, headers) = Self.state.lock.withLock { () -> (Int, String, [String: String]) in
            Self.state.requests.append(recorded)
            return Self.state.responses.isEmpty ? (500, "{}", [:]) : Self.state.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Type": "application/json"]) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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
