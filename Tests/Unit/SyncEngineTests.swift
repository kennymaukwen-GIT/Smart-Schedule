import XCTest

/// The engine and the router against a scripted stand-in for Google: demo mode never reaches it; a change made
/// offline is shown at once and sent later in one request; a queued edit that meets a 412 is re-applied on top of
/// Google's copy; a reminder's event is fetched fresh.
final class SyncEngineTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let personal = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
    private let mapper = CalendarEventMapper(clock: TestClock.clock)

    override func setUpWithError() throws {
        // A hostless test bundle has no App Group: the status lives in a throwaway suite.
        suiteName = "SyncEngineTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        files.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let engine: SyncEngine
        let router: CalendarRouter
        let store: SharedStore
        let outbox: SyncOutbox
    }

    private func makeRig(demo: Bool, google: ScriptedGoogle) async -> Rig {
        let accounts = AccountStore(fileURL: files.url("SyncEngineTests-accounts"), isDemoMode: { demo },
                                    defaultCalendar: { nil })
        await accounts.upsert(SampleAccounts.account("111", email: "kenny@example.com"))
        let store = SharedStore(fileURL: files.url("SyncEngineTests-cache"), accounts: accounts)
        let outbox = SyncOutbox(fileURL: files.url("SyncEngineTests-outbox"))
        let tokens = GoogleTokenProvider(accounts: accounts)
        // No reminders: a hostless test bundle has no notification center.
        let engine = SyncEngine(store: store, accounts: accounts, outbox: outbox, tokens: tokens, transport: google,
                                statusDefaults: defaults, clock: TestClock.clock, isDemoMode: { demo }, onChange: {})
        let router = CalendarRouter(accounts: accounts, tokens: tokens, store: store, clock: TestClock.clock,
                                    transport: google, outbox: outbox)
        return Rig(engine: engine, router: router, store: store, outbox: outbox)
    }

    private func event(_ id: String, title: String = "Team sync", hour: Int = 14, etag: String? = nil) -> ScheduleEvent {
        var event = TestEvents.make(id: id, title: title, start: TestClock.local(2026, 10, 15, hour),
                                    end: TestClock.local(2026, 10, 15, hour + 1), calendar: personal)
        event.etag = etag
        return event
    }

    // MARK: Demo mode

    func testDemoModeNeverReachesGoogle() async {
        let google = ScriptedGoogle()
        let rig = await makeRig(demo: true, google: google)
        let cached = event("e1", etag: "\"1\"")
        await rig.store.upsert([cached])
        await rig.outbox.enqueue(OutboxItem(kind: .delete, calendar: personal, eventID: "e1", etag: "\"1\"", title: "Team sync"))

        let report = await rig.engine.sync(.pull)
        let sent = await rig.engine.flushOutbox()
        let fresh = await rig.engine.freshEvent(cached.ref)
        await rig.engine.retry(UUID())

        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(report.sent, 0)
        XCTAssertFalse(report.changed)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(fresh, .unavailable)
        // Kept for when demo mode ends; the status says demo.
        let waiting = await rig.outbox.pending()
        XCTAssertEqual(waiting.count, 1)
        let status = SyncStatusStore.current(in: defaults)
        XCTAssertTrue(status.isDemo)
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertFalse(status.isOffline)
    }

    // MARK: Offline, then back online

    func testAChangeMadeOfflineIsShownAtOnceAndSentLaterInOneRequest() async throws {
        let google = ScriptedGoogle()
        await google.setOffline(true)
        let rig = await makeRig(demo: false, google: google)
        let target = try await rig.router.defaultTarget()

        var body = GCalEvent()
        body.id = "sslunch"
        body.summary = "Lunch"
        body.start = GCalDateTime(dateTime: "2026-10-15T13:00:00", timeZone: "Europe/London")
        body.end = GCalDateTime(dateTime: "2026-10-15T14:00:00", timeZone: "Europe/London")
        let shown = try await rig.router.insert([MappedEvent(body: body, wantsConference: false)], into: target,
                                                mapper: mapper, now: TestClock.utc(2026, 10, 14, 9))
        XCTAssertEqual(shown.map(\.isWaitingToSync), [true])
        var cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.filter(\.isWaitingToSync).map(\.id), ["sslunch"])

        // Renamed while still offline: folded into the queued create.
        var rename = GCalEvent()
        rename.summary = "Lunch with Andrew"
        let renamed = try await rig.router.patch(shown[0], body: rename, mapper: mapper)
        XCTAssertEqual(renamed?.title, "Lunch with Andrew")
        var queue = await rig.outbox.pending()
        XCTAssertEqual(queue.map(\.kind), [.insert])
        XCTAssertEqual(queue.first?.body?.summary, "Lunch with Andrew")
        let offlineRequests = await google.requests
        XCTAssertTrue(offlineRequests.isEmpty)

        // Back online: one POST with the latest body, then the listing.
        await google.setOffline(false)
        let saved = #"{"id":"sslunch","status":"confirmed","etag":"\"1\"","summary":"Lunch with Andrew","start":{"dateTime":"2026-10-15T13:00:00+01:00"},"end":{"dateTime":"2026-10-15T14:00:00+01:00"}}"#
        await google.on("POST", "/events", [(200, saved)])
        await google.on("GET", "/events", [(200, #"{"items":["# + saved + "]}")])

        let report = await rig.engine.sync(.network)
        XCTAssertEqual(report.sent, 1)
        XCTAssertEqual(report.pulledAccounts, 1)
        queue = await rig.outbox.pending()
        XCTAssertTrue(queue.isEmpty)
        let posts = await google.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        let posted = try XCTUnwrap(posts.first?.json)
        XCTAssertEqual(posted["summary"] as? String, "Lunch with Andrew")
        XCTAssertEqual(posted["id"] as? String, "sslunch")

        cached = await rig.store.snapshot().events
        let lunch = try XCTUnwrap(cached.first { $0.id == "sslunch" })
        XCTAssertFalse(lunch.isWaitingToSync)
        XCTAssertEqual(lunch.etag, "\"1\"")
        let status = SyncStatusStore.current(in: defaults)
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertNotNil(status.lastSuccess["111"])
        XCTAssertFalse(status.isOffline)
        XCTAssertNil(status.lastError)
    }

    func testCreatingThenDeletingOfflineLeavesNothingToSend() async throws {
        let google = ScriptedGoogle()
        await google.setOffline(true)
        let rig = await makeRig(demo: false, google: google)
        let target = try await rig.router.defaultTarget()
        var body = GCalEvent()
        body.id = "ssdentist"
        body.summary = "Dentist"
        body.start = GCalDateTime(dateTime: "2026-10-16T10:00:00", timeZone: "Europe/London")
        body.end = GCalDateTime(dateTime: "2026-10-16T10:30:00", timeZone: "Europe/London")
        let shown = try await rig.router.insert([MappedEvent(body: body, wantsConference: false)], into: target,
                                                mapper: mapper, now: TestClock.utc(2026, 10, 14, 9))

        let queued = try await rig.router.delete([shown[0].ref])
        XCTAssertTrue(queued)
        let queue = await rig.outbox.items()
        XCTAssertTrue(queue.isEmpty)
        let cached = await rig.store.snapshot().events
        XCTAssertFalse(cached.contains { $0.id == "ssdentist" })
        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: Conflicts

    func testAQueuedEditThatMeetsAConflictIsReappliedOnGooglesCopy() async throws {
        let google = ScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let seen = event("e1", etag: "\"1\"")
        await rig.store.upsert([seen])
        var rename = GCalEvent()
        rename.summary = "Team sync (moved)"
        await rig.outbox.enqueue(OutboxItem(kind: .patch, calendar: personal, eventID: "e1", body: rename,
                                            etag: "\"1\"", base: seen, title: "Team sync"))

        let conflict = #"{"error":{"code":412,"message":"Precondition Failed","errors":[{"reason":"conditionNotMet"}]}}"#
        let current = #"{"id":"e1","status":"confirmed","etag":"\"2\"","summary":"Team sync","location":"Room 4","start":{"dateTime":"2026-10-15T14:00:00+01:00"},"end":{"dateTime":"2026-10-15T15:00:00+01:00"}}"#
        let saved = #"{"id":"e1","status":"confirmed","etag":"\"3\"","summary":"Team sync (moved)","location":"Room 4","start":{"dateTime":"2026-10-15T14:00:00+01:00"},"end":{"dateTime":"2026-10-15T15:00:00+01:00"}}"#
        await google.on("PATCH", "/events/e1", [(412, conflict), (200, saved)])
        await google.on("GET", "/events/e1", [(200, current)])
        await google.on("GET", "/events", [(200, #"{"items":["# + saved + "]}")])

        let sent = await rig.engine.flushOutbox()
        XCTAssertEqual(sent, 1)
        let left = await rig.outbox.items()
        XCTAssertTrue(left.isEmpty)

        let patches = await google.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.map(\.ifMatch), ["\"1\"", "\"2\""])
        // The second PATCH carries only the rename: the room added in Google is not overwritten.
        let second = try XCTUnwrap(patches.last?.json)
        XCTAssertEqual(second["summary"] as? String, "Team sync (moved)")
        XCTAssertNil(second["location"])

        let cached = await rig.store.snapshot().events.first { $0.id == "e1" }
        XCTAssertEqual(cached?.title, "Team sync (moved)")
        XCTAssertEqual(cached?.location, "Room 4")
        XCTAssertEqual(cached?.etag, "\"3\"")
    }

    func testAnEditOfAnEventDeletedInGoogleGoesToTheFailedList() async throws {
        let google = ScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let seen = event("e1", etag: "\"1\"")
        await rig.store.upsert([seen])
        var rename = GCalEvent()
        rename.summary = "Renamed"
        let item = OutboxItem(kind: .patch, calendar: personal, eventID: "e1", body: rename, etag: "\"1\"", base: seen,
                              title: "Team sync")
        await rig.outbox.enqueue(item)
        let gone = #"{"error":{"code":404,"message":"Not Found","errors":[{"reason":"notFound"}]}}"#
        await google.on("PATCH", "/events/e1", [(404, gone)])

        let sent = await rig.engine.flushOutbox()
        XCTAssertEqual(sent, 0)
        let status = SyncStatusStore.current(in: defaults)
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failed.map(\.id), [item.id])
        XCTAssertEqual(status.failed.first?.reason, "It was deleted in Google Calendar.")

        await rig.engine.discard(item.id)
        let left = await rig.outbox.items()
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(SyncStatusStore.current(in: defaults).failed.isEmpty)
    }

    // MARK: A reminder's event

    func testAReminderSeesTheEventAsGoogleHasItNow() async throws {
        let google = ScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let moved = event("e1", etag: "\"1\"")
        let cancelled = event("e2", hour: 16, etag: "\"1\"")
        await rig.store.upsert([moved, cancelled])
        await google.on("GET", "/events/e1", [(200, #"{"id":"e1","status":"confirmed","etag":"\"2\"","summary":"Team sync","start":{"dateTime":"2026-10-15T16:00:00+01:00"},"end":{"dateTime":"2026-10-15T17:00:00+01:00"}}"#)])
        await google.on("GET", "/events/e2", [(200, #"{"id":"e2","status":"cancelled"}"#)])

        let first = await rig.engine.freshEvent(moved.ref)
        guard case let .moved(event) = first else { return XCTFail("expected moved, got \(first)") }
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 15, 16))
        let second = await rig.engine.freshEvent(cancelled.ref)
        XCTAssertEqual(second, .cancelled)

        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.map(\.id), ["e1"])
        XCTAssertEqual(cached.first?.start, TestClock.local(2026, 10, 15, 16))
    }
}

/// Answers Calendar API requests from a script, by method and path suffix, and records them. Offline, it fails like
/// a phone without a connection and records nothing (nothing left the device).
private actor ScriptedGoogle: CalendarTransport {
    struct Request: Sendable {
        let method: String
        let path: String
        let ifMatch: String?
        let body: Data?

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private(set) var requests: [Request] = []
    private var script: [String: [(status: Int, json: String)]] = [:]
    private var isOffline = false

    func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    /// Responses in order; the last one repeats.
    func on(_ method: String, _ pathSuffix: String, _ responses: [(status: Int, json: String)]) {
        script[method + " " + pathSuffix] = responses
    }

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        "test-token"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        requests.append(Request(method: method, path: path, ifMatch: request.value(forHTTPHeaderField: "If-Match"),
                                body: request.httpBody))
        let keys = script.keys.filter { key in
            key.hasPrefix(method + " ") && path.hasSuffix(String(key.dropFirst(method.count + 1)))
        }
        var answer = (status: 404, json: #"{"error":{"code":404,"message":"Not Found","errors":[{"reason":"notFound"}]}}"#)
        if let key = keys.max(by: { $0.count < $1.count }), var queue = script[key], let next = queue.first {
            if queue.count > 1 { queue.removeFirst() }
            script[key] = queue
            answer = next
        }
        let url = request.url ?? URL(string: "https://www.googleapis.com")!
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Date": "Wed, 14 Oct 2026 09:00:00 GMT"])!
        return (Data(answer.json.utf8), response)
    }
}
