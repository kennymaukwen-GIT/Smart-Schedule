import XCTest

/// The router's seam for the sample calendars (`CalendarRouter+Sample.swift`): a write to a demo account's calendar
/// stays in the cache with `demo-` ids and never reaches Google, the outbox or a refresh; once demo mode has ended it
/// is refused and nothing changes; an account store pinned to the samples never lists a real calendar, and its router
/// refuses a real calendar; outside demo mode, writes to a real account's calendar go to Google (or the outbox) as
/// before.
final class SampleCalendarRouterTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())
    /// Tuesday 2026-10-13 22:50 BST, the fixture's now_local.
    private let now = TestClock.local(2026, 10, 13, 22, 50)
    private let realCalendar = SampleAccounts.calendar("111", "kenny@example.com", email: "kenny@example.com",
                                                       primary: true)

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let router: CalendarRouter
        let store: SharedStore
        let outbox: SyncOutbox
        let google: SampleRouterGoogle
    }

    /// The router's accounts are pinned to the samples (as `AccountStore.sampleCalendarsOnly()` is) unless `pinned` is
    /// false, and their file also holds a real account. `demoActive` is what the cache's own account store says: the
    /// live demo flag.
    private func makeRig(demoActive: Bool = true, pinned: Bool = true) async -> Rig {
        let file = files.url("SampleCalendarRouterTests-accounts")
        let accounts = AccountStore(fileURL: file, isDemoMode: { pinned }, defaultCalendar: { nil })
        await accounts.upsert(SampleAccounts.account("111", email: "kenny@example.com"))
        let live = AccountStore(fileURL: file, isDemoMode: { demoActive }, defaultCalendar: { nil })
        let store = SharedStore(fileURL: files.url("SampleCalendarRouterTests-cache"), accounts: live)
        let outbox = SyncOutbox(fileURL: files.url("SampleCalendarRouterTests-outbox"))
        let google = SampleRouterGoogle()
        let router = CalendarRouter(accounts: accounts, tokens: GoogleTokenProvider(accounts: accounts), store: store,
                                    clock: TestClock.clock, transport: google, outbox: outbox)
        return Rig(router: router, store: store, outbox: outbox, google: google)
    }

    /// "1個小時後買蛋給 Jocelyn" said at 22:50, as Gemini answers it (`create_events.relative_time.json`), mapped the
    /// way `ScheduleAssistant` maps a new event: created at `now`, so the 23:50 task gets 10 minutes before and at start.
    private func relativeTimeEvent(seed: String = "s|0") throws -> MappedEvent {
        let name = "create_events.relative_time.json"
        let draft = try XCTUnwrap(Fixtures.args(CreateEventsArgs.self, from: name).events.first)
        return try mapper.event(from: draft, seed: seed, utterance: Fixtures.utterance(name), createdAt: now)
    }

    private func repeating(_ title: String, start: String, minutes: Int, kind: String = "event",
                           rule: RecurrenceDraft, seed: String) throws -> MappedEvent {
        let draft = EventDraft(title: title, start: start, durationMinutes: minutes, kind: kind, recurrence: rule)
        return try mapper.event(from: draft, seed: seed, utterance: title)
    }

    /// Nothing left this iPhone and nothing waits to be sent.
    private func assertNothingReachedGoogle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await rig.google.calls
        XCTAssertEqual(calls, 0, "no token or request", file: file, line: line)
        let waiting = await rig.outbox.items()
        XCTAssertTrue(waiting.isEmpty, "nothing in the outbox", file: file, line: line)
    }

    private func assertDemoEnded(_ write: () async throws -> Void, file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            try await write()
            XCTFail("expected DemoCalendarError.demoEnded", file: file, line: line)
        } catch DemoCalendarError.demoEnded {
            // expected
        } catch {
            XCTFail("expected DemoCalendarError.demoEnded, got \(error)", file: file, line: line)
        }
    }

    private func assertSampleCalendarsOnly(_ write: () async throws -> Void, file: StaticString = #filePath,
                                           line: UInt = #line) async {
        do {
            try await write()
            XCTFail("expected DemoCalendarError.sampleCalendarsOnly", file: file, line: line)
        } catch DemoCalendarError.sampleCalendarsOnly {
            // expected
        } catch {
            XCTFail("expected DemoCalendarError.sampleCalendarsOnly, got \(error)", file: file, line: line)
        }
    }

    // MARK: Insert

    func testATimeCountedFromNowIsAddedToTheSampleCalendarOnly() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        XCTAssertEqual(target.id, DemoData.personalCalendar)

        let saved = try await rig.router.insert([relativeTimeEvent()], into: target, mapper: mapper, now: now)
        XCTAssertEqual(saved.count, 1)
        let event = try XCTUnwrap(saved.first)
        XCTAssertTrue(event.id.hasPrefix("demo-"), event.id)
        XCTAssertNil(event.seriesID)
        XCTAssertEqual(event.accountID, DemoData.personalAccountID)
        XCTAssertEqual(event.calendarID, DemoData.personalEmail)
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.end, TestClock.local(2026, 10, 14, 0, 20))
        XCTAssertEqual(event.reminderMinutes, [10, 0], "created at 22:50 for later the same day")
        XCTAssertFalse(event.isWaitingToSync)

        // Demo mode shows it, like every sample event.
        let shown = await rig.store.events(in: DateInterval(start: now, duration: 86_400))
        XCTAssertEqual(shown.map(\.id), [event.id])
        await assertNothingReachedGoogle(rig)
    }

    func testAWeeklySeriesExpandsTwentySixWeeksAhead() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        // Wednesday 2026-10-14 18:00, every Wednesday: 26 weeks from now ends before Wednesday 2027-04-14.
        let piano = try repeating("Piano lesson", start: "2026-10-14T18:00", minutes: 45,
                                  rule: RecurrenceDraft(frequency: "WEEKLY", byWeekday: ["WE"]), seed: "s|weekly")
        let saved = try await rig.router.insert([piano], into: target, mapper: mapper, now: now)

        XCTAssertEqual(saved.count, 26)
        let seriesID = try XCTUnwrap(piano.body.id.map { "demo-" + $0 })
        XCTAssertEqual(Set(saved.compactMap(\.seriesID)), [seriesID])
        XCTAssertTrue(saved.allSatisfy { $0.id.hasPrefix("demo-") && $0.seriesID != nil })
        XCTAssertTrue(saved.allSatisfy { $0.calendarRef == DemoData.personalCalendar })
        XCTAssertEqual(saved.first?.start, TestClock.local(2026, 10, 14, 18, 0))
        XCTAssertEqual(saved.last?.start, TestClock.local(2027, 4, 7, 18, 0), "18:00 on both sides of the clock changes")
        XCTAssertTrue(saved.allSatisfy { $0.duration == 45 * 60 })
        let cached = await rig.store.snapshot().events.filter { $0.seriesID == seriesID }
        XCTAssertEqual(cached.count, 26)
        await assertNothingReachedGoogle(rig)
    }

    func testADailySeriesHasSevenEventsAWeek() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        let stretch = try repeating("Stretch", start: "2026-10-14T07:00", minutes: 15, kind: "routine",
                                    rule: RecurrenceDraft(frequency: "DAILY"), seed: "s|daily")
        let saved = try await rig.router.insert([stretch], into: target, mapper: mapper, now: now)

        let firstWeek = DateInterval(start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 21))
        XCTAssertEqual(saved.filter { firstWeek.contains($0.start) }.count, 7)
        XCTAssertEqual(saved.count, 182, "every day from 14 Oct to 13 Apr")
        XCTAssertEqual(Set(saved.compactMap(\.seriesID)).count, 1)
        XCTAssertTrue(saved.allSatisfy { $0.id.hasPrefix("demo-") })
        await assertNothingReachedGoogle(rig)
    }

    func testOtherRepeatsAreAddedOnce() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        let book = try repeating("Book club", start: "2026-10-20T19:00", minutes: 60,
                                 rule: RecurrenceDraft(frequency: "MONTHLY"), seed: "s|monthly")
        let water = try repeating("Water the plants", start: "2026-10-14T08:00", minutes: 15,
                                  rule: RecurrenceDraft(frequency: "DAILY", interval: 2), seed: "s|every-other-day")
        let saved = try await rig.router.insert([book, water], into: target, mapper: mapper, now: now)

        XCTAssertEqual(saved.map(\.title), ["Book club", "Water the plants"])
        XCTAssertTrue(saved.allSatisfy { $0.seriesID == nil && $0.id.hasPrefix("demo-") })
        XCTAssertEqual(saved.first?.start, TestClock.local(2026, 10, 20, 19, 0))
        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.count, 2)
        await assertNothingReachedGoogle(rig)
    }

    func testOnlyAnEveryDayRuleBecomesWeekly() {
        func rule(_ rrule: String?) -> String? {
            var body = GCalEvent()
            body.recurrence = rrule.map { [$0] }
            return CalendarRouter.weeklyEquivalent(body).recurrence?.first
        }
        XCTAssertEqual(rule("RRULE:FREQ=DAILY"), "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU")
        XCTAssertEqual(rule("RRULE:FREQ=DAILY;COUNT=5"), "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=5")
        XCTAssertEqual(rule("RRULE:FREQ=DAILY;BYDAY=MO,WE;UNTIL=20261130T235959Z"),
                       "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261130T235959Z")
        XCTAssertEqual(rule("RRULE:FREQ=DAILY;INTERVAL=2"), "RRULE:FREQ=DAILY;INTERVAL=2")
        XCTAssertEqual(rule("RRULE:FREQ=MONTHLY"), "RRULE:FREQ=MONTHLY")
        XCTAssertEqual(rule("RRULE:FREQ=WEEKLY;BYDAY=TU"), "RRULE:FREQ=WEEKLY;BYDAY=TU")
        XCTAssertNil(rule(nil))
    }

    // MARK: Patch

    func testPatchChangesTheCachedCopy() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        let saved = try await rig.router.insert([relativeTimeEvent()], into: target, mapper: mapper, now: now)
        let event = try XCTUnwrap(saved.first)

        var change = GCalEvent()
        change.summary = "買蛋和牛奶給 Jocelyn"
        change.location = "Tesco"
        change.start = mapper.timed(TestClock.local(2026, 10, 14, 9, 0))
        change.end = mapper.timed(TestClock.local(2026, 10, 14, 9, 30))
        let updated = try await rig.router.patch(event, body: change, mapper: mapper, now: now)
        XCTAssertEqual(updated?.id, event.id)
        XCTAssertEqual(updated?.title, "買蛋和牛奶給 Jocelyn")

        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.count, 1)
        let copy = try XCTUnwrap(cached.first)
        XCTAssertEqual(copy.ref, event.ref)
        XCTAssertEqual(copy.title, "買蛋和牛奶給 Jocelyn")
        XCTAssertEqual(copy.location, "Tesco")
        XCTAssertEqual(copy.start, TestClock.local(2026, 10, 14, 9, 0))
        XCTAssertEqual(copy.end, TestClock.local(2026, 10, 14, 9, 30))
        XCTAssertEqual(copy.reminderMinutes, [10, 0], "unchanged")
        await assertNothingReachedGoogle(rig)
    }

    func testPatchSeriesMovesEverySeededYogaClass() async throws {
        let rig = await makeRig()
        await rig.store.replaceWindow(DemoData.seedWindow(now: now, clock: TestClock.clock),
                                      with: DemoData.events(now: now, clock: TestClock.clock))
        let before = await rig.store.snapshot().events
        let yoga = before.filter { $0.seriesID == "demo-yoga" }
        XCTAssertGreaterThan(yoga.count, 1)
        let gym = before.filter { $0.seriesID == "demo-gym" }
        let open = try XCTUnwrap(yoga.first)

        var change = GCalEvent()
        change.summary = "Morning yoga"
        let queued = try await rig.router.patchSeries(of: open, body: change,
                                                      newStart: TestClock.local(2026, 10, 17, 10, 30),
                                                      duration: TimeInterval(90 * 60), mapper: mapper, now: now)
        XCTAssertFalse(queued)

        let after = await rig.store.snapshot().events
        let calendar = TestClock.clock.calendar
        for old in yoga {
            let moved = try XCTUnwrap(after.first { $0.ref == old.ref }, old.id)
            XCTAssertEqual(moved.title, "Morning yoga", old.id)
            XCTAssertTrue(calendar.isDate(moved.start, inSameDayAs: old.start), old.id)
            XCTAssertEqual(calendar.component(.hour, from: moved.start), 10, old.id)
            XCTAssertEqual(calendar.component(.minute, from: moved.start), 30, old.id)
            XCTAssertEqual(moved.duration, 90 * 60, old.id)
        }
        XCTAssertEqual(after.filter { $0.seriesID == "demo-gym" }, gym, "another series in the same calendar")
        XCTAssertEqual(after.count, before.count)
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Delete

    func testAPlanCanBeFoundAndDeletedWithEveryOccurrence() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        let name = "create_long_term_plan.muscle.json"
        let plan = try Fixtures.args(LongTermPlanArgs.self, from: name)
        let planID = "plan-muscle-6m"
        let mapped = try mapper.events(fromPlan: plan, planID: planID, utterance: Fixtures.utterance(name))
        let saved = try await rig.router.insert(mapped, into: target, mapper: mapper, now: now)
        XCTAssertTrue(saved.allSatisfy { $0.planID == planID && $0.id.hasPrefix("demo-") })
        XCTAssertEqual(Set(saved.compactMap(\.seriesID)).count, 6, "one series per session")
        XCTAssertEqual(saved.filter { $0.seriesID == nil }.count, 6, "the milestones")

        let refs = try await rig.router.planEventRefs(planID: planID, now: now)
        XCTAssertEqual(refs.count, 12)
        XCTAssertTrue(refs.allSatisfy { $0.accountID == DemoData.personalAccountID && $0.eventID.hasPrefix("demo-") })

        let queued = try await rig.router.delete(refs, now: now)
        XCTAssertFalse(queued)
        let left = await rig.store.snapshot().events
        XCTAssertTrue(left.isEmpty, "\(left.count) left")
        await assertNothingReachedGoogle(rig)
    }

    func testDeletingARefWithoutACalendarRemovesTheSampleEvent() async throws {
        let rig = await makeRig()
        let target = try await rig.router.defaultTarget()
        let saved = try await rig.router.insert([relativeTimeEvent()], into: target, mapper: mapper, now: now)
        let event = try XCTUnwrap(saved.first)

        let unscoped = EventRef(accountID: nil, calendarID: nil, eventID: event.id)
        let queued = try await rig.router.delete([unscoped], now: now)
        XCTAssertFalse(queued)
        let left = await rig.store.snapshot().events
        XCTAssertTrue(left.isEmpty)
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Demo mode ended

    func testOnceDemoModeHasEndedNothingIsWritten() async throws {
        let rig = await makeRig(demoActive: false)
        let seeded = DemoData.events(now: now, clock: TestClock.clock)
        await rig.store.upsert(seeded)
        let router = rig.router, mapper = self.mapper, now = self.now
        let sample = try XCTUnwrap(DemoData.accounts.first?.primaryCalendar)
        let dentist = try XCTUnwrap(seeded.first { $0.id == "demo-dentist" })
        let gym = try XCTUnwrap(seeded.first { $0.seriesID == "demo-gym" })
        let event = try relativeTimeEvent()
        var change = GCalEvent()
        change.summary = "Changed"

        await assertDemoEnded { _ = try await router.insert([event], into: sample, mapper: mapper, now: now) }
        await assertDemoEnded { _ = try await router.patch(dentist, body: change, mapper: mapper, now: now) }
        await assertDemoEnded { _ = try await router.patchSeries(of: gym, body: change, mapper: mapper, now: now) }
        await assertDemoEnded { _ = try await router.delete([dentist.ref], now: now) }

        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.count, seeded.count, "nothing added or removed")
        XCTAssertFalse(cached.contains { $0.title == "Changed" || $0.title == "買蛋給 Jocelyn" })
        await assertNothingReachedGoogle(rig)
        XCTAssertEqual(DemoCalendarError.demoEnded.errorDescription, "Demo mode has ended, so nothing was changed.")
    }

    // MARK: Accounts

    func testAPinnedAccountStoreListsOnlyTheSampleCalendars() async {
        let file = files.url("SampleCalendarRouterTests-pinned")
        let real = AccountStore(fileURL: file, isDemoMode: { false }, defaultCalendar: { nil })
        await real.upsert(SampleAccounts.account("111", email: "kenny@example.com"))
        // Even with a real calendar picked for new events in Settings.
        let picked = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
        let pinned = AccountStore(fileURL: file, isDemoMode: { true }, defaultCalendar: { picked })

        let calendars = await pinned.calendars()
        XCTAssertEqual(calendars.map(\.id), DemoData.accounts.flatMap(\.calendars).map(\.id))
        XCTAssertTrue(calendars.allSatisfy { CalendarRouter.isSample($0.id) })
        let target = await pinned.defaultWriteTarget()
        XCTAssertEqual(target?.id, DemoData.personalCalendar)
        let synced = await pinned.syncedCalendars()
        XCTAssertTrue(synced.isEmpty)
        // The stored account is still there for sign-in.
        let connected = await pinned.connectedAccounts()
        XCTAssertEqual(connected.map(\.id), ["111"])

        // The App Group store, pinned the same way.
        let sampleOnly = await AccountStore.sampleCalendarsOnly().calendars()
        XCTAssertEqual(sampleOnly.map(\.id), DemoData.accounts.flatMap(\.calendars).map(\.id))
    }

    func testOnlyDemoAccountsAreSample() {
        XCTAssertTrue(CalendarRouter.isSample(DemoData.personalCalendar))
        XCTAssertTrue(CalendarRouter.isSample(DemoData.gymCalendar))
        XCTAssertTrue(CalendarRouter.isSample(DemoData.schoolCalendar))
        XCTAssertFalse(CalendarRouter.isSample(realCalendar.id))
        XCTAssertFalse(CalendarRouter.isSample(CalendarRef(accountID: "", calendarID: "primary")))
    }

    // MARK: Real calendars

    /// Whatever reaches demo mode's router (a hidden copy of a real event, an id Gemini made up), a real calendar is
    /// neither sent to nor queued for.
    func testAPinnedRouterNeverWritesARealCalendar() async throws {
        let rig = await makeRig()
        let real = TestEvents.make(id: "realdentist1", title: "Dentist", start: TestClock.local(2026, 10, 14, 9),
                                   end: TestClock.local(2026, 10, 14, 10), calendar: realCalendar.id)
        await rig.store.upsert([real])
        let router = rig.router, mapper = self.mapper, now = self.now, realCalendar = self.realCalendar
        let event = try relativeTimeEvent()
        var change = GCalEvent()
        change.summary = "Changed"

        await assertSampleCalendarsOnly { _ = try await router.insert([event], into: realCalendar, mapper: mapper, now: now) }
        await assertSampleCalendarsOnly { _ = try await router.patch(real, body: change, mapper: mapper, now: now) }
        await assertSampleCalendarsOnly { _ = try await router.patchSeries(of: real, body: change, mapper: mapper, now: now) }
        await assertSampleCalendarsOnly { _ = try await router.delete([real.ref], now: now) }

        let cached = await rig.store.snapshot().events
        XCTAssertEqual(cached.map(\.title), ["Dentist"], "the real event is untouched")
        await assertNothingReachedGoogle(rig)
        XCTAssertEqual(DemoCalendarError.sampleCalendarsOnly.errorDescription,
                       "Demo mode changes only the sample calendars, so nothing was changed.")
    }

    func testOutsideDemoModeAnInsertIntoARealCalendarGoesToGoogleOrTheOutbox() async throws {
        let rig = await makeRig(demoActive: false, pinned: false)
        let sent = try await rig.router.insert([relativeTimeEvent(seed: "s|online")], into: realCalendar,
                                               mapper: mapper, now: now)
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(sent.contains { $0.id.hasPrefix("demo-") })
        XCTAssertEqual(sent.first?.accountID, "111")
        XCTAssertEqual(sent.first?.isWaitingToSync, false)
        let online = await rig.google.calls
        XCTAssertGreaterThan(online, 0, "sent to Google")
        var waiting = await rig.outbox.pending()
        XCTAssertTrue(waiting.isEmpty)

        await rig.google.setOffline(true)
        let queued = try await rig.router.insert([relativeTimeEvent(seed: "s|offline")], into: realCalendar,
                                                 mapper: mapper, now: now)
        XCTAssertEqual(queued.map(\.isWaitingToSync), [true])
        XCTAssertFalse(queued.contains { $0.id.hasPrefix("demo-") })
        let offline = await rig.google.calls
        XCTAssertGreaterThan(offline, online, "tried Google first")
        waiting = await rig.outbox.pending()
        XCTAssertEqual(waiting.map(\.kind), [.insert])
        XCTAssertEqual(waiting.first?.calendar, realCalendar.id)
    }
}

/// Counts every token request and Calendar API request. Online, Google saves an insert as it was sent (the request
/// body comes back); offline, it fails like a phone without a connection.
private actor SampleRouterGoogle: CalendarTransport {
    private(set) var calls = 0
    private var isOffline = false

    func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        calls += 1
        return "test-token"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        if isOffline { throw URLError(.notConnectedToInternet) }
        let url = request.url ?? URL(string: "https://www.googleapis.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (request.httpBody ?? Data(#"{"items":[]}"#.utf8), response)
    }
}
