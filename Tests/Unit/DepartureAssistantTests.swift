import XCTest

/// `ScheduleAssistant`'s departure flow 「該出發了」 (docs/SETTINGS.md §7.11, build step G4d), with fakes for Gemini,
/// Google Calendar, the routes server and the location. Only the chat plans (`handleFromChat`); with the feature off
/// (none given, not offered here, Not now, demo mode, Siri) Gemini gets main's request exactly. A plan is for being
/// there 10 minutes before the start, asks Google once (or once more by car), writes only the two values on the event,
/// and tells Gemini one fixed value, never a time, a place or a route. The reply's text keeps no time from Google; the
/// chat shows it. The lines are the English keys (Bundle.main is the test runner).
final class DepartureAssistantTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-20 14:00 BST (London is UTC+1 until 25 October).
    private let now = TestClock.local(2026, 10, 20, 14, 0)
    private let email = "kenny@example.com"
    /// Where the iPhone is (King's Cross).
    private let here = GeoPoint(latitude: 51.5308, longitude: -0.1238)
    /// The UserDefaults suite holding this test's answer to 「使用 Google 地圖規劃出發時間？」.
    private var suiteName = ""

    /// What a chat turn may call on main: every conversational function, in `AssistantFunction`'s order.
    private let mainFunctions = ["create_events", "create_long_term_plan", "modify_event", "delete_events",
                                 "query_schedule", "reply_to_user", "confirm_plan", "update_preferences"]

    /// A new 16:40 meeting at Taipei 101 and the plan_departure for it, as Gemini sends them in one turn.
    private let newMeetingUtterance = "Meeting at Taipei 101 today at 16:40 for an hour, when should I leave?"
    private let createMeeting = #"""
        {"events": [{"title": "Meeting", "start": "2026-10-20T16:40", "duration_minutes": 60, "kind": "event",
                     "location": "Taipei 101"}]}
        """#
    private let planNewMeeting = #"{"destination": "Taipei 101", "arrive_at_local": "2026-10-20T16:40", "create_event": true}"#

    override func setUp() {
        super.setUp()
        DepartureAssistantGeminiStub.recorder.reset()
        suiteName = "DepartureAssistantTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        files.removeAll()
        super.tearDown()
    }

    // MARK: Rig

    private struct Rig {
        let assistant: ScheduleAssistant
        let store: SharedStore
        /// The router's accounts: what the prompt's CALENDARS come from.
        let accounts: AccountStore
        let preferences: PreferencesStore
        let google: DepartureAssistantGoogle
        let routes: DepartureAssistantRoutes
        /// Asking 「使用 Google 地圖規劃出發時間？」 ("ask"), reading the location ("location") and asking for a route
        /// ("route"), in order.
        let trail: DepartureAssistantTrail
        let consent: DepartureConsentStore
    }

    /// A real-looking account "111" whose calendar holds `events` and gets new events, or demo mode's assistant
    /// (`sample`, as in SampleCalendarAssistantTests). The departure services are given (`DepartureSource.given`) unless
    /// `departuresOff` (`.none`): routes and a location that note each use, `consent` kept in this test's suite, and the
    /// availability the app works out in Taiwan (off once the user said Not now) unless `availability` fixes it.
    /// Reminders are not rescheduled: a hostless test bundle has no notification center.
    private func makeRig(sample: Bool = false, askFirst: Bool = false, events: [ScheduleEvent] = [],
                         consent answer: DepartureConsent = .allowed, allowWhenAsked: Bool = false,
                         availability: DepartureAvailability? = nil, location: (any LocationProviding)? = nil,
                         departuresOff: Bool = false) async -> Rig {
        let file = files.url("DepartureAssistant-accounts")
        let live = AccountStore(fileURL: file, isDemoMode: { sample }, defaultCalendar: { nil })
        await live.upsert(SampleAccounts.account("111", email: email))
        let accounts = sample ? AccountStore(fileURL: file, isDemoMode: { true }, defaultCalendar: { nil }) : live
        let store = SharedStore(fileURL: files.url("DepartureAssistant-cache"), accounts: live)
        if sample {
            await store.replaceWindow(DemoData.seedWindow(now: now, clock: TestClock.clock),
                                      with: DemoData.events(now: now, clock: TestClock.clock))
        }
        if !events.isEmpty { await store.upsert(events) }

        let outbox = SyncOutbox(fileURL: files.url("DepartureAssistant-outbox"))
        let google = DepartureAssistantGoogle()
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: google, outbox: outbox)
        let preferences = PreferencesStore(fileURL: files.url("DepartureAssistant-prefs"))
        if askFirst { await preferences.update { $0.autonomy = .askFirst } }

        let trail = DepartureAssistantTrail()
        let routes = DepartureAssistantRoutes(trail: trail)
        let consent = DepartureConsentStore(suiteName: suiteName)
        consent.write(answer)
        let reader: any LocationProviding
        if let location {
            reader = location
        } else {
            reader = DepartureAssistantLocation(trail: trail, result: .success(here))
        }
        let check: @Sendable () async -> DepartureAvailability
        if let availability {
            check = { availability }
        } else {
            check = {
                DepartureAvailability.resolve(region: "TW", timeZone: "Asia/Taipei", consent: consent.read(),
                                              debugBuild: false, debugAllowsBlocked: false)
            }
        }
        let services = DepartureServices(routing: routes, location: reader, availability: check, consent: consent,
                                         appLanguage: "en", isoRegion: "TW", debugBuild: false,
                                         askConsent: {
                                             await trail.note("ask")
                                             return allowWhenAsked
                                         })
        let source: DepartureSource = departuresOff ? .none : .given(services)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DepartureAssistantGeminiStub.self]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { true })
        let assistant = ScheduleAssistant(gemini: gemini, router: router, store: store, preferences: preferences,
                                          clock: TestClock.clock, rescheduleReminders: { _ in }, departures: source)
        return Rig(assistant: assistant, store: store, accounts: accounts, preferences: preferences, google: google,
                   routes: routes, trail: trail, consent: consent)
    }

    // MARK: Helpers

    /// 20 October 2026 at this London time.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        TestClock.local(2026, 10, 20, hour, minute)
    }

    /// An hour-long event in account 111's calendar.
    private func event(_ id: String, title: String = "Meeting", start: Date, place: String? = "Taipei 101",
                       seriesID: String? = nil, departure: DepartureSettings? = nil) -> ScheduleEvent {
        var made = TestEvents.make(id: id, title: title, start: start, end: start.addingTimeInterval(3600),
                                   seriesID: seriesID, calendar: CalendarRef(accountID: "111", calendarID: email))
        made.location = place
        made.departure = departure
        return made
    }

    /// 16:40 at Taipei 101: be there by 16:30.
    private func meeting() -> ScheduleEvent {
        event("meeting1", start: at(16, 40))
    }

    /// A route as the server answers it. Its summary is Google's text, which must never reach Gemini.
    private func route(_ mode: RouteMode = .transit, leave: Date, arrive: Date, late: Bool = false,
                       plansLeft: Int = 1) -> Result<DepartureRouteResult, DepartureRouteError> {
        .success(.route(DepartureRoute(mode: mode, departAt: leave, arriveAt: arrive, late: late, estimate: false,
                                       plan: nil, plansLeft: plansLeft,
                                       summary: RouteSummary(description: "Piccadilly line", warnings: ["Toll road ahead"],
                                                             segments: []))))
    }

    /// The request the app should send from here (or `origin`), in English with Taiwan's region bias.
    private func routeRequest(_ mode: RouteMode = .transit, origin: TravelOrigin? = nil, to destination: String = "Taipei 101",
                              arriveBy: Date?) -> DepartureRouteRequest {
        DepartureRouteRequest(mode: mode, origin: origin ?? .current(here), destination: destination, arriveBy: arriveBy,
                              plan: nil, utcOffsetMinutes: 60, language: "en", region: "tw", debugBuild: false)
    }

    /// Queues Gemini's answers to the next requests, in order.
    private func answer(_ responses: String...) {
        DepartureAssistantGeminiStub.recorder.answer(responses)
    }

    private func call(_ name: String, _ args: String) -> String {
        DepartureAssistantGeminiStub.call(name, args)
    }

    /// One model turn with several function calls.
    private func turn(_ calls: [(name: String, args: String)]) -> String {
        DepartureAssistantGeminiStub.turn(calls)
    }

    private func sentRequests() throws -> [DepartureAssistantRequest] {
        try DepartureAssistantGeminiStub.recorder.bodies.map { try DepartureAssistantRequest($0) }
    }

    private func onlyRequest(file: StaticString = #filePath, line: UInt = #line) throws -> DepartureAssistantRequest {
        let requests = try sentRequests()
        XCTAssertEqual(requests.count, 1, "one Gemini request", file: file, line: line)
        return try XCTUnwrap(requests.first, file: file, line: line)
    }

    /// The fixed answer plan_departure gives Gemini.
    private func reminders(_ value: String) -> NSDictionary {
        NSDictionary(dictionary: ["ok": true, "departure_reminders": value])
    }

    /// What Gemini was told for plan_departure, as the next chat request ("Thanks") carries it.
    private func toldGemini(_ rig: Rig, now: Date) async throws -> [NSDictionary] {
        _ = try await rig.assistant.handleFromChat("Thanks", now: now)
        let requests = try sentRequests()
        return try XCTUnwrap(requests.last).responses(named: "plan_departure")
    }

    /// The private extended properties of a Calendar request's body.
    private func privateProperties(_ body: Data?, file: StaticString = #filePath,
                                   line: UInt = #line) throws -> [String: String] {
        let object = try TestJSON.object(try XCTUnwrap(body, file: file, line: line))
        let extended = try XCTUnwrap(object["extendedProperties"] as? [String: Any], file: file, line: line)
        return try XCTUnwrap(extended["private"] as? [String: String], file: file, line: line)
    }

    /// main's declarations (the frozen copy in Tests/fixtures/main).
    private func mainDeclarations() throws -> NSArray {
        let url = try Fixtures.directory().appendingPathComponent("main/FunctionDeclarations.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSArray)
    }

    /// main's system instruction (the frozen copy in PromptWithoutDepartures.swift) for what the rig holds now.
    private func mainsSystem(_ rig: Rig) async -> String {
        let clock = TestClock.clock
        let window = DateInterval(start: clock.calendar.startOfDay(for: now), duration: 14 * 86_400)
        let upcoming = await rig.store.events(in: window)
        let draft = await rig.store.pendingPlan()
        let pending = await rig.store.pendingEventBatch()
        let calendars = await rig.accounts.calendars()
        let target = await rig.accounts.defaultWriteTarget()?.id
        let preferences = rig.preferences.current()
        return PromptWithoutDepartures.system(now: now, clock: clock, locale: .current, upcoming: upcoming, focus: nil,
                                              policy: ReminderPolicy(preferences: preferences), draft: draft,
                                              preferences: preferences, calendars: calendars, defaultTarget: target,
                                              pendingEvents: pending)
    }

    /// The request is main's exactly (owner decision 3A): the system text, the declarations, the allowed functions, and
    /// no plan_departure anywhere, the history included.
    private func assertMainsRequest(_ request: DepartureAssistantRequest, rig: Rig, demo: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let system = await mainsSystem(rig) + (demo ? "\n\n" + AssistantPrompt.demoModeBlock : "")
        XCTAssertEqual(request.system, system, "main's system instruction", file: file, line: line)
        let declarations = try mainDeclarations()
        XCTAssertEqual(request.declarations, declarations, "main's declarations", file: file, line: line)
        XCTAssertEqual(request.allowed, mainFunctions, file: file, line: line)
        XCTAssertEqual(request.mode, "ANY", file: file, line: line)
        XCTAssertFalse(request.raw.contains("plan_departure"), request.raw, file: file, line: line)
    }

    /// Not asked, no location read, no route asked for, nothing written to Google Calendar.
    private func assertNothingPlanned(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let steps = await rig.trail.steps
        XCTAssertEqual(steps, [], "not asked, no location, no route", file: file, line: line)
        let routes = await rig.routes.requests
        XCTAssertTrue(routes.isEmpty, "no route asked for", file: file, line: line)
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty, "nothing written", file: file, line: line)
    }

    // MARK: Off: exactly main's request (owner decision 3A)

    func testWithTheFeatureOffTheChatSendsMainsRequestExactly() async throws {
        let rig = await makeRig(events: [meeting()], departuresOff: true)
        _ = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)
        let request = try onlyRequest()
        try await assertMainsRequest(request, rig: rig)
        XCTAssertTrue(request.system.contains("meeting1 | Meeting |"), "the meeting is in UPCOMING")
    }

    /// Not offered here (the region, or the switch in Settings): main's request, and a stray plan_departure plans
    /// nothing.
    func testWhereTheFeatureIsNotOfferedNothingIsDeclaredOrPlanned() async throws {
        let rig = await makeRig(events: [meeting()], availability: .off)
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        try await assertMainsRequest(try onlyRequest(), rig: rig)
        XCTAssertNil(reply.departure)
        XCTAssertFalse(reply.changed)
        await assertNothingPlanned(rig)
    }

    /// Demo mode never plans departures (owner decision 2026-10-19): main's request plus the demo block.
    func testDemoModeSendsMainsRequestAndPlansNothing() async throws {
        let rig = await makeRig(sample: true)
        answer(call("plan_departure", #"{"destination": "Hyde Park"}"#))
        let reply = try await rig.assistant.handleFromChat("How long does it take to get to Hyde Park?", now: now)

        let request = try onlyRequest()
        XCTAssertTrue(request.system.contains("# DEMO MODE"), request.system)
        try await assertMainsRequest(request, rig: rig, demo: true)
        XCTAssertNil(reply.departure)
        await assertNothingPlanned(rig)
    }

    /// Siri, notification replies and the long-press card (`handle`) never plan, even with the services given and the
    /// question not asked yet.
    func testSiriAndNotificationRepliesNeverPlan() async throws {
        let rig = await makeRig(events: [meeting()], consent: .notAsked, allowWhenAsked: true)
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handle("When should I leave for the meeting?", now: now)

        try await assertMainsRequest(try onlyRequest(), rig: rig)
        XCTAssertNil(reply.departure)
        XCTAssertFalse(reply.changed)
        await assertNothingPlanned(rig)
        XCTAssertEqual(rig.consent.read(), .notAsked)
    }

    /// After a chat turn that planned, Siri's request is still main's: the history leaves out plan_departure's call and
    /// answer (`DepartureTurn.withoutDepartureCalls`).
    func testSiriAfterAChatDepartureSendsTheHistoryWithoutIt() async throws {
        let rig = await makeRig()
        await rig.routes.answer([route(.walk, leave: now, arrive: at(14, 25))])
        answer(call("plan_departure", #"{"destination": "Hyde Park", "travel_mode": "walking"}"#))
        _ = try await rig.assistant.handleFromChat("How long does it take to walk to Hyde Park?", now: now)
        _ = try await rig.assistant.handle("What's on tomorrow?", now: now)

        let requests = try sentRequests()
        XCTAssertEqual(requests.count, 2)
        let chat = try XCTUnwrap(requests.first)
        XCTAssertTrue(chat.declared.contains("plan_departure"))
        let siri = try XCTUnwrap(requests.last)
        try await assertMainsRequest(siri, rig: rig)
        // The chat turn as main keeps it: the user's words, the model turn left empty as "OK.", no answer turn.
        XCTAssertEqual(siri.contents.count, 3)
        if siri.contents.count == 3 {
            XCTAssertEqual(siri.contents[1] as NSDictionary,
                           NSDictionary(dictionary: ["role": "model", "parts": [["text": "OK."]]]))
        }
    }

    // MARK: A new event

    /// create_events and plan_departure in one turn: the event and its two values go in the same insert, which is the
    /// insert made without the feature plus those two values.
    func testANewEventIsWrittenWithItsDepartureInTheSameInsert() async throws {
        let rig = await makeRig()
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(turn([("create_events", createMeeting), ("plan_departure", planNewMeeting)]))
        let reply = try await rig.assistant.handleFromChat(newMeetingUtterance, now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: at(16, 30))], "be there 10 minutes before the start")
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["POST"], "one insert, no PATCH after it")
        let properties = try privateProperties(writes.first?.body)
        XCTAssertEqual(properties[SSProperty.arriveEarly], "10")
        XCTAssertEqual(properties[SSProperty.travelMode], "transit")
        let settings = DepartureSettings(arriveEarlyMinutes: 10, travelMode: .transit)
        XCTAssertEqual(reply.addedEvents.first?.departure, settings)
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.\nYou can plan 1 more this week.")
        XCTAssertTrue(reply.text.contains("Planned when to leave for Taipei 101 (be there by 16:30)."), reply.text)
        XCTAssertFalse(reply.text.contains("15:48"), reply.text)
        XCTAssertEqual(DepartureAssistantGeminiStub.recorder.bodies.count, 1)
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("set")])

        // The same turn without the feature: the insert differs only by the two values (and its random id).
        let off = await makeRig(departuresOff: true)
        answer(call("create_events", createMeeting))
        _ = try await off.assistant.handleFromChat(newMeetingUtterance, now: now)
        let plain = await off.google.writes
        XCTAssertEqual(plain.map(\.method), ["POST"])
        var withDeparture = try TestJSON.object(try XCTUnwrap(writes.first?.body))
        var without = try TestJSON.object(try XCTUnwrap(plain.first?.body))
        withDeparture["id"] = nil
        without["id"] = nil
        var extended = try XCTUnwrap(withDeparture["extendedProperties"] as? [String: Any])
        var values = try XCTUnwrap(extended["private"] as? [String: String])
        values[SSProperty.arriveEarly] = nil
        values[SSProperty.travelMode] = nil
        extended["private"] = values
        withDeparture["extendedProperties"] = extended
        XCTAssertEqual(withDeparture as NSDictionary, without as NSDictionary)
    }

    /// "Ask me first": nothing is written before Add. The preview carries the departure, the reply says it is set on
    /// Add, Add writes the two values in the insert, and Gemini is told awaiting_user_approval.
    func testAskMeFirstKeepsTheDepartureOnThePreviewAndWritesItOnAdd() async throws {
        let rig = await makeRig(askFirst: true)
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        // plan_departure first this time: the order of the calls doesn't matter.
        answer(turn([("plan_departure", planNewMeeting), ("create_events", createMeeting)]))
        let proposed = try await rig.assistant.handleFromChat(newMeetingUtterance, now: now)

        let settings = DepartureSettings(arriveEarlyMinutes: 10, travelMode: .transit)
        let batch = try XCTUnwrap(proposed.pendingEvents)
        XCTAssertEqual(batch.previewEvents.first?.departure, settings)
        XCTAssertTrue(proposed.text.contains("Departure reminders are set when you tap Add."), proposed.text)
        XCTAssertEqual(proposed.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.\n"
                           + "Departure reminders are set when you tap Add.\nYou can plan 1 more this week.")
        var writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty, "nothing written before Add")

        let added = try await rig.assistant.commitPendingEvents(batch, now: now)
        XCTAssertEqual(added.addedEvents.first?.departure, settings)
        writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["POST"])
        let properties = try privateProperties(writes.first?.body)
        XCTAssertEqual(properties[SSProperty.arriveEarly], "10")
        XCTAssertEqual(properties[SSProperty.travelMode], "transit")

        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("awaiting_user_approval")])
    }

    // MARK: An event in the calendar

    /// The app reads the event's place and start (owner decision 1A), asks by public transport to be there 10 minutes
    /// early, and PATCHes the two values and nothing else.
    func testAnEventInTheCalendarGetsOnlyItsTwoDepartureValues() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        // On, the chat's request declares plan_departure (the control for the tests above).
        let request = try onlyRequest()
        XCTAssertTrue(request.declared.contains("plan_departure"))
        XCTAssertEqual(request.allowed, mainFunctions + ["plan_departure"])
        XCTAssertTrue(request.system.contains("\n13. Travel times and departures"), request.system)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: at(16, 30))])
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH"])
        let url = try XCTUnwrap(writes.first?.url?.absoluteString)
        XCTAssertTrue(url.hasSuffix("/events/meeting1"), url)
        let body = try TestJSON.object(try XCTUnwrap(writes.first?.body))
        XCTAssertEqual(Array(body.keys), ["extendedProperties"])
        XCTAssertEqual(try privateProperties(writes.first?.body),
                       [SSProperty.arriveEarly: "10", SSProperty.travelMode: "transit"])

        XCTAssertTrue(reply.changed)
        XCTAssertEqual(reply.text, "Planned when to leave for Taipei 101 (be there by 16:30).\nYou can plan 1 more this week.")
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.\nYou can plan 1 more this week.")
        XCTAssertEqual(reply.departure?.destination, "Taipei 101")
        XCTAssertEqual(reply.departure?.mode, .transit)
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("set")])
    }

    /// A repeating event: the whole series gets the two values (owner decision 2026-10-20), not the one occurrence.
    func testARepeatingEventGetsItsDepartureOnTheWholeSeries() async throws {
        let standup = event("standup_20261020T154000Z", title: "Stand-up", start: at(16, 40), seriesID: "standup")
        let rig = await makeRig(events: [standup])
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "standup_20261020T154000Z"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the stand-up?", now: now)

        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH"])
        let url = try XCTUnwrap(writes.first?.url?.absoluteString)
        XCTAssertTrue(url.hasSuffix("/events/standup"), "the series master, not the occurrence: \(url)")
        XCTAssertEqual(try privateProperties(writes.first?.body),
                       [SSProperty.arriveEarly: "10", SSProperty.travelMode: "transit"])
        XCTAssertTrue(reply.changed)
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.\nYou can plan 1 more this week.")
    }

    /// The way of travelling the user said wins over the one the event keeps, which wins over public transport; the
    /// minutes early likewise.
    func testWhatTheUserSaysWinsOverWhatTheEventKeeps() async throws {
        let kept = DepartureSettings(arriveEarlyMinutes: 20, travelMode: .walking)
        let rig = await makeRig(events: [event("walk1", start: at(16, 40), departure: kept)])
        await rig.routes.answer([route(.walk, leave: at(15, 50), arrive: at(16, 18)),
                                 route(.drive, leave: at(16, 10), arrive: at(16, 33))])
        answer(call("plan_departure", #"{"event_id": "walk1"}"#),
               call("plan_departure", #"{"event_id": "walk1", "travel_mode": "driving", "arrive_early_minutes": 5}"#))
        _ = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)
        _ = try await rig.assistant.handleFromChat("I'll drive, and 5 minutes early is enough", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(.walk, arriveBy: at(16, 20)), routeRequest(.drive, arriveBy: at(16, 35))])
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH", "PATCH"])
        XCTAssertEqual(try privateProperties(writes.first?.body),
                       [SSProperty.arriveEarly: "20", SSProperty.travelMode: "walking"])
        XCTAssertEqual(try privateProperties(writes.last?.body),
                       [SSProperty.arriveEarly: "5", SSProperty.travelMode: "driving"])
    }

    /// The reply's text (history, the export, Siri, the Live Activity) keeps no time from Google; the chat swaps in the
    /// shown answer while the app runs.
    func testTheReplyTextKeepsNoTimeFromGoogleAndTheChatShowsIt() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        XCTAssertFalse(reply.text.contains("15:48"), reply.text)
        XCTAssertFalse(reply.text.contains("16:28"), reply.text)
        let departure = try XCTUnwrap(reply.departure)
        XCTAssertEqual(departure.kept, reply.text)
        XCTAssertTrue(departure.shown.contains("leave at 15:48"), departure.shown)
        XCTAssertEqual(DepartureReply.displayText(reply.text, departure: departure), departure.shown)
        let line = await rig.store.snapshot().lastAssistantLine
        XCTAssertEqual(line, reply.text)
    }

    // MARK: When there is nothing to set

    /// The time to be there has passed (owner decision 2026-10-21): nothing is asked, read or sent.
    func testATimeThatHasPassedIsNotPlanned() async throws {
        let rig = await makeRig(events: [event("soon1", start: at(14, 5))], consent: .notAsked, allowWhenAsked: true)
        answer(call("plan_departure", #"{"event_id": "soon1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        XCTAssertEqual(reply.text, "That time has already passed, so there's no departure to plan.")
        XCTAssertEqual(reply.departure?.shown, reply.text)
        XCTAssertFalse(reply.changed)
        await assertNothingPlanned(rig)
        XCTAssertEqual(rig.consent.read(), .notAsked)
    }

    /// Even leaving now arrives late (owner decision 2026-10-21, B): shown with how late, nothing written, not_set.
    func testArrivingLateSaysLeaveNowAndSavesNothing() async throws {
        let later = at(16, 5)
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([route(leave: later, arrive: at(16, 42), late: true)])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: later)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: at(16, 30))])
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave now: you'll arrive at 16:42, about 12 min late.\n"
                           + "You can plan 1 more this week.")
        XCTAssertEqual(reply.text, "Planned when to leave for Taipei 101 (be there by 16:30).\nYou can plan 1 more this week.")
        XCTAssertFalse(reply.changed)
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty)
        let told = try await toldGemini(rig, now: later)
        XCTAssertEqual(told, [reminders("not_set")])
    }

    /// Under two minutes to the time to be there: no arrival is sent, Google plans leaving now, and the reply says how
    /// late that arrives.
    func testWithinTwoMinutesItPlansLeavingNow() async throws {
        let rig = await makeRig(events: [event("soon1", start: at(14, 11))])
        await rig.routes.answer([route(leave: now, arrive: at(14, 20))])
        answer(call("plan_departure", #"{"event_id": "soon1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: nil)])
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 14:01, leave now: you'll arrive at 14:20, about 19 min late.\n"
                           + "You can plan 1 more this week.")
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty)
    }

    /// "How long": the destination only, leaving now (no arrival), the way of travelling said; nothing is written.
    func testHowLongPlansLeavingNowWithoutAnArrivalTime() async throws {
        let rig = await makeRig()
        await rig.routes.answer([route(.walk, leave: now, arrive: at(14, 25))])
        answer(call("plan_departure", #"{"destination": "Hyde Park", "travel_mode": "walking"}"#))
        let reply = try await rig.assistant.handleFromChat("How long does it take to walk to Hyde Park?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(.walk, to: "Hyde Park", arriveBy: nil)])
        XCTAssertEqual(reply.text, "Checked the travel time to Hyde Park.\nYou can plan 1 more this week.")
        XCTAssertEqual(reply.departure?.shown,
                       "Leaving now for Hyde Park takes about 25 min: you'll arrive at 14:25.\nYou can plan 1 more this week.")
        XCTAssertEqual(reply.departure?.mode, .walking)
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty)
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("not_set")])
    }

    /// An event without a place (owner decision 1A): the app says so and asks nothing of Google.
    func testAnEventWithoutAPlaceIsNotPlanned() async throws {
        let rig = await makeRig(events: [event("noplace1", start: at(16, 40), place: nil)])
        answer(call("plan_departure", #"{"event_id": "noplace1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        XCTAssertEqual(reply.text, "This event has no place yet. Add one to the event first.")
        await assertNothingPlanned(rig)
    }

    // MARK: The way of travelling

    /// Public transport was the app's choice: with no route, one more request by car, and the reply says so.
    func testNoPublicTransportRouteFallsBackToDrivingOnce() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([.success(.noRoute(plansLeft: 1)),
                                 route(.drive, leave: at(15, 55), arrive: at(16, 25), plansLeft: 0)])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: at(16, 30)), routeRequest(.drive, arriveBy: at(16, 30))])
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:55. "
                           + "No public transport route was found, so this is by car.\nThat was this week's last plan.")
        XCTAssertEqual(reply.text, "Planned when to leave for Taipei 101 (be there by 16:30).\nThat was this week's last plan.")
        XCTAssertEqual(reply.departure?.mode, .driving)
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH"])
        XCTAssertEqual(try privateProperties(writes.first?.body),
                       [SSProperty.arriveEarly: "10", SSProperty.travelMode: "driving"])
    }

    /// A way of travelling the user said is never swapped for another.
    func testAWayOfTravellingTheUserSaidIsNeverSwapped() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([.success(.noRoute(plansLeft: 1)),
                                 route(.drive, leave: at(15, 55), arrive: at(16, 25))])
        answer(call("plan_departure", #"{"event_id": "meeting1", "travel_mode": "transit"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting by bus?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(arriveBy: at(16, 30))], "no second request by car")
        XCTAssertEqual(reply.text, "No route there by public transport.")
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: What Gemini gets

    /// plan_departure answers Gemini with one fixed value, and a reply_to_user next to it gets {"ok": true} and isn't
    /// shown: the app answers about the departure itself. No time, place or route from Google reaches Gemini.
    func testGeminiGetsOnlyAFixedValueAndTheAppAnswersInsteadOfReplyToUser() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(turn([("plan_departure", #"{"event_id": "meeting1"}"#),
                     ("reply_to_user", #"{"message": "Leave at 15:30 to be safe."}"#)]))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)
        XCTAssertEqual(reply.text, "Planned when to leave for Taipei 101 (be there by 16:30).\nYou can plan 1 more this week.")
        XCTAssertFalse(reply.text.contains("Leave at 15:30"), reply.text)

        _ = try await rig.assistant.handleFromChat("Thanks", now: now)
        let requests = try sentRequests()
        XCTAssertEqual(requests.count, 2, "one Gemini request per turn")
        let next = try XCTUnwrap(requests.last)
        XCTAssertEqual(next.responses(named: "plan_departure"), [reminders("set")])
        XCTAssertEqual(next.responses(named: "reply_to_user"), [NSDictionary(dictionary: ["ok": true])])
        for request in requests {
            for google in ["15:48", "16:28", "Taipei 101", "Piccadilly line", "Toll road ahead"] {
                XCTAssertFalse(request.raw.contains(google), "\(google) reached Gemini")
            }
        }
    }

    /// Only the turn's first plan_departure is planned; another one gets not_set.
    func testASecondPlanDepartureInATurnGetsNotSet() async throws {
        let rig = await makeRig(events: [meeting()])
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28)),
                                 route(leave: now, arrive: at(14, 25))])
        answer(turn([("plan_departure", #"{"event_id": "meeting1"}"#),
                     ("plan_departure", #"{"destination": "Hyde Park"}"#)]))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting and for Hyde Park?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent.map(\.destination), ["Taipei 101"], "only the first is planned")
        XCTAssertEqual(reply.departure?.destination, "Taipei 101")
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("set"), reminders("not_set")])
    }

    /// A clarifying question in the same turn: nothing is planned until it is answered, and the question is shown.
    func testAClarifyingQuestionInTheSameTurnPlansNothing() async throws {
        let rig = await makeRig()
        answer(turn([("plan_departure", planNewMeeting),
                     ("reply_to_user", #"""
                         {"message": "How long is the meeting?", "needs_clarification": true,
                          "suggested_replies": ["30 min", "1 hr"]}
                         """#)]))
        let reply = try await rig.assistant.handleFromChat("Meeting at Taipei 101 today at 16:40, when should I leave?",
                                                           now: now)

        XCTAssertEqual(reply.text, "How long is the meeting?")
        XCTAssertTrue(reply.needsClarification)
        XCTAssertEqual(reply.suggestions, ["30 min", "1 hr"])
        XCTAssertNil(reply.departure)
        await assertNothingPlanned(rig)

        _ = try await rig.assistant.handleFromChat("1 hr", now: now)
        let requests = try sentRequests()
        let next = try XCTUnwrap(requests.last)
        XCTAssertEqual(next.responses(named: "plan_departure"), [reminders("not_set")])
        XCTAssertEqual(next.responses(named: "reply_to_user"), [NSDictionary(dictionary: ["ok": true])])
    }

    /// A plan_departure with no event and no place leaves nothing for the app to answer: Gemini's reply_to_user is
    /// shown, and Gemini is told not_set.
    func testAPlanDepartureWithNothingToPlanLeavesTheReplyToGemini() async throws {
        let rig = await makeRig()
        answer(turn([("plan_departure", "{}"), ("reply_to_user", #"{"message": "Where are you going?"}"#)]))
        let reply = try await rig.assistant.handleFromChat("When should I leave?", now: now)

        XCTAssertEqual(reply.text, "Where are you going?")
        XCTAssertNil(reply.departure)
        await assertNothingPlanned(rig)
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("not_set")])
    }

    /// The app never asks Gemini a second time: one request per turn, however many times Google is asked.
    func testEveryTurnIsOneGeminiRequest() async throws {
        let rig = await makeRig(events: [meeting()], consent: .notAsked, allowWhenAsked: true)
        await rig.routes.answer([.success(.noRoute(plansLeft: 1)), route(.drive, leave: at(15, 55), arrive: at(16, 25)),
                                 route(.walk, leave: now, arrive: at(14, 25))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#),
               call("plan_departure", #"{"destination": "Hyde Park", "travel_mode": "walking"}"#))

        _ = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)
        XCTAssertEqual(DepartureAssistantGeminiStub.recorder.bodies.count, 1, "asked Allow, then Google twice")
        _ = try await rig.assistant.handleFromChat("How long does it take to walk to Hyde Park?", now: now)
        XCTAssertEqual(DepartureAssistantGeminiStub.recorder.bodies.count, 2)
        _ = try await rig.assistant.handle("Thanks", now: now)
        XCTAssertEqual(DepartureAssistantGeminiStub.recorder.bodies.count, 3)
        let sent = await rig.routes.requests
        XCTAssertEqual(sent.count, 3)
    }

    // MARK: 「使用 Google 地圖規劃出發時間？」

    /// Not now: nothing is read or sent, the answer is kept, the reply says how to turn it on, Gemini is told not_set,
    /// and the next chat request is main's.
    func testNotNowOnTheFirstPlanSendsNothingAndTurnsTheFeatureOff() async throws {
        let rig = await makeRig(events: [meeting()], consent: .notAsked, allowWhenAsked: false)
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        let steps = await rig.trail.steps
        XCTAssertEqual(steps, ["ask"], "asked once; no location read and nothing sent to Google")
        XCTAssertEqual(rig.consent.read(), .declined)
        XCTAssertEqual(reply.text, "OK. Departure planning stays off. You can turn it on in Settings › Assistant.")
        XCTAssertFalse(reply.changed)
        let writes = await rig.google.writes
        XCTAssertTrue(writes.isEmpty)

        // The next chat request has no plan_departure, in its declarations or its history.
        _ = try await rig.assistant.handleFromChat("OK", now: now)
        let requests = try sentRequests()
        XCTAssertEqual(requests.count, 2)
        try await assertMainsRequest(try XCTUnwrap(requests.last), rig: rig)

        // Turned on again in Settings › Assistant: the history shows what Gemini was told.
        rig.consent.write(.allowed)
        let told = try await toldGemini(rig, now: now)
        XCTAssertEqual(told, [reminders("not_set")])
    }

    /// Allow: asked once, before the location is read or Google is asked, and kept; the plan goes ahead.
    func testAllowOnTheFirstPlanIsAskedOnceBeforeTheLocationIsRead() async throws {
        let rig = await makeRig(events: [meeting()], consent: .notAsked, allowWhenAsked: true)
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28)), route(.walk, leave: now, arrive: at(14, 25))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#),
               call("plan_departure", #"{"destination": "Hyde Park", "travel_mode": "walking"}"#))
        let first = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        var steps = await rig.trail.steps
        XCTAssertEqual(steps, ["ask", "location", "route"])
        XCTAssertEqual(rig.consent.read(), .allowed)
        XCTAssertNotNil(first.departure)
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH"])

        _ = try await rig.assistant.handleFromChat("How long does it take to walk to Hyde Park?", now: now)
        steps = await rig.trail.steps
        XCTAssertEqual(steps, ["ask", "location", "route", "location", "route"], "not asked again")
    }

    // MARK: Where from

    /// A starting point the user said goes to Google as written; the location isn't read (it would fail here).
    func testAStartingPointTheUserSaidIsUsedInsteadOfTheLocation() async throws {
        let rig = await makeRig(events: [meeting()], location: FakeLocation(result: .failure(.noPermission)))
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1", "starting_point": "King's Cross"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave King's Cross for the meeting?", now: now)

        let sent = await rig.routes.requests
        XCTAssertEqual(sent, [routeRequest(origin: .typed("King's Cross"), arriveBy: at(16, 30))])
        XCTAssertEqual(reply.departure?.shown,
                       "Based on being at Taipei 101 by 16:30, leave at 15:48.\nYou can plan 1 more this week.")
        let writes = await rig.google.writes
        XCTAssertEqual(writes.map(\.method), ["PATCH"])
    }

    /// Without location permission: the reply asks for a starting point, and Google isn't asked.
    func testWithoutLocationPermissionTheReplyAsksWhereFrom() async throws {
        let rig = await makeRig(events: [meeting()], location: FakeLocation(result: .failure(.noPermission)))
        await rig.routes.answer([route(leave: at(15, 48), arrive: at(16, 28))])
        answer(call("plan_departure", #"{"event_id": "meeting1"}"#))
        let reply = try await rig.assistant.handleFromChat("When should I leave for the meeting?", now: now)

        XCTAssertEqual(reply.text, "Allow Location for Smart Schedules in Settings, or say where you're leaving from.")
        XCTAssertFalse(reply.changed)
        await assertNothingPlanned(rig)
    }
}

// MARK: - Fakes

/// What Gemini was sent, read back from one request body.
private struct DepartureAssistantRequest {
    let raw: String
    let system: String
    let declarations: NSArray
    let allowed: [String]
    let mode: String?
    let contents: [[String: Any]]

    /// The names of the declared functions, in order.
    var declared: [String] {
        (declarations as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    init(_ body: Data) throws {
        raw = String(decoding: body, as: UTF8.self)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instruction = root["systemInstruction"] as? [String: Any]
        let parts = instruction?["parts"] as? [[String: Any]]
        system = try XCTUnwrap(parts?.first?["text"] as? String)
        let tools = root["tools"] as? [[String: Any]]
        declarations = try XCTUnwrap(tools?.first?["functionDeclarations"] as? NSArray)
        let config = (root["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        allowed = try XCTUnwrap(config?["allowedFunctionNames"] as? [String])
        mode = config?["mode"] as? String
        contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
    }

    /// The `response` of every functionResponse to `name` in the history, oldest first.
    func responses(named name: String) -> [NSDictionary] {
        contents.flatMap { content -> [NSDictionary] in
            (content["parts"] as? [[String: Any]] ?? []).compactMap { part -> NSDictionary? in
                guard let answer = part["functionResponse"] as? [String: Any],
                      answer["name"] as? String == name else { return nil }
                return answer["response"] as? NSDictionary
            }
        }
    }
}

/// Answers each Gemini request with the next queued response (a plain reply once none is left) and keeps every
/// request body. A response may hold several function calls in one model turn.
private final class DepartureAssistantGeminiStub: URLProtocol {
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
            if queued.isEmpty { return DepartureAssistantGeminiStub.call("reply_to_user", #"{"message": "OK"}"#) }
            return queued.removeFirst()
        }
    }

    static let recorder = Recorder()

    /// A Gemini response with one function call; `args` is its JSON object.
    static func call(_ name: String, _ args: String) -> String {
        turn([(name: name, args: args)])
    }

    /// A Gemini response whose model turn holds these function calls, in order.
    static func turn(_ calls: [(name: String, args: String)]) -> String {
        let parts = calls.map { #"{"functionCall": {"name": "\#($0.name)", "args": \#($0.args)}}"# }
            .joined(separator: ", ")
        return #"{"candidates": [{"content": {"role": "model", "parts": [\#(parts)]}, "finishReason": "STOP"}]}"#
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

/// One request to Google Calendar, as the fake received it.
private struct DepartureAssistantGoogleRequest: Sendable {
    let method: String
    let url: URL?
    let body: Data?
}

/// Google Calendar: keeps every request. An insert or a PATCH is saved as it was sent (the body comes back); anything
/// else gets an empty list.
private actor DepartureAssistantGoogle: CalendarTransport {
    private(set) var requests: [DepartureAssistantGoogleRequest] = []

    /// The requests that change something (inserts and PATCHes), not the reads.
    var writes: [DepartureAssistantGoogleRequest] {
        requests.filter { $0.method != "GET" }
    }

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        "test-token"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(DepartureAssistantGoogleRequest(method: request.httpMethod ?? "GET", url: request.url,
                                                        body: request.httpBody))
        let url = request.url ?? URL(string: "https://www.googleapis.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (request.httpBody ?? Data(#"{"items":[]}"#.utf8), response)
    }
}

/// What the departure flow did, in order: "ask" (「使用 Google 地圖規劃出發時間？」), "location", "route".
private actor DepartureAssistantTrail {
    private(set) var steps: [String] = []

    func note(_ step: String) {
        steps.append(step)
    }
}

/// The routes server: keeps every request and gives the queued answers in order (unavailable once none is left).
private actor DepartureAssistantRoutes: DepartureRouting {
    private(set) var requests: [DepartureRouteRequest] = []
    private var answers: [Result<DepartureRouteResult, DepartureRouteError>] = []
    private let trail: DepartureAssistantTrail

    init(trail: DepartureAssistantTrail) {
        self.trail = trail
    }

    func answer(_ results: [Result<DepartureRouteResult, DepartureRouteError>]) {
        answers += results
    }

    func route(_ request: DepartureRouteRequest) async throws -> DepartureRouteResult {
        requests.append(request)
        await trail.note("route")
        guard !answers.isEmpty else { throw DepartureRouteError.unavailable }
        return try answers.removeFirst().get()
    }
}

/// The iPhone's location, noted on the trail each time it is read.
private struct DepartureAssistantLocation: LocationProviding {
    let trail: DepartureAssistantTrail
    let result: Result<GeoPoint, TravelTimeError>

    func currentLocation() async throws -> GeoPoint {
        await trail.note("location")
        return try result.get()
    }
}
