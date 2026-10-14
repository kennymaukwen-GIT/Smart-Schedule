import XCTest

/// The outbox: later changes folded into earlier ones, queue order, the file round trip, and what the status counts.
final class SyncOutboxTests: XCTestCase {
    private let files = TemporaryStoreFiles()
    private let personal = CalendarRef(accountID: "111", calendarID: "kenny@example.com")
    private let school = CalendarRef(accountID: "222", calendarID: "student@university.example.edu")
    private let created = TestClock.utc(2026, 10, 14, 9, 0)

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func body(summary: String? = nil, start: String? = nil) -> GCalEvent {
        var body = GCalEvent()
        body.summary = summary
        if let start { body.start = GCalDateTime(dateTime: start, timeZone: "Europe/London") }
        return body
    }

    private func change(_ kind: OutboxItem.Kind, _ eventID: String, _ body: GCalEvent? = nil, etag: String? = nil,
                        reached: Bool = false, calendar: CalendarRef? = nil) -> OutboxItem {
        OutboxItem(kind: kind, calendar: calendar ?? personal, eventID: eventID, body: body, etag: etag,
                   title: body?.summary ?? eventID, createdAt: created, mayHaveReachedGoogle: reached)
    }

    // MARK: Folding

    func testCreateThenEditIsOneCreateWithTheNewBody() {
        var queue = OutboxQueue.enqueue(change(.insert, "ss1", body(summary: "Lunch", start: "2026-10-15T13:00:00")), into: [])
        queue = OutboxQueue.enqueue(change(.patch, "ss1", body(summary: "Lunch with Andrew")), into: queue)

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].kind, .insert)
        XCTAssertEqual(queue[0].body?.summary, "Lunch with Andrew")
        XCTAssertEqual(queue[0].body?.start?.dateTime, "2026-10-15T13:00:00")
        // Kept apart too, for an insert that turns out to have reached Google before the edit.
        XCTAssertEqual(queue[0].followUp?.summary, "Lunch with Andrew")
        XCTAssertEqual(queue[0].revision, 1)
    }

    func testTwoEditsBecomeOneKeepingTheFirstEtag() {
        var queue = OutboxQueue.enqueue(change(.patch, "e1", body(summary: "A"), etag: "\"1\""), into: [])
        queue = OutboxQueue.enqueue(change(.patch, "e1", body(start: "2026-10-15T15:00:00"), etag: "\"1\""), into: queue)
        queue = OutboxQueue.enqueue(change(.patch, "e1", body(summary: "B")), into: queue)

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].kind, .patch)
        XCTAssertEqual(queue[0].etag, "\"1\"")
        XCTAssertEqual(queue[0].body?.summary, "B")
        XCTAssertEqual(queue[0].body?.start?.dateTime, "2026-10-15T15:00:00")
        XCTAssertEqual(queue[0].revision, 2)
    }

    func testAnythingThenDeleteIsADeleteAndLaterEditsAreDropped() {
        var queue = OutboxQueue.enqueue(change(.patch, "e1", body(summary: "A"), etag: "\"1\""), into: [])
        queue = OutboxQueue.enqueue(change(.delete, "e1", etag: "\"1\""), into: queue)
        XCTAssertEqual(queue.map(\.kind), [.delete])
        XCTAssertEqual(queue[0].etag, "\"1\"")

        queue = OutboxQueue.enqueue(change(.patch, "e1", body(summary: "B")), into: queue)
        XCTAssertEqual(queue.map(\.kind), [.delete])
    }

    func testCreateThenDeleteBeforeSendingDropsBoth() {
        var queue = OutboxQueue.enqueue(change(.insert, "ss1", body(summary: "Lunch")), into: [])
        queue = OutboxQueue.enqueue(change(.patch, "ss1", body(summary: "Lunch with Andrew")), into: queue)
        queue = OutboxQueue.enqueue(change(.delete, "ss1"), into: queue)
        XCTAssertTrue(queue.isEmpty)
    }

    func testACreateThatMayHaveReachedGoogleIsDeletedThere() {
        // A timeout: Google may have it, with an etag this iPhone never saw.
        var queue = OutboxQueue.enqueue(change(.insert, "ss1", body(summary: "Lunch"), reached: true), into: [])
        queue = OutboxQueue.enqueue(change(.delete, "ss1", etag: "\"stale\""), into: queue)
        XCTAssertEqual(queue.map(\.kind), [.delete])
        XCTAssertNil(queue[0].etag)
        XCTAssertTrue(queue[0].mayHaveReachedGoogle)
    }

    func testOrderIsFirstQueuedAndOtherEventsAreUntouched() {
        var queue: [OutboxItem] = []
        queue = OutboxQueue.enqueue(change(.insert, "a", body(summary: "A")), into: queue)
        queue = OutboxQueue.enqueue(change(.patch, "b", body(summary: "B")), into: queue)
        queue = OutboxQueue.enqueue(change(.delete, "c"), into: queue)
        queue = OutboxQueue.enqueue(change(.patch, "a", body(summary: "A2")), into: queue)
        XCTAssertEqual(queue.map(\.eventID), ["a", "b", "c"])
        XCTAssertEqual(queue[0].body?.summary, "A2")

        // The same id in another calendar is another event.
        queue = OutboxQueue.enqueue(change(.delete, "a", calendar: school), into: queue)
        XCTAssertEqual(queue.map(\.eventID), ["a", "b", "c", "a"])
        XCTAssertEqual(queue.map(\.kind), [.insert, .patch, .delete, .delete])
    }

    func testRefusedChangesAreNeverFoldedInto() {
        var refused = change(.patch, "e1", body(summary: "A"))
        refused.failure = "You can't change events in “Holidays”."
        let queue = OutboxQueue.enqueue(change(.patch, "e1", body(summary: "B")), into: [refused])
        XCTAssertEqual(queue.map { $0.body?.summary }, ["A", "B"])
    }

    func testDeletingASeriesTakesItsQueuedEditsWithIt() {
        var instanceEdit = change(.patch, "s_20261015", body(summary: "Moved once"))
        instanceEdit.base = TestEvents.make(id: "s_20261015", start: TestClock.local(2026, 10, 15, 18, 30),
                                            end: TestClock.local(2026, 10, 15, 19, 30), seriesID: "s", calendar: personal)
        var queue = OutboxQueue.enqueue(instanceEdit, into: [])
        queue = OutboxQueue.enqueue(change(.patchSeries, "s", body(summary: "Gym")), into: queue)
        queue = OutboxQueue.enqueue(change(.patch, "other", body(summary: "Other")), into: queue)
        queue = OutboxQueue.enqueue(change(.delete, "s"), into: queue)
        XCTAssertEqual(queue.map(\.eventID), ["other", "s"])
        XCTAssertEqual(queue.map(\.kind), [.patch, .delete])
    }

    // MARK: File

    func testTheQueueSurvivesAReopenAndCompletingAnOldRevisionKeepsNewerEdits() async {
        let url = files.url("SyncOutboxTests-outbox")
        let outbox = SyncOutbox(fileURL: url)
        var insert = change(.insert, "ss1", body(summary: "Lunch", start: "2026-10-15T13:00:00"))
        insert.wantsConference = true
        await outbox.enqueue(insert)
        await outbox.enqueue(change(.patch, "e1", body(summary: "A"), etag: "\"1\""))

        let reopened = SyncOutbox(fileURL: url)
        let items = await reopened.items()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first, insert)
        let waiting = await reopened.hasPending(calendar: personal, eventID: "e1")
        XCTAssertTrue(waiting)
        let otherCalendar = await reopened.hasPending(calendar: school, eventID: "e1")
        XCTAssertFalse(otherCalendar)
        let master = await reopened.pendingInsert(calendar: personal, eventID: "ss1")
        XCTAssertEqual(master?.summary, "Lunch")

        // An edit folded in while the insert was on its way: completing the revision that was sent keeps it.
        let sent = items[0]
        await reopened.enqueue(change(.patch, "ss1", body(summary: "Lunch with Andrew")))
        await reopened.complete(sent)
        var left = await reopened.pending()
        XCTAssertEqual(left.map(\.eventID), ["ss1", "e1"])
        XCTAssertEqual(left.first?.followUp?.summary, "Lunch with Andrew")

        if let current = left.first { await reopened.complete(current) }
        left = await reopened.pending()
        XCTAssertEqual(left.map(\.eventID), ["e1"])

        await reopened.eraseAll()
        let erased = await SyncOutbox(fileURL: url).items()
        XCTAssertTrue(erased.isEmpty)
    }

    func testUnreadableItemsAreSkippedNotTheWholeQueue() async throws {
        let url = files.url("SyncOutboxTests-tolerant")
        let outbox = SyncOutbox(fileURL: url)
        await outbox.enqueue(change(.delete, "e1"))
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(json["items"] as? [Any])
        items.insert(["kind": "teleport"], at: 0) // a newer build's item
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let read = await SyncOutbox(fileURL: url).items()
        XCTAssertEqual(read.map(\.eventID), ["e1"])
    }

    // MARK: Status

    func testRefusedChangesAreCountedApartAndCanBeRetriedOrDiscarded() async {
        let outbox = SyncOutbox(fileURL: files.url("SyncOutboxTests-failed"))
        let first = change(.patch, "e1", body(summary: "A"))
        let second = change(.delete, "e2")
        await outbox.enqueue(first)
        await outbox.enqueue(second)
        await outbox.fail(id: first.id, reason: "You can't change events in “Holidays”.", at: created)

        let items = await outbox.items()
        let status = SyncStatus(pendingCount: items.filter { !$0.isFailed }.count, failed: items.compactMap(\.failedChange))
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(status.failed.map(\.id), [first.id])
        XCTAssertEqual(status.failed.first?.title, "A")
        XCTAssertEqual(status.failed.first?.reason, "You can't change events in “Holidays”.")
        XCTAssertEqual(status.failed.first?.failedAt, created)
        XCTAssertTrue(status.needsAttention)

        let retried = await outbox.retry(id: first.id)
        XCTAssertTrue(retried)
        let afterRetry = await outbox.pending()
        XCTAssertEqual(afterRetry.map(\.eventID), ["e1", "e2"])
        let retriedAgain = await outbox.retry(id: first.id)
        XCTAssertFalse(retriedAgain) // nothing to retry: it is waiting again

        let dropped = await outbox.discard(id: second.id)
        XCTAssertEqual(dropped?.eventID, "e2")
        let remaining = await outbox.items()
        XCTAssertEqual(remaining.map(\.eventID), ["e1"])
        XCTAssertFalse(SyncStatus().needsAttention)
    }

    func testStatusRoundTripAndUnreadableFields() throws {
        let suite = "SyncOutboxTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SyncStatusStore.current(in: defaults), SyncStatus())

        let refused = FailedChange(id: UUID(), title: "Gym", summary: "Edit · 15 Oct 18:30", failedAt: created, reason: "No")
        SyncStatusStore.update(in: defaults) { status in
            status.pendingCount = 3
            status.failed = [refused]
            status.isOffline = true
            status.lastSuccess["111"] = created
        }
        let read = SyncStatusStore.current(in: defaults)
        XCTAssertEqual(read.pendingCount, 3)
        XCTAssertEqual(read.failed, [refused])
        XCTAssertTrue(read.isOffline)
        XCTAssertEqual(read.latestSuccess, created)

        defaults.set(Data(#"{"pendingCount": "three", "isOffline": true}"#.utf8), forKey: SyncStatusStore.defaultsKey)
        let tolerant = SyncStatusStore.current(in: defaults)
        XCTAssertEqual(tolerant.pendingCount, 0)
        XCTAssertTrue(tolerant.isOffline)
    }
}
