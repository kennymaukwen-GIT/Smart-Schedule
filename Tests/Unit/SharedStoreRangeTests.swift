import XCTest

/// On-demand ranges in the App Group cache: merged without moving the rolling window's markers, forgotten by a
/// rolling refresh, and capped.
final class SharedStoreRangeTests: XCTestCase {
    private var storeFiles: [URL] = []

    /// The rolling window for "now" = Tue 13 Oct 2026 (−7 d … +120 d).
    private let window = DateInterval(start: TestClock.local(2026, 10, 6), end: TestClock.local(2027, 2, 10))

    override func tearDown() {
        for url in storeFiles { try? FileManager.default.removeItem(at: url) }
        storeFiles = []
        super.tearDown()
    }

    private func makeStore() -> SharedStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharedStoreRangeTests-\(UUID().uuidString).json")
        storeFiles.append(url)
        return SharedStore(fileURL: url)
    }

    private func month(_ year: Int, _ month: Int, through endMonth: Int? = nil) -> DateInterval {
        let start = TestClock.local(year, month, 1)
        let last = endMonth ?? month
        let end = last == 12 ? TestClock.local(year + 1, 1, 1) : TestClock.local(year, last + 1, 1)
        return DateInterval(start: start, end: end)
    }

    private func event(_ id: String, _ year: Int, _ month: Int, _ day: Int, planID: String? = nil) -> ScheduleEvent {
        TestEvents.make(id: id, start: TestClock.local(year, month, day, 9), end: TestClock.local(year, month, day, 10),
                        planID: planID)
    }

    func testMergingAFarRangeKeepsTheWindowMarkers() async {
        let store = makeStore()
        await store.replaceWindow(window, with: [event("near", 2026, 10, 20)])
        let before = await store.snapshot()

        let far = month(2027, 9, through: 11)
        await store.mergeRange(far, with: [event("far", 2027, 10, 5)])
        let after = await store.snapshot()

        XCTAssertEqual(after.windowStart, before.windowStart)
        XCTAssertEqual(after.windowEnd, before.windowEnd)
        XCTAssertEqual(after.lastRefresh, before.lastRefresh)
        XCTAssertEqual(Set(after.events.map(\.id)), ["near", "far"])
        XCTAssertEqual(after.loadedRanges, [far])

        let coverage = await store.coverage()
        XCTAssertTrue(coverage.contains(window))
        XCTAssertTrue(coverage.contains(far))
        XCTAssertEqual(coverage.missing(in: DateInterval(start: window.start, end: far.end)),
                       [DateInterval(start: window.end, end: far.start)])
    }

    func testMergeReplacesItsRangeAndMovesListedEvents() async {
        let store = makeStore()
        let september = month(2027, 9)
        let october = month(2027, 10)
        await store.mergeRange(september, with: [event("deleted-later", 2027, 9, 10), event("moved", 2027, 9, 20)])
        // "moved" now lives in October: its September copy goes, "deleted-later" (outside October) stays.
        await store.mergeRange(october, with: [event("moved", 2027, 10, 20)])
        var snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), ["deleted-later", "moved"])
        XCTAssertEqual(snapshot.events.first { $0.id == "moved" }?.start, TestClock.local(2027, 10, 20, 9))

        // September listed again without it: deleted on the server.
        await store.mergeRange(september, with: [])
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.map(\.id), ["moved"])
        XCTAssertEqual(snapshot.loadedRanges, [month(2027, 9, through: 10)])
    }

    func testDemoMergeKeepsEventsThatExistOnlyInTheCache() async {
        let store = makeStore()
        let chat = event(DemoData.idPrefix + "chat-1", 2027, 10, 6)
        await store.upsert([chat])
        let october = month(2027, 10)
        await store.mergeRange(october, with: DemoData.recurringEvents(in: october, clock: TestClock.clock), replacingCached: false)

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.events.contains(chat))
        XCTAssertTrue(snapshot.events.contains { $0.id == "demo-gym-2027-10-06" })
    }

    func testRollingRefreshForgetsOnDemandRangesButKeepsTheirEvents() async {
        let store = makeStore()
        let far = month(2027, 9, through: 11)
        await store.mergeRange(far, with: [event("far", 2027, 10, 5), event("moved-in", 2027, 10, 6)])
        // "moved-in" was rescheduled into the window; the window listing carries its new date.
        await store.replaceWindow(window, with: [event("moved-in", 2026, 11, 2)])

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.loadedRanges, [])
        XCTAssertEqual(snapshot.window, window)
        XCTAssertEqual(snapshot.events.filter { $0.id == "moved-in" }.map(\.start), [TestClock.local(2026, 11, 2, 9)])
        XCTAssertTrue(snapshot.events.contains { $0.id == "far" })
        let coverage = await store.coverage()
        XCTAssertFalse(coverage.contains(far))
    }

    func testCacheCapDropsFarRangesButNeverTheWindowOrThePendingPlan() async {
        let store = makeStore()
        await store.replaceWindow(window, with: [event("in-window", 2026, 11, 2)])
        let far = month(2029, 3)
        await store.mergeRange(far, with: [event("far-a", 2029, 3, 3), event("far-b", 2029, 3, 4),
                                           event("far-plan", 2029, 3, 5, planID: "p1")])
        await store.setPendingPlan(PlanDraft(id: "p1", revision: 1, utterance: "", goal: "", title: "Plan",
                                             startDate: TestClock.local(2029, 3, 1), endDate: TestClock.local(2029, 3, 31),
                                             summary: "", phases: [], sessions: [], milestones: [], nudge: nil,
                                             assumptions: [], previewEvents: [], writeCount: 0, argsJSON: Data()))
        let today = DateInterval(start: TestClock.local(2026, 10, 13), end: TestClock.local(2026, 10, 14))
        let keep = LoadedRanges.keepZones(around: [today], months: 12, calendar: TestClock.clock.calendar)

        let underLimit = await store.evictEvents(outside: keep, whenCountExceeds: 10)
        XCTAssertEqual(underLimit, 0)

        let dropped = await store.evictEvents(outside: keep, whenCountExceeds: 2)
        XCTAssertEqual(dropped, 2)
        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), ["in-window", "far-plan"])
        XCTAssertEqual(snapshot.loadedRanges, [])
        XCTAssertEqual(snapshot.window, window)
        XCTAssertEqual(snapshot.pendingPlan?.id, "p1")
    }

    func testLoadedRangesDecodeLenientlyAndRoundTrip() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970 // what SharedStore uses
        let old = #"{"events": [], "nudges": [], "windowStart": 1791500000}"#
        XCTAssertEqual(try decoder.decode(SharedStore.Snapshot.self, from: Data(old.utf8)).loadedRanges, [])
        let unreadable = #"{"events": [], "nudges": [], "loadedRanges": "from another version"}"#
        XCTAssertEqual(try decoder.decode(SharedStore.Snapshot.self, from: Data(unreadable.utf8)).loadedRanges, [])

        var snapshot = SharedStore.Snapshot()
        snapshot.loadedRanges = [month(2027, 9, through: 11)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SharedStore.Snapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded.loadedRanges, snapshot.loadedRanges)
    }
}
