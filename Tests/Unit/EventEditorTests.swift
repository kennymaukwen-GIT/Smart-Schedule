import XCTest

/// The event page's writes through `EventEditor`: demo mode edits the sample events and never reaches Google; online
/// edits PATCH with If-Match and update the cache; offline edits wait in the outbox, shown at once; a series edit
/// patches the master; read-only calendars and previews cannot be changed; deletes take one event or the series.
final class EventEditorTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let personal = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
    private let holidays = CalendarRef(accountID: "111", calendarID: "holidays-id")
    /// Wednesday 2026-10-14 09:00 BST.
    private let now = TestClock.local(2026, 10, 14, 9)

    override func setUpWithError() throws {
        // A hostless test bundle has no App Group: the sync status lives in a throwaway suite.
        suiteName = "EventEditorTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        files.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let editor: EventEditor
        let store: SharedStore
        let outbox: SyncOutbox
        let accounts: AccountStore
    }

    private func makeRig(demo: Bool, google: EditorScriptedGoogle) async -> Rig {
        let accounts = AccountStore(fileURL: files.url("EventEditorTests-accounts"), isDemoMode: { demo },
                                    defaultCalendar: { nil })
        let reader = SampleAccounts.calendar("111", "holidays-id", email: "kenny@example.com", name: "Holidays", role: "reader")
        await accounts.upsert(SampleAccounts.account("111", email: "kenny@example.com", extra: [reader]))
        let store = SharedStore(fileURL: files.url("EventEditorTests-cache"), accounts: accounts)
        let outbox = SyncOutbox(fileURL: files.url("EventEditorTests-outbox"))
        let editor = EventEditor(store: store, accounts: accounts, outbox: outbox,
                                 tokens: GoogleTokenProvider(accounts: accounts), transport: google,
                                 preferences: PreferencesStore(fileURL: files.url("EventEditorTests-prefs")),
                                 statusDefaults: defaults, clock: TestClock.clock, policy: ReminderPolicy(),
                                 isDemoMode: { demo }, rescheduleReminders: { _ in })
        return Rig(editor: editor, store: store, outbox: outbox, accounts: accounts)
    }

    private func event(_ id: String, title: String = "Team sync", start: Date, minutes: Int = 60,
                       calendar: CalendarRef, seriesID: String? = nil, etag: String? = nil) -> ScheduleEvent {
        var event = TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes) * 60),
                                    seriesID: seriesID, calendar: calendar)
        event.etag = etag
        return event
    }

    private func cached(_ store: SharedStore, _ id: String) async -> ScheduleEvent? {
        await store.snapshot().events.first { $0.id == id }
    }

    // MARK: Demo mode

    func testDemoModeEditsTheSampleEventsAndNeverReachesGoogle() async throws {
        let google = EditorScriptedGoogle()
        let rig = await makeRig(demo: true, google: google)
        let dentist = event("demo-dentist", title: "Dentist", start: TestClock.local(2026, 10, 16, 9, 30),
                            calendar: DemoData.personalCalendar)
        let yoga = [17, 24, 31].map { day in
            event("demo-yoga-2026-10-\(day)", title: "Yoga", start: TestClock.local(2026, 10, day, 9), calendar: DemoData.gymCalendar,
                  seriesID: "demo-yoga")
        }
        await rig.store.upsert([dentist] + yoga)

        let canEdit = await rig.editor.canEdit(dentist)
        XCTAssertTrue(canEdit)

        // One event: notes.
        let noted = try await rig.editor.update(dentist, with: EventEdit(notes: "Bring the forms"), scope: .thisEvent, now: now)
        XCTAssertEqual(noted.notes, "Bring the forms")
        let dentistNotes = await cached(rig.store, "demo-dentist")?.notes
        XCTAssertEqual(dentistNotes, "Bring the forms")

        // Every occurrence: a new title, an hour earlier, each on its own day.
        let edit = EventEdit(title: "Morning yoga", start: TestClock.local(2026, 10, 24, 8), end: TestClock.local(2026, 10, 24, 9))
        let moved = try await rig.editor.update(yoga[1], with: edit, scope: .allEvents, now: now)
        XCTAssertEqual(moved.id, "demo-yoga-2026-10-24")
        XCTAssertEqual(moved.start, TestClock.local(2026, 10, 24, 8))
        let series = await rig.store.snapshot().events.filter { $0.seriesID == "demo-yoga" }.sorted { $0.start < $1.start }
        XCTAssertEqual(series.map(\.title), ["Morning yoga", "Morning yoga", "Morning yoga"])
        XCTAssertEqual(series.map(\.start), [17, 24, 31].map { TestClock.local(2026, 10, $0, 8) })
        XCTAssertEqual(series.map(\.duration), [3_600, 3_600, 3_600])

        // "All events" cannot move the series to another day.
        do {
            try await rig.editor.update(yoga[0], with: EventEdit(start: TestClock.local(2026, 10, 18, 8)), scope: .allEvents, now: now)
            XCTFail("another day needs Google Calendar")
        } catch {
            XCTAssertEqual(error as? EventEditError, .seriesDayChange)
        }

        // Delete one occurrence, then the whole series.
        try await rig.editor.delete(series[0], scope: .thisEvent, now: now)
        var left = await rig.store.snapshot().events.map(\.id).sorted()
        XCTAssertEqual(left, ["demo-dentist", "demo-yoga-2026-10-24", "demo-yoga-2026-10-31"])
        try await rig.editor.delete(series[1], scope: .allEvents, now: now)
        left = await rig.store.snapshot().events.map(\.id)
        XCTAssertEqual(left, ["demo-dentist"])

        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(SyncStatusStore.current(in: defaults).pendingCount, 0)
    }

    // MARK: Online

    func testAnEditIsPatchedWithIfMatchAndCached() async throws {
        let google = EditorScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let sync = event("e1", start: TestClock.local(2026, 10, 15, 14), calendar: personal, etag: "\"1\"")
        await rig.store.upsert([sync])
        let saved = #"{"id":"e1","status":"confirmed","etag":"\"2\"","summary":"Team sync","description":"Bring slides\nRoom 4","start":{"dateTime":"2026-10-15T14:00:00+01:00"},"end":{"dateTime":"2026-10-15T15:00:00+01:00"}}"#
        await google.on("PATCH", "/events/e1", [(200, saved)])

        let updated = try await rig.editor.update(sync, with: EventEdit(notes: "Bring slides\nRoom 4\n"), scope: .thisEvent, now: now)

        let patches = await google.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.map(\.ifMatch), ["\"1\""])
        let body = try XCTUnwrap(patches.first?.json)
        XCTAssertEqual(Set(body.keys), ["description"])
        XCTAssertEqual(body["description"] as? String, "Bring slides\nRoom 4")
        XCTAssertEqual(updated.notes, "Bring slides\nRoom 4")
        XCTAssertEqual(updated.etag, "\"2\"")
        XCTAssertFalse(updated.isWaitingToSync)
        let cachedCopy = await cached(rig.store, "e1")
        XCTAssertEqual(cachedCopy?.notes, "Bring slides\nRoom 4")
        XCTAssertEqual(cachedCopy?.calendarRef, personal)

        // Nothing changed: no request.
        let unchanged = try await rig.editor.update(updated, with: EventEdit(notes: "Bring slides\nRoom 4"), scope: .thisEvent, now: now)
        XCTAssertEqual(unchanged.etag, "\"2\"")
        let count = await google.requests.count
        XCTAssertEqual(count, 1)
    }

    func testAnEditOfEveryOccurrencePatchesTheSeriesMaster() async throws {
        let google = EditorScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let instance = event("series1_20261015T130000Z", title: "Yoga", start: TestClock.local(2026, 10, 15, 14),
                             calendar: personal, seriesID: "series1", etag: "\"i1\"")
        await rig.store.upsert([instance])
        let master = #"{"id":"series1","status":"confirmed","etag":"\"m1\"","summary":"Yoga","recurrence":["RRULE:FREQ=WEEKLY;BYDAY=TH"],"start":{"dateTime":"2026-10-01T14:00:00+01:00","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-01T15:00:00+01:00","timeZone":"Europe/London"}}"#
        let patched = #"{"id":"series1","status":"confirmed","etag":"\"m2\"","summary":"Morning yoga","recurrence":["RRULE:FREQ=WEEKLY;BYDAY=TH"],"start":{"dateTime":"2026-10-01T15:00:00+01:00","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-01T16:00:00+01:00","timeZone":"Europe/London"}}"#
        let listed = #"{"items":[{"id":"series1_20261015T140000Z","recurringEventId":"series1","status":"confirmed","etag":"\"i2\"","summary":"Morning yoga","start":{"dateTime":"2026-10-15T15:00:00+01:00"},"end":{"dateTime":"2026-10-15T16:00:00+01:00"}}]}"#
        await google.on("GET", "/events/series1", [(200, master)])
        await google.on("PATCH", "/events/series1", [(200, patched)])
        await google.on("GET", "/events", [(200, listed)])

        let edit = EventEdit(title: "Morning yoga", start: TestClock.local(2026, 10, 15, 15), end: TestClock.local(2026, 10, 15, 16))
        let updated = try await rig.editor.update(instance, with: edit, scope: .allEvents, now: now)

        let patches = await google.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.map(\.ifMatch), ["\"m1\""])
        let body = try XCTUnwrap(patches.first?.json)
        XCTAssertEqual(body["summary"] as? String, "Morning yoga")
        // The new time on the master's own first date.
        XCTAssertEqual((body["start"] as? [String: Any])?["dateTime"] as? String, "2026-10-01T15:00:00")
        XCTAssertEqual((body["end"] as? [String: Any])?["dateTime"] as? String, "2026-10-01T16:00:00")
        // Google gave the moved instance a new id: the page gets that occurrence.
        XCTAssertEqual(updated.id, "series1_20261015T140000Z")
        XCTAssertEqual(updated.title, "Morning yoga")
        XCTAssertEqual(updated.start, TestClock.local(2026, 10, 15, 15))
        let ids = await rig.store.snapshot().events.map(\.id)
        XCTAssertEqual(ids, ["series1_20261015T140000Z"])
    }

    func testDeletingTheWholeSeriesDeletesTheMaster() async throws {
        let google = EditorScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let first = event("series1_a", title: "Yoga", start: TestClock.local(2026, 10, 15, 14), calendar: personal,
                          seriesID: "series1", etag: "\"a\"")
        let second = event("series1_b", title: "Yoga", start: TestClock.local(2026, 10, 22, 14), calendar: personal,
                           seriesID: "series1", etag: "\"b\"")
        let lunch = event("lunch", title: "Lunch", start: TestClock.local(2026, 10, 16, 12), calendar: personal, etag: "\"l\"")
        await rig.store.upsert([first, second, lunch])
        await google.on("DELETE", "/events/series1", [(204, "")])
        await google.on("DELETE", "/events/lunch", [(204, "")])

        try await rig.editor.delete(second, scope: .allEvents, now: now)
        try await rig.editor.delete(lunch, scope: .allEvents, now: now) // a one-off: just the event

        let deletes = await google.requests.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.map { $0.path.components(separatedBy: "/").last }, ["series1", "lunch"])
        XCTAssertEqual(deletes.map(\.ifMatch), [nil, "\"l\""])
        let left = await rig.store.snapshot().events
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: Offline

    func testAnEditMadeOfflineWaitsInTheOutboxAndShowsAtOnce() async throws {
        let google = EditorScriptedGoogle()
        await google.setOffline(true)
        let rig = await makeRig(demo: false, google: google)
        let sync = event("e1", start: TestClock.local(2026, 10, 15, 14), calendar: personal, etag: "\"1\"")
        await rig.store.upsert([sync])

        let edit = EventEdit(title: "Team sync (moved)", start: TestClock.local(2026, 10, 15, 16), notes: "Room 4")
        let shown = try await rig.editor.update(sync, with: edit, scope: .thisEvent, now: now)
        XCTAssertTrue(shown.isWaitingToSync)
        XCTAssertEqual(shown.title, "Team sync (moved)")
        XCTAssertEqual(shown.start, TestClock.local(2026, 10, 15, 16))
        XCTAssertEqual(shown.end, TestClock.local(2026, 10, 15, 17))
        XCTAssertEqual(shown.notes, "Room 4")

        let queue = await rig.outbox.pending()
        XCTAssertEqual(queue.map(\.kind), [.patch])
        XCTAssertEqual(queue.first?.etag, "\"1\"")
        XCTAssertEqual(queue.first?.body?.description, "Room 4")
        let cachedCopy = await cached(rig.store, "e1")
        XCTAssertEqual(cachedCopy?.isWaitingToSync, true)
        XCTAssertEqual(SyncStatusStore.current(in: defaults).pendingCount, 1)
        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: What cannot be changed

    func testReadOnlyCalendarsAndPreviewsCannotBeChanged() async throws {
        let google = EditorScriptedGoogle()
        let rig = await makeRig(demo: false, google: google)
        let holiday = event("h1", title: "Bank holiday", start: TestClock.local(2026, 10, 16), calendar: holidays)
        await rig.store.upsert([holiday])

        let canEditHoliday = await rig.editor.canEdit(holiday)
        XCTAssertFalse(canEditHoliday)
        let calendars = await rig.accounts.calendars()
        XCTAssertFalse(EventEditor.canEdit(holiday, in: calendars))
        XCTAssertTrue(EventEditor.canEdit(event("x", start: now, calendar: personal), in: calendars))
        XCTAssertTrue(EventEditor.canEdit(event("y", start: now, calendar: CalendarRef(accountID: "999", calendarID: "gone")),
                                          in: calendars), "Google decides for a calendar the account store does not know")

        do {
            try await rig.editor.update(holiday, with: EventEdit(title: "Day off"), scope: .thisEvent, now: now)
            XCTFail("a reader calendar cannot be changed")
        } catch {
            guard case RouterError.readOnly? = error as? RouterError else { return XCTFail("\(error)") }
        }
        do {
            try await rig.editor.delete(holiday, scope: .thisEvent, now: now)
            XCTFail("a reader calendar cannot be changed")
        } catch {
            guard case RouterError.readOnly? = error as? RouterError else { return XCTFail("\(error)") }
        }

        let preview = TestEvents.make(id: PlanDraft.eventIDPrefix + "p1", start: now, end: now.addingTimeInterval(3_600))
        XCTAssertFalse(EventEditor.canEdit(preview, in: calendars))
        do {
            try await rig.editor.update(preview, with: EventEdit(title: "x"), scope: .thisEvent, now: now)
            XCTFail("a preview is not in a calendar")
        } catch {
            XCTAssertEqual(error as? EventEditError, .notEditable)
        }

        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty)
        let kept = await cached(rig.store, "h1")
        XCTAssertEqual(kept?.title, "Bank holiday")
    }
}

/// Answers Calendar API requests from a script, by method and path suffix (the longest matching suffix wins), and
/// records them. Offline, it fails like a phone without a connection and records nothing.
private actor EditorScriptedGoogle: CalendarTransport {
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
                                       headerFields: ["Date": "Wed, 14 Oct 2026 08:00:00 GMT"])!
        return (Data(answer.json.utf8), response)
    }
}
