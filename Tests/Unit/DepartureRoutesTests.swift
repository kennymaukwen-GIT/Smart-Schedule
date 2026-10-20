import XCTest

/// 「該出發了」 routes from the Smart Schedules server (Shared/Departure/DepartureRoutes.swift and
/// WorkerDepartureRoutes.swift). The samples in Tests/fixtures/departure are shared with the server's own tests
/// (server/worker/test/departure.test.ts), so the two sides read and write the same thing.
final class DepartureRoutesTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    /// 2026-10-15 08:00 UTC (16:00 in Taipei): the server tests' clock.
    private let now = Date(timeIntervalSince1970: 1_792_051_200)

    private func sample(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.directory().appendingPathComponent("departure/\(name)"))
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func utc(_ text: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(text)
    }

    private var transitRequest: DepartureRouteRequest {
        DepartureRouteRequest(mode: .transit, origin: .current(GeoPoint(latitude: 25.047_761_9, longitude: 121.517_058_1)),
                              destination: "台北101", arriveBy: utc("2026-10-15T09:00:00Z"), plan: nil,
                              utcOffsetMinutes: 480, language: "zh-TW", region: "tw")
    }

    // MARK: Request

    func testTheClockMatchesTheServerTests() {
        XCTAssertEqual(now, utc("2026-10-15T08:00:00Z"))
    }

    func testTransitRequestIsTheSharedSample() throws {
        let body = try transitRequest.validated(now: now).body()
        XCTAssertEqual(try object(body), try object(sample("request.transit.json")))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("debugBuild"), "Release requests leave the flag out")
    }

    func testDriveRequestWithATypedStartIsTheSharedSample() throws {
        let request = DepartureRouteRequest(mode: .drive, origin: .typed("  台北車站 "), destination: "新竹科學園區",
                                            arriveBy: utc("2026-10-15T10:00:00Z"), plan: nil, utcOffsetMinutes: 480,
                                            language: "zh-TW", region: "tw", debugBuild: true)
        XCTAssertEqual(try object(request.validated(now: now).body()), try object(sample("request.drive.json")))
    }

    func testBodyLeavesOutWhatIsNotSetAndSortsItsKeys() throws {
        let request = DepartureRouteRequest(mode: .walk, origin: .typed("台北車站"), destination: "台北101", arriveBy: nil,
                                            plan: nil, utcOffsetMinutes: -300, language: nil, region: nil)
        let text = String(decoding: try request.validated(now: now).body(), as: UTF8.self)
        XCTAssertEqual(text, #"{"destination":{"address":"台北101"},"mode":"walk","origin":{"address":"台北車站"},"utcOffsetMinutes":-300}"#)
    }

    func testBodyCarriesAPlanTokenForARecheck() throws {
        var request = transitRequest
        request.plan = String(repeating: "A", count: 43)
        let json = try object(request.validated(now: now).body())
        XCTAssertEqual(json["plan"] as? String, String(repeating: "A", count: 43))
    }

    func testCoordinatesAreRoundedToFiveDecimals() throws {
        let json = try object(transitRequest.validated(now: now).body())
        let origin = try XCTUnwrap(json["origin"] as? [String: Double])
        XCTAssertEqual(origin["lat"] ?? 0, 25.04776, accuracy: 1e-9)
        XCTAssertEqual(origin["lng"] ?? 0, 121.51706, accuracy: 1e-9)
        XCTAssertEqual(DepartureRouteRequest.coordinate(-0.000_004_9), 0, accuracy: 1e-12)
    }

    func testPlacesAreFoldedToOneLine() throws {
        var request = transitRequest
        request.destination = "台北 101\n  信義路五段7號 "
        request.origin = .typed("\t台北車站\n")
        let checked = try request.validated(now: now)
        XCTAssertEqual(checked.destination, "台北 101, 信義路五段7號")
        XCTAssertEqual(checked.origin, .typed("台北車站"))
    }

    func testInvalidRequestsAreRefusedBeforeSending() {
        func refused(_ change: (inout DepartureRouteRequest) -> Void, line: UInt = #line) {
            var request = transitRequest
            change(&request)
            XCTAssertThrowsError(try request.validated(now: now), line: line) { error in
                XCTAssertEqual(error as? DepartureRouteError, .invalidRequest, line: line)
            }
        }
        refused { $0.destination = "  \n " }
        refused { $0.destination = String(repeating: "字", count: 201) }
        refused { $0.origin = .typed(" ") }
        refused { $0.origin = .current(GeoPoint(latitude: 91, longitude: 0)) }
        refused { $0.origin = .current(GeoPoint(latitude: .nan, longitude: 0)) }
        refused { $0.arriveBy = self.now.addingTimeInterval(-120) }
        refused { $0.arriveBy = self.now.addingTimeInterval(101 * 86_400) }
        refused { $0.plan = "short" }
        refused { $0.utcOffsetMinutes = 900 }
        var longest = transitRequest
        longest.destination = String(repeating: "字", count: 200)
        XCTAssertNoThrow(try longest.validated(now: now))
    }

    func testAMalformedLanguageOrRegionIsLeftOut() throws {
        var request = transitRequest
        request.language = "zh_TW"
        request.region = "TW"
        let json = try object(request.validated(now: now).body())
        XCTAssertNil(json["language"])
        XCTAssertNil(json["region"])
    }

    func testOffsetLanguageAndRegionFromTheIPhone() {
        XCTAssertEqual(DepartureRouteRequest.utcOffsetMinutes(taipei, at: now), 480)
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(DepartureRouteRequest.utcOffsetMinutes(london, at: now), 60, "summer time until 25 October")
        XCTAssertEqual(DepartureRouteRequest.utcOffsetMinutes(london, at: utc("2026-10-26T12:00:00Z")), 0)
        XCTAssertEqual(DepartureRouteRequest.utcOffsetMinutes(TimeZone(secondsFromGMT: 14 * 3600)!, at: now), 840)
        XCTAssertEqual(DepartureRouteRequest.languageCode(appLanguage: "zh-Hant"), "zh-TW")
        XCTAssertEqual(DepartureRouteRequest.languageCode(appLanguage: "en"), "en")
        XCTAssertEqual(DepartureRouteRequest.languageCode(appLanguage: nil), "en")
        XCTAssertEqual(DepartureRouteRequest.regionCode(isoRegion: "TW"), "tw")
        XCTAssertEqual(DepartureRouteRequest.regionCode(isoRegion: "GB"), "uk", "the UK's ccTLD")
        XCTAssertNil(DepartureRouteRequest.regionCode(isoRegion: "419"))
        XCTAssertNil(DepartureRouteRequest.regionCode(isoRegion: nil))
    }

    func testModesAsTheServerKnowsThem() {
        XCTAssertEqual(RouteMode.allCases.map(\.rawValue), ["transit", "drive", "walk", "two_wheeler"])
        XCTAssertEqual(TravelMode.allCases.map(RouteMode.init), [.transit, .drive, .walk])
    }

    // MARK: Answer

    func testReadsTheServersTransitAnswer() throws {
        let result = try DepartureRouteReader.result(status: 200, body: sample("response.transit.json"), retryAfter: nil)
        guard case let .route(route) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(route.mode, .transit)
        XCTAssertEqual(route.departAt, utc("2026-10-15T08:31:00Z"))
        XCTAssertEqual(route.arriveAt, utc("2026-10-15T08:50:00Z"))
        XCTAssertFalse(route.late)
        XCTAssertFalse(route.estimate)
        XCTAssertEqual(route.plan, String(repeating: "A", count: 43))
        XCTAssertEqual(route.plansLeft, 1)

        let summary = route.summary
        XCTAssertEqual(summary.durationText, "25 分鐘")
        XCTAssertEqual(summary.distanceText, "5.4 公里")
        XCTAssertEqual(summary.fareText, "NT$25")
        XCTAssertEqual(summary.durationSeconds, 1500)
        XCTAssertEqual(summary.distanceMeters, 5370)
        XCTAssertEqual(summary.segments.count, 3)

        XCTAssertEqual(summary.segments[0], RouteSegment(kind: .walk, seconds: 300, meters: 350, instructions: ["步行至台北車站"]))
        let ride = TransitRide(lineName: "淡水信義線", lineShortName: "R", vehicleType: "SUBWAY", vehicleName: "捷運",
                               headsign: "象山", agency: "臺北大眾捷運股份有限公司", color: "#e3002c", textColor: "#ffffff",
                               departureStop: "台北車站", arrivalStop: "台北101/世貿",
                               departureTime: utc("2026-10-15T08:36:00Z"), arrivalTime: utc("2026-10-15T08:46:00Z"),
                               departureTimeText: "下午4:36", arrivalTimeText: "下午4:46", stopCount: 6)
        XCTAssertEqual(summary.segments[1], RouteSegment(kind: .transit(ride), seconds: 600, meters: 4700, instructions: ["捷運 往象山"]))
        XCTAssertEqual(summary.segments[2], RouteSegment(kind: .walk, seconds: 240, meters: 320,
                                                         instructions: ["往東走信義路五段", "目的地在左側"]),
                       "the two walking steps after the ride are one walk")
    }

    func testReadsTheServersDriveAnswer() throws {
        let result = try DepartureRouteReader.result(status: 200, body: sample("response.drive.json"), retryAfter: nil)
        guard case let .route(route) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(route.mode, .drive)
        XCTAssertEqual(route.departAt, utc("2026-10-15T08:50:00Z"))
        XCTAssertEqual(route.arriveAt, utc("2026-10-15T10:00:00Z"))
        XCTAssertEqual(route.plansLeft, 19)
        XCTAssertEqual(route.summary.description, "國道1號")
        XCTAssertEqual(route.summary.warnings, ["此路線有收費路段"])
        XCTAssertEqual(route.summary.durationText, "1 小時 10 分鐘")
        XCTAssertEqual(route.summary.segments, [
            RouteSegment(kind: .drive, seconds: 3900, meters: 72_100,
                         instructions: ["往西北走忠孝西路一段", "走國道1號", "右轉進入園區二路\n目的地在右側"]),
        ])
    }

    func testReadsNoRouteAndPlacesNotFound() throws {
        func read(_ json: String) throws -> DepartureRouteResult {
            try DepartureRouteReader.result(status: 200, body: Data(json.utf8), retryAfter: nil)
        }
        XCTAssertEqual(try read(#"{"result":"no_route","plansLeft":2}"#), .noRoute(plansLeft: 2))
        XCTAssertEqual(try read(#"{"result":"place_not_found","place":"origin","plansLeft":2}"#), .placeNotFound(.start, plansLeft: 2))
        XCTAssertEqual(try read(#"{"result":"place_not_found","place":"destination","plansLeft":0}"#),
                       .placeNotFound(.destination, plansLeft: 0))
    }

    func testAnAnswerThatMakesNoSenseIsUnavailable() {
        for body in [#"{"result":"ok","mode":"transit","arriveAt":"2026-10-15T08:50:00Z"}"#,
                     #"{"result":"ok","mode":"fly","departAt":"2026-10-15T08:31:00Z","arriveAt":"2026-10-15T08:50:00Z"}"#,
                     #"{"result":"maybe"}"#, "not json", "[]"] {
            XCTAssertThrowsError(try DepartureRouteReader.result(status: 200, body: Data(body.utf8), retryAfter: nil), body) { error in
                XCTAssertEqual(error as? DepartureRouteError, .unavailable, body)
            }
        }
    }

    func testAMissingRouteOrABadTokenStillReadsTheTimes() throws {
        let json = #"{"result":"ok","mode":"walk","departAt":"2026-10-15T08:31:00Z","arriveAt":"2026-10-15T08:50:00Z","plan":"x","plansLeft":1}"#
        guard case let .route(route) = try DepartureRouteReader.result(status: 200, body: Data(json.utf8), retryAfter: nil) else {
            return XCTFail("no route")
        }
        XCTAssertNil(route.plan, "a malformed token is dropped: a recheck would be refused")
        XCTAssertEqual(route.summary, RouteSummary(warnings: [], segments: []))
    }

    func testEveryRefusalHasItsMeaning() {
        let cases: [(Int, String?, DepartureRouteError)] = [
            (403, "region_unavailable", .regionUnavailable),
            (429, "weekly_limit", .weeklyLimit(retryAfter: 3600)),
            (429, "recheck_limit", .recheckLimit),
            (403, "invalid_plan", .invalidPlan),
            (429, "capacity_reached", .dailyCapacity(retryAfter: 3600)),
            (429, "user_daily_limit", .userDailyLimit(retryAfter: 3600)),
            (429, "rate_limited", .busy(retryAfter: 3600)),
            (503, "server_busy", .busy(retryAfter: 3600)),
            (500, "server_misconfigured", .notReady),
            (400, "invalid_request", .invalidRequest),
            (413, "payload_too_large", .invalidRequest),
            (401, "attestation_required", .unverified),
            (401, "unknown_key", .unverified),
            (401, "invalid_attestation", .unverified),
            (502, "upstream_unavailable", .unavailable),
            (404, "not_found", .notReady),
            (405, "method_not_allowed", .notReady),
            (500, "internal_error", .unavailable),
            (503, nil, .busy(retryAfter: 3600)),
            (502, nil, .unavailable),
        ]
        for (status, code, expected) in cases {
            let body = code.map { #"{"error":"\#($0)"}"# } ?? "<html>"
            XCTAssertThrowsError(try DepartureRouteReader.result(status: status, body: Data(body.utf8), retryAfter: 3600)) { error in
                XCTAssertEqual(error as? DepartureRouteError, expected, "\(status) \(code ?? "-")")
            }
        }
    }

    func testAttestationFailuresHaveTheirMeaning() {
        XCTAssertEqual(DepartureRouteReader.error(attestation: .unsupported), .unverified)
        XCTAssertEqual(DepartureRouteReader.error(attestation: .deviceCheck(code: 3)), .unverified)
        XCTAssertEqual(DepartureRouteReader.error(attestation: .attestationRejected), .unverified)
        XCTAssertEqual(DepartureRouteReader.error(attestation: .notConfigured), .notReady)
        XCTAssertEqual(DepartureRouteReader.error(attestation: .serverNotReady), .notReady)
        XCTAssertEqual(DepartureRouteReader.error(attestation: .rateLimited), .busy(retryAfter: nil))
        XCTAssertEqual(DepartureRouteReader.error(attestation: .dailyLimit), .userDailyLimit(retryAfter: nil),
                       "a network's daily cap on new installs lasts until tomorrow, not a moment")
        XCTAssertEqual(DepartureRouteReader.error(attestation: .server(status: 500)), .unavailable)
    }

    func testErrorsNeverTellGeminiWhy() {
        let reasons: [DepartureRouteError] = [.regionUnavailable, .weeklyLimit(retryAfter: 1), .unavailable, .invalidPlan]
        let descriptions = Set(reasons.map { ($0 as NSError).localizedDescription })
        XCTAssertEqual(descriptions.count, 1)
        XCTAssertEqual((DepartureRouteError.regionUnavailable as NSError).code, 0)
    }

    func testValuesGoogleWritesInItsOwnWays() {
        XCTAssertEqual(DepartureRouteReader.seconds("1234s"), 1234)
        XCTAssertEqual(DepartureRouteReader.seconds("12.5s"), 12)
        XCTAssertNil(DepartureRouteReader.seconds("12m"))
        XCTAssertNil(DepartureRouteReader.seconds(12))
        XCTAssertEqual(DepartureRouteReader.int(NSNumber(value: 72_100)), 72_100)
        XCTAssertEqual(DepartureRouteReader.int("72100"), 72_100, "int64 as a string")
        XCTAssertNil(DepartureRouteReader.int(NSNumber(value: true)))
        XCTAssertNil(DepartureRouteReader.int(NSNumber(value: -1)))
        XCTAssertNil(DepartureRouteReader.int(NSNumber(value: 1.5)))
        XCTAssertEqual(DepartureRouteReader.date("2026-10-15T08:36:00Z"), utc("2026-10-15T08:36:00Z"))
        XCTAssertEqual(DepartureRouteReader.date("2026-10-15T08:36:00.250Z")?.timeIntervalSince(utc("2026-10-15T08:36:00Z")) ?? -1,
                       0.25, accuracy: 0.001)
        XCTAssertNil(DepartureRouteReader.date("tomorrow"))
    }

    // MARK: Sending

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouteStub.self]
        return URLSession(configuration: configuration)
    }

    private func client(_ attestation: AttestationProviding = SigningAttestation(), origin: URL? = URL(string: "https://worker.test")) -> WorkerDepartureRoutes {
        let clock = now
        return WorkerDepartureRoutes(origin: origin, attestation: attestation, session: stubSession(), now: { clock })
    }

    override func setUp() {
        super.setUp()
        RouteStub.reset()
    }

    func testSendsTheSignedBodyToTheRoute() async throws {
        RouteStub.respond([(200, String(decoding: try sample("response.transit.json"), as: UTF8.self), [:])])
        let attestation = SigningAttestation()
        let result = try await client(attestation).route(transitRequest)
        guard case .route = result else { return XCTFail("\(result)") }

        let sent = try XCTUnwrap(RouteStub.requests.first)
        XCTAssertEqual(RouteStub.requests.count, 1)
        XCTAssertEqual(sent.url, "https://worker.test/v1/departure/routes")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer test-1")
        let signed = await attestation.bodies
        XCTAssertEqual(signed, [sent.body], "the assertion signs exactly the bytes sent")
        XCTAssertEqual(sent.body, try transitRequest.validated(now: now).body())
    }

    func testARefusalComesBackWithItsRetryAfter() async throws {
        RouteStub.respond([(429, #"{"error":"weekly_limit"}"#, ["Retry-After": "288000"])])
        do {
            _ = try await client().route(transitRequest)
            XCTFail("no refusal")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .weeklyLimit(retryAfter: 288_000))
        }
    }

    func testAnOlderServerWithoutTheRouteIsNotReady() async throws {
        RouteStub.respond([(404, #"{"error":"not_found"}"#, [:])])
        do {
            _ = try await client().route(transitRequest)
            XCTFail("no refusal")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .notReady)
        }
    }

    func testNothingIsSentForAnInvalidRequestOrWithoutAServer() async {
        var request = transitRequest
        request.destination = " "
        do {
            _ = try await client().route(request)
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .invalidRequest)
        }
        do {
            _ = try await client(origin: nil).route(transitRequest)
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .notReady)
        }
        XCTAssertTrue(RouteStub.requests.isEmpty)
    }

    func testADeviceThatCantProveTheAppIsUnverified() async {
        do {
            _ = try await client(FailingAttestation()).route(transitRequest)
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .unverified)
        }
        XCTAssertTrue(RouteStub.requests.isEmpty)
    }

    func testANetworkFailureIsUnavailable() async {
        RouteStub.failNext(URLError(.notConnectedToInternet))
        do {
            _ = try await client().route(transitRequest)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? DepartureRouteError, .unavailable)
        }
    }

    func testAForgottenKeyIsRetriedOnceWithAFreshAssertion() async throws {
        RouteStub.respond([(401, #"{"error":"unknown_key"}"#, [:]),
                           (200, #"{"result":"no_route","plansLeft":2}"#, [:])])
        let attestation = SigningAttestation()
        let result = try await client(attestation).route(transitRequest)
        XCTAssertEqual(result, .noRoute(plansLeft: 2))
        XCTAssertEqual(RouteStub.requests.count, 2)
        let resets = await attestation.resets
        XCTAssertEqual(resets, 1)
    }
}

// MARK: - Test doubles

private actor SigningAttestation: AttestationProviding {
    private(set) var bodies: [Data] = []
    private(set) var resets = 0

    func headers(for body: Data) async throws -> [String: String] {
        bodies.append(body)
        return ["Authorization": "Bearer test-\(bodies.count)"]
    }

    func reset() async { resets += 1 }
}

private struct FailingAttestation: AttestationProviding {
    func headers(for body: Data) async throws -> [String: String] { throw AttestationError.unsupported }
    func reset() async {}
}

private final class RouteStub: URLProtocol {
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
        var failure: URLError?
    }

    private static let state = State()

    static var requests: [Recorded] { state.lock.withLock { state.requests } }
    static func respond(_ responses: [(Int, String, [String: String])]) { state.lock.withLock { state.responses = responses } }
    static func failNext(_ error: URLError) { state.lock.withLock { state.failure = error } }
    static func reset() { state.lock.withLock { state.requests = []; state.responses = []; state.failure = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET",
                                headers: request.allHTTPHeaderFields ?? [:], body: Self.bodyData(of: request))
        let (failure, reply) = Self.state.lock.withLock { () -> (URLError?, (Int, String, [String: String])) in
            Self.state.requests.append(recorded)
            defer { Self.state.failure = nil }
            return (Self.state.failure, Self.state.responses.isEmpty ? (500, "{}", [:]) : Self.state.responses.removeFirst())
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, body, headers) = reply
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
