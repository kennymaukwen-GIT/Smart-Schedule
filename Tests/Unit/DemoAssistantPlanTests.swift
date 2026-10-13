import XCTest

/// The draft → review → Add / Keep editing loop, end to end on the offline assistant and a temporary store.
final class DemoAssistantPlanTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    /// Tuesday 2026-10-13 10:15 BST, the fixtures' now.
    private let now = TestClock.local(2026, 10, 13, 10, 15)
    private let goal = "I want to be muscular in 6 months"
    private var storeFiles: [URL] = []

    override func tearDown() {
        for url in storeFiles { try? FileManager.default.removeItem(at: url) }
        storeFiles = []
        super.tearDown()
    }

    private func makeAssistant() -> (DemoAssistant, SharedStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DemoAssistantPlanTests-\(UUID().uuidString).json")
        storeFiles.append(url)
        let store = SharedStore(fileURL: url)
        // No notification center in a hostless test bundle.
        return (DemoAssistant(store: store, clock: TestClock.clock, rescheduleReminders: { _ in }), store)
    }

    private func ask(_ assistant: DemoAssistant, _ text: String) async throws -> Reply {
        try await assistant.handle(text, focusEventID: nil, now: now)
    }

    /// A first draft for `goal`, already checked to be pending.
    private func startPlan(_ assistant: DemoAssistant, _ store: SharedStore) async throws -> PlanDraft {
        let reply = try await ask(assistant, goal)
        let draft = try XCTUnwrap(reply.planDraft)
        let pending = await store.pendingPlan()
        XCTAssertEqual(pending, draft)
        return draft
    }

    /// The draft a change request produced.
    private func revise(_ assistant: DemoAssistant, _ text: String) async throws -> PlanDraft {
        let reply = try await ask(assistant, text)
        return try XCTUnwrap(reply.planDraft, "“\(text)” produced no revision: \(reply.text)")
    }

    private func wallTimes(_ events: [ScheduleEvent]) -> Set<String> {
        Set(events.filter { !$0.isAllDay }.map { String(TestClock.clock.promptDateTimeString($0.start).suffix(5)) })
    }

    // MARK: The whole loop

    func testPlanIsOnlyADraftUntilAddEvenAfterARevision() async throws {
        let (assistant, store) = makeAssistant()

        // 1. The plan is shown, not written.
        let first = try await ask(assistant, goal)
        let draft = try XCTUnwrap(first.planDraft)
        XCTAssertEqual(draft.revision, 1)
        XCTAssertTrue(draft.id.hasPrefix(DemoData.idPrefix))
        XCTAssertEqual(draft.utterance, goal)
        XCTAssertEqual(draft.startDate, TestClock.local(2026, 10, 14))
        XCTAssertEqual(draft.endDate, TestClock.local(2027, 4, 13))
        XCTAssertEqual(Set(draft.sessions.map(\.startTime)), ["18:30"])
        XCTAssertEqual(draft.previewEvents.filter { !$0.isAllDay }.count, 104)
        XCTAssertTrue(draft.previewEvents.allSatisfy(\.isDraft))
        XCTAssertFalse(first.changed)
        XCTAssertNil(first.committedPlanID)
        XCTAssertTrue(first.text.contains(draft.summary))
        XCTAssertTrue(first.text.contains(ReplyFormatter.planReviewPrompt))
        XCTAssertEqual(first.showRange?.start, draft.startDate)

        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.pendingPlan, draft)
        XCTAssertTrue(snapshot.events.filter { $0.planID != nil }.isEmpty)
        XCTAssertTrue(snapshot.nudges.isEmpty)

        // 2. "Keep editing": a change request produces revision 2 of the same plan, still unwritten.
        let second = try await ask(assistant, "make it 7am")
        let revised = try XCTUnwrap(second.planDraft)
        XCTAssertEqual(revised.id, draft.id)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.utterance, draft.utterance)
        XCTAssertEqual(Set(revised.sessions.map(\.startTime)), ["07:00"])
        XCTAssertEqual(wallTimes(revised.previewEvents), ["07:00"])
        XCTAssertEqual(revised.nudge?.hour, 6) // an hour before an early session
        XCTAssertTrue(revised.summary.contains("at 07:00"))
        XCTAssertTrue(second.text.contains("revision 2"))
        XCTAssertFalse(second.changed)

        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.pendingPlan?.revision, 2)
        XCTAssertTrue(snapshot.events.filter { $0.planID != nil }.isEmpty)

        // 3. "Add" writes exactly what was reviewed, with real ids.
        let added = try await assistant.commitPlan(revised)
        XCTAssertEqual(added.committedPlanID, draft.id)
        XCTAssertNil(added.planDraft)
        XCTAssertTrue(added.changed)
        XCTAssertTrue(added.text.hasPrefix("Added (demo)"), added.text)
        XCTAssertTrue(added.text.contains(DemoAssistant.demoNote))

        snapshot = await store.snapshot()
        XCTAssertNil(snapshot.pendingPlan)
        let written = snapshot.events.filter { $0.planID == draft.id }
        XCTAssertEqual(written.count, revised.previewEvents.count)
        XCTAssertFalse(written.contains(where: \.isDraft))
        XCTAssertTrue(written.allSatisfy { DemoData.isDemoID($0.id) })
        XCTAssertEqual(wallTimes(written), ["07:00"])
        XCTAssertEqual(snapshot.nudges.map(\.planID), [draft.id])
        XCTAssertEqual(snapshot.lastAssistantLine, added.text)
    }

    func testTypedApprovalAddsTheDraft() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "looks good")
        XCTAssertEqual(reply.committedPlanID, draft.id)
        XCTAssertTrue(reply.changed)

        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.pendingPlan)
        XCTAssertEqual(snapshot.events.filter { $0.planID == draft.id }.count, draft.previewEvents.count)
    }

    func testChineseApprovalAddsTheDraft() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "好")
        XCTAssertEqual(reply.committedPlanID, draft.id)
        let pending = await store.pendingPlan()
        XCTAssertNil(pending)
    }

    func testTypedAbandonmentDiscardsTheDraft() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "cancel the plan")
        XCTAssertEqual(reply.discardedPlanID, draft.id)
        XCTAssertNil(reply.committedPlanID)
        XCTAssertFalse(reply.changed)
        XCTAssertEqual(reply.text, ReplyFormatter.planDiscarded)

        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.pendingPlan)
        XCTAssertTrue(snapshot.events.filter { $0.planID != nil }.isEmpty)
        XCTAssertTrue(snapshot.nudges.isEmpty)
    }

    func testDiscardPlanDropsTheDraft() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = await assistant.discardPlan(draft)
        XCTAssertEqual(reply.discardedPlanID, draft.id)
        let pending = await store.pendingPlan()
        XCTAssertNil(pending)
    }

    // MARK: Keep editing

    func testUnrecognisedReplyAsksWhatToChange() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "hmm")
        XCTAssertNil(reply.planDraft)
        XCTAssertTrue(reply.needsClarification)
        XCTAssertEqual(reply.suggestions, ReplyFormatter.planEditSuggestions)
        XCTAssertEqual(reply.suggestions.count, 4)
        XCTAssertTrue(reply.text.contains(ReplyFormatter.planEditQuestion))
        let pending = await store.pendingPlan()
        XCTAssertEqual(pending, draft)
    }

    func testSuggestionChipsLeadToARevision() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let question = try await ask(assistant, "Change the time")
        XCTAssertNil(question.planDraft)
        XCTAssertTrue(question.needsClarification)
        XCTAssertTrue(question.suggestions.contains("7am"))

        let answer = try await ask(assistant, "7am")
        let revised = try XCTUnwrap(answer.planDraft)
        XCTAssertEqual(revised.id, draft.id)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(Set(revised.sessions.map(\.startTime)), ["07:00"])

        let shorter = try await ask(assistant, "Make sessions shorter")
        let third = try XCTUnwrap(shorter.planDraft)
        XCTAssertEqual(third.revision, 3)
        XCTAssertEqual(Set(third.sessions.map(\.durationMinutes)), [45])
        XCTAssertEqual(Set(third.sessions.map(\.startTime)), ["07:00"]) // earlier changes are kept

        let days = try await ask(assistant, "Change the training days")
        XCTAssertNil(days.planDraft)
        XCTAssertFalse(days.suggestions.isEmpty)

        let start = try await ask(assistant, "Start on a different date")
        XCTAssertNil(start.planDraft)
        XCTAssertTrue(start.suggestions.contains("Next Monday"))
    }

    func testWeekdayDurationAndTimeChanges() async throws {
        let (assistant, store) = makeAssistant()
        _ = try await startPlan(assistant, store)

        let mwf = try await revise(assistant, "MWF")
        XCTAssertEqual(Set(mwf.sessions.flatMap(\.weekdays)), ["MO", "WE", "FR"])
        // Upper/Lower alternate through the week.
        XCTAssertEqual(mwf.sessions.filter { $0.phaseIndex == 0 }.map(\.weekdays), [["MO", "FR"], ["WE"]])
        XCTAssertEqual(mwf.previewEvents.filter { !$0.isAllDay }.count, 78)

        let fortyFive = try await revise(assistant, "45 min sessions please")
        XCTAssertEqual(Set(fortyFive.sessions.map(\.durationMinutes)), [45])
        XCTAssertEqual(Set(fortyFive.sessions.flatMap(\.weekdays)), ["MO", "WE", "FR"])

        let count = try await revise(assistant, "2 days a week")
        XCTAssertEqual(Set(count.sessions.flatMap(\.weekdays)), ["TU", "FR"])

        let evenings = try await revise(assistant, "move the workouts to evenings")
        XCTAssertEqual(Set(evenings.sessions.map(\.startTime)), ["19:00"])

        let later = try await revise(assistant, "30 min later")
        XCTAssertEqual(Set(later.sessions.map(\.startTime)), ["19:30"])
        XCTAssertEqual(Set(later.sessions.map(\.durationMinutes)), [45]) // a shift, not a new length
        XCTAssertEqual(later.revision, 6)
    }

    func testChineseChangeRequest() async throws {
        let (assistant, store) = makeAssistant()
        _ = try await startPlan(assistant, store)

        let revised = try await revise(assistant, "改成週二四早上7點")
        XCTAssertEqual(Set(revised.sessions.flatMap(\.weekdays)), ["TU", "TH"])
        XCTAssertEqual(Set(revised.sessions.map(\.startTime)), ["07:00"])
        XCTAssertEqual(revised.revision, 2)
    }

    func testStartDateChanges() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let nextMonday = try await revise(assistant, "start next Monday")
        XCTAssertEqual(nextMonday.startDate, TestClock.local(2026, 10, 19))
        XCTAssertEqual(nextMonday.endDate, TestClock.local(2027, 4, 18)) // same length
        XCTAssertEqual(nextMonday.phases.first?.start, TestClock.local(2026, 10, 19))
        XCTAssertEqual(nextMonday.milestones.count, draft.milestones.count)
        let firstSession = try XCTUnwrap(nextMonday.previewEvents.first { !$0.isAllDay })
        XCTAssertEqual(firstSession.start, TestClock.local(2026, 10, 19, 18, 30))

        let november = try await revise(assistant, "Nov 1")
        XCTAssertEqual(november.startDate, TestClock.local(2026, 11, 1))
        XCTAssertEqual(november.revision, 3)
    }

    // MARK: Other requests while a draft is pending

    func testAnotherEventIsCapturedAndTheDraftStaysPending() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "Lunch with Andrew tomorrow 1pm")
        XCTAssertNil(reply.planDraft)
        XCTAssertEqual(reply.created.map(\.title), ["Lunch with Andrew"])
        XCTAssertEqual(reply.created.first?.start, TestClock.local(2026, 10, 14, 13, 0))

        let pending = await store.pendingPlan()
        XCTAssertEqual(pending, draft)
    }

    func testANewGoalReplacesTheDraftAsTheNextRevision() async throws {
        let (assistant, store) = makeAssistant()
        let draft = try await startPlan(assistant, store)

        let reply = try await ask(assistant, "I want to be muscular in 3 months")
        let replacement = try XCTUnwrap(reply.planDraft)
        XCTAssertEqual(replacement.id, draft.id)
        XCTAssertEqual(replacement.revision, 2)
        XCTAssertEqual(replacement.endDate, TestClock.local(2027, 1, 13))
        let pending = await store.pendingPlan()
        XCTAssertEqual(pending?.revision, 2)
    }

    func testWithoutADraftApprovalWordsAreOrdinaryMessages() async throws {
        let (assistant, store) = makeAssistant()
        let reply = try await ask(assistant, "looks good")
        XCTAssertNil(reply.committedPlanID)
        XCTAssertNil(reply.planDraft)
        let pending = await store.pendingPlan()
        XCTAssertNil(pending)
    }
}
