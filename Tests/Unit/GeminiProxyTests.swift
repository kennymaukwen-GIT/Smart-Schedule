import DeviceCheck
import XCTest

/// Gemini requests go to Smart Schedule's server with App Attest headers and never an API key; the body the
/// assertion signs is exactly the body sent; the server's 401s get one fresh assertion (or a new key). The
/// notification extension sends a session the app renews; the iOS 18 push-to-start registration reaches the server
/// only with consent and is cleared when consent goes or the data is erased.
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
        // The body is Gemini's own: generationConfig as before, nothing added or removed.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["systemInstruction", "contents", "tools", "toolConfig", "generationConfig"])
        XCTAssertEqual((json["generationConfig"] as? [String: Any]).flatMap { $0["thinkingConfig"] as? [String: String] },
                       ["thinkingLevel": "low"])
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
        } catch GeminiError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ProxyStub.requests.count, 2)
    }

    func testGoogleItselfIsNeverCalledFromTheApp() async {
        let attestation = FakeAttestation()
        let direct = GeminiConfig(baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "test-model",
                                  apiKey: nil, thinkingLevel: nil)
        do {
            _ = try await client(attestation, config: direct).generate(system: "system", history: [.user("hi")])
            XCTFail("expected an error")
        } catch GeminiError.malformed {
            // expected: it would need an API key in the app
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(ProxyStub.requests.isEmpty)
        let signed = await attestation.bodies
        XCTAssertTrue(signed.isEmpty)
    }

    // MARK: Endpoint and token

    func testServerOriginComesFromTheBaseURL() {
        XCTAssertEqual(ServerEndpoint.origin(of: "https://ss.example.dev/v1beta"), URL(string: "https://ss.example.dev"))
        XCTAssertEqual(ServerEndpoint.origin(of: "http://localhost:8787/v1beta"), URL(string: "http://localhost:8787"))
        XCTAssertNil(ServerEndpoint.origin(of: "https://generativelanguage.googleapis.com/v1beta"))
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

        // Expired: not sent. (Release throws sessionMissing, "Open Smart Schedule once…"; this Debug test bundle
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

    // MARK: Push-to-start upload (iOS 18)

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

    func testTheRegistrationIsUploadedOnlyWithConsentAndClearedWhenItIsWithdrawn() async throws {
        let (file, defaults) = try await registration("upload", events: [flight])
        let uploads = UploadRecorder()

        // No consent, nothing on the server yet: nothing leaves the iPhone.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertTrue(uploads.sent.isEmpty)

        // Consent: the registration as it is.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.last?.events.map(\.eventID), ["e1"])

        // Unchanged and accepted: not sent again.
        await PushToStartRegistrar.uploadIfNeeded(changed: false, consented: true, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 1)

        // Consent withdrawn: an empty registration clears the titles on the server, once.
        await PushToStartRegistrar.uploadIfNeeded(changed: true, consented: false, upload: uploads.accept, fileURL: file, defaults: defaults)
        XCTAssertEqual(uploads.sent.count, 2)
        XCTAssertEqual(uploads.sent.last?.events, [])
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
        let headers: [String: String]
        let body: Data
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Recorded] = []
        var responses: [(Int, String)] = []
    }

    private static let state = State()

    static var requests: [Recorded] { state.lock.withLock { state.requests } }
    static func respond(_ responses: [(Int, String)]) { state.lock.withLock { state.responses = responses } }
    static func reset() { state.lock.withLock { state.requests = []; state.responses = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields ?? [:],
                                body: Self.bodyData(of: request))
        let (status, body) = Self.state.lock.withLock { () -> (Int, String) in
            Self.state.requests.append(recorded)
            return Self.state.responses.isEmpty ? (500, "{}") : Self.state.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
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
