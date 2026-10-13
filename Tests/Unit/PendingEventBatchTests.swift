import XCTest

/// "Ask me first": the batch model, its App Group slot and the args that Add re-maps.
final class PendingEventBatchTests: XCTestCase {
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private func sample(id: String = PendingEventBatch.newID()) -> PendingEventBatch {
        let preview = TestEvents.make(id: PendingEventBatch.previewID(batchID: id, index: 0), title: "Lunch with Andrew",
                                      start: TestClock.local(2026, 10, 14, 13), end: TestClock.local(2026, 10, 14, 14))
        let args = Data(#"{"events":[{"title":"Lunch with Andrew","start":"2026-10-14T13:00","kind":"event"}]}"#.utf8)
        return PendingEventBatch(id: id, createdAt: now, utterance: "Lunch with Andrew tomorrow 1pm", seed: "seed|0",
                                 argsJSON: args,
                                 target: CalendarRef(accountID: "acct-a", calendarID: "kenny@example.com"),
                                 targetLabel: "My calendar · kenny@example.com", previewEvents: [preview])
    }

    func testIdsAreBase32HexAndPreviewsAreDrafts() {
        let id = PendingEventBatch.newID()
        XCTAssertTrue(id.hasPrefix("batch-"), id)
        let suffix = id.dropFirst("batch-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { "0123456789abcdefghijklmnopqrstuv".contains($0) }, id)
        XCTAssertNotEqual(PendingEventBatch.newID(), PendingEventBatch.newID())

        XCTAssertEqual(PendingEventBatch.previewID(batchID: "batch-k3p9a0bc", index: 2), "draft-ev-k3p9a0bc-2")
        let preview = TestEvents.make(id: PendingEventBatch.previewID(batchID: id, index: 0),
                                      start: now, end: now.addingTimeInterval(3600))
        XCTAssertTrue(preview.isDraft, "previews draw as ghosts and are never written")
    }

    func testCodableRoundTrip() throws {
        let batch = sample()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(PendingEventBatch.self, from: encoder.encode(batch)), batch)
    }

    func testTolerantDecoding() throws {
        // Written by another build: optional parts missing, an unknown field added.
        let json = #"{"id": "batch-abcdefgh", "argsJSON": "e30=", "future": true}"#
        let batch = try JSONDecoder().decode(PendingEventBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.id, "batch-abcdefgh")
        XCTAssertEqual(batch.argsJSON, Data("{}".utf8))
        XCTAssertEqual(batch.seed, "batch-abcdefgh")
        XCTAssertNil(batch.target)
        XCTAssertNil(batch.targetLabel)
        XCTAssertTrue(batch.previewEvents.isEmpty)
        XCTAssertNil(batch.previewRange)
    }

    func testSharedStoreSlotHoldsOneBatch() async {
        let store = SharedStore(fileURL: files.url("PendingEventBatchTests-cache"))
        let empty = await store.pendingEventBatch()
        XCTAssertNil(empty)

        let first = sample()
        await store.setPendingEventBatch(first)
        let stored = await store.pendingEventBatch()
        XCTAssertEqual(stored, first)

        // A newer batch replaces the old one.
        let second = sample()
        await store.setPendingEventBatch(second)
        let replaced = await store.pendingEventBatch()
        XCTAssertEqual(replaced?.id, second.id)

        await store.setPendingEventBatch(nil)
        let cleared = await store.pendingEventBatch()
        XCTAssertNil(cleared)
    }

    func testArgsReMapToTheSameGoogleIds() throws {
        // Add maps the stored args again with the batch's seed: the ids match, so a second Add is an idempotent 409.
        let batch = sample()
        let args = try ScheduleAssistant.decodeCreateArgs(batch.argsJSON)
        let mapper = CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy())
        let first = try mapper.event(from: args.events[0], seed: "\(batch.seed)|0", utterance: batch.utterance)
        let again = try mapper.event(from: args.events[0], seed: "\(batch.seed)|0", utterance: batch.utterance)
        XCTAssertNotNil(first.body.id)
        XCTAssertEqual(first.body.id, again.body.id)
        XCTAssertEqual(first.body.summary, "Lunch with Andrew")
    }

    func testDemoArgsEncodingDecodesLikeGeminis() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let draft = EventDraft(title: "Dentist", start: "2026-10-14T09:00", durationMinutes: 45, kind: "event")
        let data = try encoder.encode(CreateEventsArgs(events: [draft]))
        let object = try TestJSON.object(data)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["duration_minutes"] as? Int, 45)
        let decoded = try ScheduleAssistant.decodeCreateArgs(data)
        XCTAssertEqual(decoded.events.first?.title, "Dentist")
        XCTAssertEqual(decoded.events.first?.durationMinutes, 45)
    }

    func testDayRangeCoversTheEvents() throws {
        let batch = sample()
        let range = try XCTUnwrap(ScheduleAssistant.dayRange(of: batch.previewEvents, clock: TestClock.clock))
        XCTAssertEqual(range.start, TestClock.local(2026, 10, 14))
        XCTAssertEqual(range.end, TestClock.local(2026, 10, 15))
        XCTAssertNil(ScheduleAssistant.dayRange(of: [], clock: TestClock.clock))
    }
}
