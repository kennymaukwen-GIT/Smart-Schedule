import XCTest

/// The App Group cache with several accounts: copies keyed by account, calendar and id, per-calendar windows and
/// coverage, purging an account, and the "Ask me first" batch slot.
final class SharedStoreAccountTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private let personal = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
    private let school = CalendarRef(accountID: "222", calendarID: "student@university.example.edu")
    /// The rolling window for "now" = Tue 13 Oct 2026 (−7 d … +120 d).
    private let window = DateInterval(start: TestClock.local(2026, 10, 6), end: TestClock.local(2027, 2, 10))

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func makeStores(demo: Bool = false) async -> (SharedStore, AccountStore) {
        let accounts = AccountStore(fileURL: files.url("SharedStoreAccountTests-accounts"),
                                    isDemoMode: { demo }, defaultCalendar: { nil })
        await accounts.upsert(SampleAccounts.account("111", email: "kenny@example.com"))
        await accounts.upsert(SampleAccounts.account("222", email: "student@university.example.edu"))
        return (SharedStore(fileURL: files.url("SharedStoreAccountTests-cache"), accounts: accounts), accounts)
    }

    private func event(_ id: String, _ calendar: CalendarRef?, _ year: Int = 2026, _ month: Int = 10, _ day: Int = 14,
                       hour: Int = 9, uid: String? = nil, organizer: Bool? = nil,
                       seriesID: String? = nil, planID: String? = nil, title: String = "Event") -> ScheduleEvent {
        TestEvents.make(id: id, title: title, start: TestClock.local(year, month, day, hour),
                        end: TestClock.local(year, month, day, hour + 1), seriesID: seriesID, planID: planID,
                        calendar: calendar, iCalUID: uid, isOrganizer: organizer)
    }

    // MARK: Identity

    func testTheSameIDInTwoCalendarsIsTwoCopiesAndOneVisibleEvent() async {
        let (store, _) = await makeStores()
        let attendee = event("m1", personal, uid: "m1@google.com", organizer: false, title: "Design review")
        let organizer = event("m1", school, uid: "m1@google.com", organizer: true, title: "Design review")
        await store.upsert([attendee, organizer])

        var cached = await store.snapshot().events
        XCTAssertEqual(cached.count, 2)
        let visible = await store.visibleEvents()
        XCTAssertEqual(visible.map(\.calendarRef), [school])
        let day = DateInterval(start: TestClock.local(2026, 10, 14), end: TestClock.local(2026, 10, 15))
        let inDay = await store.events(in: day)
        XCTAssertEqual(inDay.count, 1)
        let byID = await store.event(id: "m1")
        XCTAssertEqual(byID?.calendarRef, school)

        // Upserting one copy replaces only that copy.
        var renamed = attendee
        renamed.title = "Design review (moved room)"
        await store.upsert([renamed])
        cached = await store.snapshot().events
        XCTAssertEqual(cached.count, 2)
        XCTAssertEqual(cached.first { $0.calendarRef == personal }?.title, "Design review (moved room)")
        XCTAssertEqual(cached.first { $0.calendarRef == school }?.title, "Design review")
    }

    func testHiddenCalendarsLeaveVisibleEventsButCanStillBeOpened() async {
        let (store, accounts) = await makeStores()
        await store.upsert([event("a", personal), event("b", school, hour: 10)])
        await accounts.setVisible(false, calendar: school)
        await accounts.setNotificationsEnabled(false, calendar: personal)

        let display = await store.visibleEvents(audience: .display)
        XCTAssertEqual(display.map(\.id), ["a"])
        let reminders = await store.visibleEvents(audience: .reminders)
        XCTAssertTrue(reminders.isEmpty)
        let hidden = await store.event(id: "b")
        XCTAssertEqual(hidden?.calendarRef, school)
    }

    func testRemovingRefsLeavesOtherCalendarsCopies() async {
        let (store, _) = await makeStores()
        await store.upsert([
            event("s_1", personal, seriesID: "s"), event("s_2", personal, 2026, 10, 21, seriesID: "s"),
            event("s_1", school, seriesID: "s"), event("single", personal, hour: 12)
        ])
        await store.remove([EventRef(accountID: "111", calendarID: "kenny@example.com", eventID: "s")], includingSeries: true)
        var left = await store.snapshot().events.map { "\($0.accountID ?? "-")/\($0.id)" }
        XCTAssertEqual(Set(left), ["222/s_1", "111/single"])

        await store.remove([EventRef(accountID: "111", calendarID: "kenny@example.com", eventID: "single")])
        left = await store.snapshot().events.map { "\($0.accountID ?? "-")/\($0.id)" }
        XCTAssertEqual(left, ["222/s_1"])
    }

    // MARK: Windows and coverage

    func testOneCalendarsWindowLeavesTheOthersAlone() async {
        let (store, _) = await makeStores()
        let far = event("far", personal, 2027, 6, 1)
        await store.upsert([event("old", personal), event("theirs", school), far])

        // The listing is stamped with the calendar even if the mapper did not.
        await store.replaceWindow(window, calendar: personal, with: [event("new", nil, hour: 15)])
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), ["new", "theirs", "far"])
        XCTAssertEqual(snapshot.events.first { $0.id == "new" }?.calendarRef, personal)
        XCTAssertEqual(snapshot.window, window)
        XCTAssertNotNil(snapshot.lastRefresh)
        let personalCoverage = await store.coverage(for: personal)
        XCTAssertEqual(personalCoverage.intervals, [window])
        let schoolCoverage = await store.coverage(for: school)
        XCTAssertTrue(schoolCoverage.isEmpty)
    }

    func testCoverageIsWhatEverySyncedCalendarHas() async {
        let (store, _) = await makeStores()
        await store.replaceWindow(window, calendar: personal, with: [])
        var coverage = await store.coverage()
        XCTAssertTrue(coverage.isEmpty, "a new account has nothing yet, so the range on screen loads for it")

        let autumn = DateInterval(start: TestClock.local(2026, 10, 1), end: TestClock.local(2026, 12, 1))
        await store.mergeRange(autumn, calendar: school, with: [event("s", school, 2026, 11, 2)])
        coverage = await store.coverage()
        XCTAssertEqual(coverage.intervals, [DateInterval(start: window.start, end: autumn.end)])
        let year = DateInterval(start: TestClock.local(2026, 10, 1), end: TestClock.local(2027, 1, 1))
        XCTAssertEqual(coverage.missing(in: year), [DateInterval(start: autumn.start, end: window.start),
                                                    DateInterval(start: autumn.end, end: year.end)])
        // Each calendar lists only its own gaps.
        let schoolGaps = await store.coverage(for: school).missing(in: year)
        XCTAssertEqual(schoolGaps, [DateInterval(start: autumn.end, end: year.end)])

        // Demo seeding replaces every event in the window, so every calendar's coverage is forgotten.
        await store.replaceWindow(window, with: [])
        let forgotten = await store.coverage(for: school)
        XCTAssertTrue(forgotten.isEmpty)
    }

    func testDemoModeUsesTheCalendarLessCoverage() async {
        let (store, _) = await makeStores(demo: true)
        await store.mergeRange(window, calendar: personal, with: [])
        let seeded = DemoData.seedWindow(now: TestClock.local(2026, 10, 13, 10), clock: TestClock.clock)
        await store.replaceWindow(seeded, with: [])
        let coverage = await store.coverage()
        XCTAssertEqual(coverage.intervals, [seeded])
    }

    func testMergingACalendarsRangeReplacesOnlyThatCalendar() async {
        let (store, _) = await makeStores()
        let october = DateInterval(start: TestClock.local(2027, 10, 1), end: TestClock.local(2027, 11, 1))
        await store.upsert([event("deleted", personal, 2027, 10, 5), event("kept", school, 2027, 10, 5),
                            event("moved", personal, 2027, 9, 20)])
        await store.mergeRange(october, calendar: personal, with: [event("moved", personal, 2027, 10, 20)])
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), ["kept", "moved"])
        XCTAssertEqual(snapshot.events.first { $0.id == "moved" }?.start, TestClock.local(2027, 10, 20, 9))
        XCTAssertTrue(snapshot.loadedRanges.isEmpty, "calendar-less ranges are for demo data")
        let covered = await store.coverage(for: personal)
        XCTAssertEqual(covered.intervals, [october])
    }

    func testTheCacheCapTrimsEveryCalendarsCoverage() async {
        let (store, _) = await makeStores()
        await store.replaceWindow(window, calendar: personal, with: [event("near", personal, 2026, 11, 2)])
        let far = DateInterval(start: TestClock.local(2029, 3, 1), end: TestClock.local(2029, 4, 1))
        await store.mergeRange(far, calendar: personal, with: [event("far-a", personal, 2029, 3, 3), event("far-b", personal, 2029, 3, 4)])
        await store.mergeRange(far, calendar: school, with: [event("far-c", school, 2029, 3, 5)])
        let today = DateInterval(start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 14))
        let keep = LoadedRanges.keepZones(around: [today], months: 12, calendar: TestClock.clock.calendar)

        let dropped = await store.evictEvents(outside: keep, whenCountExceeds: 2)
        XCTAssertEqual(dropped, 3)
        let personalCoverage = await store.coverage(for: personal)
        XCTAssertEqual(personalCoverage.intervals, [window])
        let schoolCoverage = await store.coverage(for: school)
        XCTAssertTrue(schoolCoverage.isEmpty)
    }

    // MARK: Accounts leaving

    func testPurgingAnAccountRemovesItsEventsCoverageAndOrphanedNudges() async {
        let (store, _) = await makeStores()
        await store.upsert([event("p", personal, planID: "plan-1"), event("s", school, planID: "plan-2"),
                            event("both", school, hour: 11, planID: "plan-3"), event("both", personal, hour: 11, planID: "plan-3")])
        await store.replaceWindow(window, calendar: school, with: [event("s", school, planID: "plan-2"),
                                                                   event("both", school, hour: 11, planID: "plan-3")])
        await store.replaceWindow(window, calendar: personal, with: [event("p", personal, planID: "plan-1"),
                                                                     event("both", personal, hour: 11, planID: "plan-3")])
        for plan in ["plan-1", "plan-2", "plan-3"] {
            await store.addNudge(PlanNudge(planID: plan, hour: 7, minute: 30, message: "Go", endsOn: window.end))
        }

        await store.purge(accountID: "222")
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map { "\($0.accountID!)/\($0.id)" }), ["111/p", "111/both"])
        XCTAssertEqual(Set(snapshot.nudges.map(\.planID)), ["plan-1", "plan-3"])
        XCTAssertNil(snapshot.coverageByCalendar[school.key])
        XCTAssertNotNil(snapshot.coverageByCalendar[personal.key])

        await store.purge(calendar: personal)
        let empty = await store.snapshot()
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertTrue(empty.coverageByCalendar.isEmpty)
        XCTAssertTrue(empty.nudges.isEmpty)
    }

    func testDroppingUnscopedGoogleEventsKeepsSampleDataAndPreviews() async {
        let (store, _) = await makeStores()
        await store.upsert([event("legacy", nil), event(DemoData.idPrefix + "chat-1", nil, hour: 10),
                            event(PlanDraft.eventIDPrefix + "p-1", nil, hour: 11), event("scoped", personal, hour: 12)])
        await store.mergeRange(window, with: [], replacingCached: false)

        await store.dropUnscopedGoogleEvents()
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), [DemoData.idPrefix + "chat-1", PlanDraft.eventIDPrefix + "p-1", "scoped"])
        XCTAssertTrue(snapshot.loadedRanges.isEmpty)
    }

    func testAStoreWithoutAccountsShowsEverythingAsBefore() async {
        let store = SharedStore(fileURL: files.url("SharedStoreAccountTests-plain"))
        await store.upsert([event(DemoData.idPrefix + "x", nil), event("google", personal, hour: 10)])
        let visible = await store.visibleEvents()
        XCTAssertEqual(visible.map(\.id), [DemoData.idPrefix + "x", "google"])
    }

    func testDemoModeShowsOnlySampleEvents() async {
        let (store, accounts) = await makeStores(demo: true)
        await store.upsert(DemoData.recurringEvents(in: window, clock: TestClock.clock) + [event("google", personal)])
        var visible = await store.visibleEvents()
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.allSatisfy { DemoData.isDemoID($0.id) })
        XCTAssertTrue(visible.contains { $0.title == "Gym" })

        await accounts.setVisible(false, calendar: DemoData.gymCalendar)
        visible = await store.visibleEvents()
        XCTAssertFalse(visible.contains { $0.title == "Gym" || $0.title == "Yoga" })
        XCTAssertTrue(visible.contains { $0.title == "Weekly team sync" })
    }

    // MARK: Pending event batch and erase

    private func batch() throws -> PendingEventBatch {
        let json = """
        {"id": "batch-abcd1234", "createdAt": 1791900000, "utterance": "Lunch with Andrew tomorrow 1pm",
         "seed": "seed-1", "argsJSON": "e30=", "target": {"accountID": "111", "calendarID": "kenny@example.com"},
         "targetLabel": "My calendar · kenny@example.com", "previewEvents": []}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970 // what SharedStore uses
        return try decoder.decode(PendingEventBatch.self, from: Data(json.utf8))
    }

    func testPendingEventBatchIsOneSharedSlot() async throws {
        let url = files.url("SharedStoreAccountTests-batch")
        let pending = try batch()
        await SharedStore(fileURL: url).setPendingEventBatch(pending)
        let reread = await SharedStore(fileURL: url).pendingEventBatch() // e.g. the notification extension
        XCTAssertEqual(reread, pending)

        await SharedStore(fileURL: url).setLastAssistantLine("unrelated write")
        let kept = await SharedStore(fileURL: url).pendingEventBatch()
        XCTAssertEqual(kept?.id, pending.id)

        await SharedStore(fileURL: url).setPendingEventBatch(nil)
        let cleared = await SharedStore(fileURL: url).pendingEventBatch()
        XCTAssertNil(cleared)
    }

    func testOlderAndNewerCachesDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Before multiple accounts: no coverage, no batch, events without calendars.
        let old = ##"{"events": [{"id": "e1", "title": "Old", "start": 1791900000, "end": 1791903600, "isAllDay": false, "kind": "event", "colorHex": "#039BE5", "isCompleted": false}], "nudges": []}"##
        let snapshot = try decoder.decode(SharedStore.Snapshot.self, from: Data(old.utf8))
        XCTAssertEqual(snapshot.events.first?.ref, EventRef(accountID: nil, calendarID: nil, eventID: "e1"))
        XCTAssertNil(snapshot.events.first?.calendarRef)
        XCTAssertTrue(snapshot.coverageByCalendar.isEmpty)
        XCTAssertNil(snapshot.pendingEventBatch)
        // A batch or coverage this build cannot read is dropped on its own.
        let newer = #"{"events": [], "nudges": [], "pendingEventBatch": {"id": 3}, "coverageByCalendar": "later"}"#
        let decoded = try decoder.decode(SharedStore.Snapshot.self, from: Data(newer.utf8))
        XCTAssertNil(decoded.pendingEventBatch)
        XCTAssertTrue(decoded.coverageByCalendar.isEmpty)
    }

    func testEraseAllEmptiesTheCache() async throws {
        let (store, _) = await makeStores()
        let pending = try batch()
        await store.upsert([event("a", personal)])
        await store.setPendingEventBatch(pending)
        await store.eraseAll()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertNil(snapshot.pendingEventBatch)
    }
}
