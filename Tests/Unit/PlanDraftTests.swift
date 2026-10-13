import XCTest

final class PlanDraftTests: XCTestCase {
    private let clock = TestClock.clock
    private let builder = PlanDraftBuilder(mapper: CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy()))
    private var storeFiles: [URL] = []

    override func tearDown() {
        for url in storeFiles { try? FileManager.default.removeItem(at: url) }
        storeFiles = []
        super.tearDown()
    }

    private func makeDraft(from fixture: String, id: String = "plan1", revision: Int = 1) throws -> PlanDraft {
        let call = try Fixtures.call(fixture)
        let args = try TestJSON.decode(LongTermPlanArgs.self, data: call.args)
        return try builder.draft(from: args, argsJSON: call.args, id: id, revision: revision,
                                 utterance: Fixtures.utterance(fixture))
    }

    private func makeDraft(json: String) throws -> PlanDraft {
        let data = Data(json.utf8)
        let args = try TestJSON.decode(LongTermPlanArgs.self, data: data)
        return try builder.draft(from: args, argsJSON: data, id: "p", revision: 1, utterance: "u")
    }

    private func wallTimes(_ events: [ScheduleEvent]) -> Set<String> {
        Set(events.filter { !$0.isAllDay }.map { String(clock.promptDateTimeString($0.start).suffix(5)) })
    }

    private var storeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: PlanDraftBuilder

    func testDraftFromMuscleFixture() throws {
        let draft = try makeDraft(from: "create_long_term_plan.muscle.json")

        XCTAssertEqual(draft.id, "plan1")
        XCTAssertEqual(draft.revision, 1)
        XCTAssertEqual(draft.utterance, "I want to be muscular in 6 month design me a daily routine")
        XCTAssertEqual(draft.title, "Muscle 6M")
        XCTAssertTrue(draft.goal.hasPrefix("Gain visible muscle mass"))
        XCTAssertEqual(draft.summary, "A 6-month muscle plan: 4 workouts a week, about an hour each.")
        XCTAssertEqual(draft.startDate, TestClock.local(2026, 10, 14))
        XCTAssertEqual(draft.endDate, TestClock.local(2027, 4, 13))
        XCTAssertEqual(draft.phases.map(\.name), ["Foundation", "Hypertrophy", "Strength"])
        XCTAssertEqual(draft.phases[1].start, TestClock.local(2026, 12, 1))
        XCTAssertEqual(draft.phases[1].end, TestClock.local(2027, 2, 28))
        XCTAssertEqual(draft.sessions.count, 6)
        XCTAssertEqual(draft.sessions.first, PlanDraft.Session(phaseIndex: 0, title: "Full body A", weekdays: ["MO", "TH"],
                                                               startTime: "18:30", durationMinutes: 60,
                                                               notes: "Squat 3x10, bench 3x10, row 3x10, plank 3x45s"))
        XCTAssertEqual(draft.sessions.last?.durationMinutes, 70)
        XCTAssertEqual(draft.milestones.count, 6)
        XCTAssertEqual(draft.milestones.first, PlanDraft.Milestone(date: TestClock.local(2026, 11, 14),
                                                                   title: "Month 1 check-in: weight & photos"))
        XCTAssertEqual(draft.nudge?.hour, 7)
        XCTAssertEqual(draft.nudge?.minute, 30)
        XCTAssertEqual(draft.assumptions, ["Beginner with gym access", "Weekday evenings after 18:00 are free"])
        XCTAssertEqual(draft.writeCount, 12) // 6 series + 6 milestones
        XCTAssertEqual(try PlanDraftBuilder.decodeArgs(draft.argsJSON).planTitle, "Muscle 6M")
    }

    func testPreviewCoversTheWholeSixMonthPlan() throws {
        let draft = try makeDraft(from: "create_long_term_plan.muscle.json")
        let sessions = draft.previewEvents.filter { !$0.isAllDay }
        let milestones = draft.previewEvents.filter(\.isAllDay)

        XCTAssertEqual(sessions.count, 104) // python3 -I scripts/validate_schema.py --print-payloads
        XCTAssertEqual(milestones.count, 6)
        XCTAssertEqual(sessions.first?.start, TestClock.local(2026, 10, 15, 18, 30))
        XCTAssertEqual(sessions.last?.start, TestClock.local(2027, 4, 13, 18, 30))
        XCTAssertEqual(wallTimes(sessions), ["18:30"]) // across both DST changes
        XCTAssertEqual(draft.previewEvents.map(\.start), draft.previewEvents.map(\.start).sorted())
        XCTAssertTrue(draft.previewEvents.allSatisfy { $0.isDraft && $0.planID == "plan1" })
        XCTAssertEqual(Set(draft.previewEvents.map(\.id)).count, draft.previewEvents.count)
        XCTAssertEqual(Set(sessions.map(\.kind)), [.routine])
        XCTAssertEqual(Set(milestones.map(\.kind)), [.deadline])
    }

    func testRevisionFixtureMovesThePreviewToMornings() throws {
        let original = try makeDraft(from: "create_long_term_plan.muscle.json")
        let revised = try makeDraft(from: "create_long_term_plan.revision.json", revision: 2)

        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.title, original.title)
        XCTAssertEqual(Set(revised.sessions.map(\.startTime)), ["07:00"])
        XCTAssertEqual(wallTimes(revised.previewEvents), ["07:00"])
        XCTAssertEqual(revised.previewEvents.count, original.previewEvents.count)
        XCTAssertEqual(revised.nudge?.hour, 6)
        XCTAssertEqual(revised.nudge?.minute, 15)
        XCTAssertEqual(revised.writeCount, original.writeCount)
    }

    func testPreviewIsCappedAtTwentySixWeeks() throws {
        let draft = try makeDraft(json: """
        {"goal": "Run a marathon", "plan_title": "Marathon", "start_date": "2026-10-14", "end_date": "2027-10-13",
         "summary_for_user": "A year of Saturday long runs.",
         "phases": [{"name": "Base", "start_date": "2026-10-14", "end_date": "2027-10-13"}],
         "sessions": [{"phase_index": 0, "title": "Long run", "weekdays": ["SA"], "start_time": "08:00", "duration_minutes": 90}]}
        """)
        let horizon = TestClock.local(2027, 4, 14) // 26 weeks after 2026-10-14
        XCTAssertEqual(builder.previewHorizon(for: draft), horizon)
        XCTAssertEqual(draft.previewEvents.count, 26)
        XCTAssertTrue(draft.previewEvents.allSatisfy { $0.start < horizon })
        XCTAssertEqual(draft.previewEvents.last?.start, TestClock.local(2027, 4, 10, 8, 0))
        XCTAssertEqual(draft.writeCount, 1) // Add still writes the whole year as one series
        XCTAssertNil(draft.nudge)
        XCTAssertTrue(draft.milestones.isEmpty)
        XCTAssertTrue(draft.assumptions.isEmpty)
    }

    func testSessionsTheMapperSkipsAreLeftOutOfTheDraft() throws {
        let draft = try makeDraft(json: """
        {"goal": "g", "plan_title": "T", "start_date": "2026-10-14", "end_date": "2026-11-30", "summary_for_user": "s",
         "phases": [{"name": "Only", "start_date": "2026-10-14", "end_date": "2026-11-30"}],
         "sessions": [
           {"phase_index": 0, "title": "Kept", "weekdays": ["mo", "WE"], "start_time": "07:00", "duration_minutes": 500},
           {"phase_index": 3, "title": "No such phase", "weekdays": ["TU"], "start_time": "07:00", "duration_minutes": 30},
           {"phase_index": 0, "title": "Bad time", "weekdays": ["TU"], "start_time": "late", "duration_minutes": 30}
         ]}
        """)
        XCTAssertEqual(draft.sessions.map(\.title), ["Kept"])
        XCTAssertEqual(draft.sessions.first?.weekdays, ["MO", "WE"])
        XCTAssertEqual(draft.sessions.first?.durationMinutes, 240) // clamped like the mapper
        XCTAssertEqual(draft.writeCount, 1)
    }

    func testAPlanThatCannotBeWrittenFailsBeforeReview() {
        XCTAssertThrowsError(try makeDraft(json: """
        {"goal": "g", "plan_title": "T", "start_date": "2026-10-14", "end_date": "2026-11-30", "summary_for_user": "s",
         "phases": [{"name": "Only", "start_date": "2026-10-14", "end_date": "2026-11-30"}],
         "sessions": [{"phase_index": 2, "title": "Orphan", "weekdays": ["TU"], "start_time": "07:00", "duration_minutes": 30}]}
        """))
    }

    func testOfflineArgsRoundTripThroughGeminisSnakeCase() throws {
        let args = try Fixtures.args(LongTermPlanArgs.self, from: "create_long_term_plan.muscle.json")
        let data = try PlanDraftBuilder.encode(args)
        let json = try TestJSON.object(data)
        XCTAssertNotNil(json["plan_title"])
        XCTAssertNotNil(json["summary_for_user"])
        XCTAssertNotNil(json["daily_nudge"])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertNotNil(sessions.first?["phase_index"])
        XCTAssertNotNil(sessions.first?["duration_minutes"])

        let decoded = try PlanDraftBuilder.decodeArgs(data)
        XCTAssertEqual(decoded.planTitle, args.planTitle)
        XCTAssertEqual(decoded.sessions.map(\.startTime), args.sessions.map(\.startTime))
        XCTAssertEqual(decoded.milestones?.map(\.date), args.milestones?.map(\.date))
    }

    // MARK: PlanDraft

    func testCodableRoundTrip() throws {
        let draft = try makeDraft(from: "create_long_term_plan.muscle.json")
        XCTAssertEqual(try JSONDecoder().decode(PlanDraft.self, from: JSONEncoder().encode(draft)), draft)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970 // what SharedStore uses
        XCTAssertEqual(try storeDecoder.decode(PlanDraft.self, from: encoder.encode(draft)), draft)
    }

    func testIsDraftComesFromTheIDAndIsNotStored() throws {
        let start = TestClock.local(2026, 10, 15, 18, 30)
        let preview = TestEvents.make(id: "draft-ss123_20261015", start: start, end: start.addingTimeInterval(3600))
        XCTAssertTrue(preview.isDraft)
        XCTAssertFalse(TestEvents.make(id: "demo-ss123_20261015", start: start, end: start).isDraft)
        XCTAssertFalse(TestEvents.make(id: "ss123", start: start, end: start).isDraft)
        XCTAssertNil(try TestJSON.object(encoding: preview)["isDraft"])
    }

    // MARK: SharedStore

    func testOldSnapshotWithoutPendingPlanStillDecodes() throws {
        // A cache file written before drafts existed.
        let json = """
        {"events": [{"id": "e1", "title": "Gym", "start": 1792089000, "end": 1792092600, "isAllDay": false,
                     "kind": "routine", "colorHex": "#0B8043", "isCompleted": false}],
         "nudges": [{"planID": "p1", "hour": 7, "minute": 30, "message": "Morning!", "endsOn": 1807833600}],
         "windowStart": 1791500000, "lastAssistantLine": "Done."}
        """
        let snapshot = try storeDecoder.decode(SharedStore.Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.pendingPlan)
        XCTAssertEqual(snapshot.events.map(\.id), ["e1"])
        XCTAssertEqual(snapshot.nudges.map(\.planID), ["p1"])
        XCTAssertEqual(snapshot.windowStart, Date(timeIntervalSince1970: 1_791_500_000))
        XCTAssertNil(snapshot.windowEnd)
        XCTAssertEqual(snapshot.lastAssistantLine, "Done.")
    }

    func testUnreadableDraftIsDroppedWithoutLosingTheCache() throws {
        let json = """
        {"events": [], "nudges": [{"planID": "p1", "hour": 7, "minute": 30, "message": "Morning!", "endsOn": 1807833600}],
         "pendingPlan": {"id": 42, "shape": "from another version"}}
        """
        let snapshot = try storeDecoder.decode(SharedStore.Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.pendingPlan)
        XCTAssertEqual(snapshot.nudges.map(\.planID), ["p1"])
    }

    func testStoreSharesThePendingPlanAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlanDraftTests-\(UUID().uuidString).json")
        storeFiles.append(url)
        let draft = try makeDraft(from: "create_long_term_plan.muscle.json")

        await SharedStore(fileURL: url).setPendingPlan(draft)
        let reread = await SharedStore(fileURL: url).pendingPlan() // e.g. the notification extension
        XCTAssertEqual(reread, draft)

        await SharedStore(fileURL: url).setLastAssistantLine("unrelated write")
        let kept = await SharedStore(fileURL: url).pendingPlan()
        XCTAssertEqual(kept?.revision, 1)

        await SharedStore(fileURL: url).setPendingPlan(nil)
        let cleared = await SharedStore(fileURL: url).pendingPlan()
        XCTAssertNil(cleared)
    }
}
