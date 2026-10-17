import XCTest

/// Demo mode's assistant (`DemoModeAssistant`): the real assistant on the sample calendars, with the offline rules
/// answering, and saying why once, when AI data sharing is off or the AI can't be reached. The AI side here is a
/// `ScheduleAssistant` on demo mode's router (accounts pinned to the samples) with a stubbed Gemini; the offline side a
/// `DemoAssistant` on the same cache. Neither reschedules reminders (a hostless test bundle has no notification
/// center): each records which side wrote instead.
final class DemoModeAssistantTests: XCTestCase {
    typealias Reply = ScheduleAssistant.Reply

    private let files = TemporaryStoreFiles()
    /// Tuesday 2026-10-13 22:50 BST.
    private let now = TestClock.local(2026, 10, 13, 22, 50)
    private let realEmail = "kenny@example.com"
    private let realEventID = "therapy1"
    private let realTitle = "Therapy with Dr Lee"

    private static let granted = AIConsent(status: .granted, version: AIConsent.disclosureVersion)
    private static let declined = AIConsent(status: .declined, version: AIConsent.disclosureVersion)

    /// What the assistant reads as the user's consent and the demo flag; a test may change them mid-conversation.
    private let consentAnswer = DemoModeTestValue(DemoModeAssistantTests.granted)
    private let demoFlag = DemoModeTestValue(true)
    private let writes = DemoModeWriteLog()

    private var consentNote: String { DemoModeAssistant.Fallback.consentOff.note }
    private var unavailableNote: String { DemoModeAssistant.Fallback.unavailable.note }

    override func setUp() {
        super.setUp()
        DemoModeGeminiStub.recorder.reset()
    }

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let assistant: DemoModeAssistant
        let store: SharedStore
        let outbox: SyncOutbox
        let google: DemoModeGoogle
    }

    /// Demo mode on, the sample week in the cache and a hidden copy of one of the user's real events (whose account is
    /// in the accounts file too).
    private func makeRig(consent: AIConsent = DemoModeAssistantTests.granted, askFirst: Bool = false) async -> Rig {
        let consentAnswer = self.consentAnswer
        let demoFlag = self.demoFlag
        let writes = self.writes
        consentAnswer.value = consent

        let file = files.url("DemoModeAssistant-accounts")
        let live = AccountStore(fileURL: file, isDemoMode: { demoFlag.value }, defaultCalendar: { nil })
        await live.upsert(SampleAccounts.account("111", email: realEmail))
        let pinned = AccountStore(fileURL: file, isDemoMode: { true }, defaultCalendar: { nil })
        let store = SharedStore(fileURL: files.url("DemoModeAssistant-cache"), accounts: live)
        await store.replaceWindow(DemoData.seedWindow(now: now, clock: TestClock.clock),
                                  with: DemoData.events(now: now, clock: TestClock.clock))
        await store.upsert([TestEvents.make(id: realEventID, title: realTitle, start: TestClock.local(2026, 10, 14, 9),
                                            end: TestClock.local(2026, 10, 14, 10),
                                            calendar: CalendarRef(accountID: "111", calendarID: realEmail))])
        let preferences = PreferencesStore(fileURL: files.url("DemoModeAssistant-prefs"))
        if askFirst { await preferences.update { $0.autonomy = .askFirst } }

        let outbox = SyncOutbox(fileURL: files.url("DemoModeAssistant-outbox"))
        let google = DemoModeGoogle()
        let router = CalendarRouter(accounts: pinned, tokens: GoogleTokenProvider(accounts: pinned), store: store,
                                    clock: TestClock.clock, transport: google, outbox: outbox)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoModeGeminiStub.self]
        let gemini = GeminiClient(config: GeminiConfig(baseURL: "https://gemini.example.invalid/v1beta", modelID: "test-model",
                                                       apiKey: "test-key", thinkingLevel: nil),
                                  session: URLSession(configuration: configuration),
                                  consentCheck: { consentAnswer.value.isGranted },
                                  attestation: DemoModeAttestation())
        let ai = ScheduleAssistant(gemini: gemini, router: router, store: store, preferences: preferences,
                                   clock: TestClock.clock, rescheduleReminders: { _ in writes.record("ai") })
        let offline = DemoAssistant(store: store, clock: TestClock.clock, preferences: preferences,
                                    rescheduleReminders: { _ in writes.record("offline") })
        let assistant = DemoModeAssistant(ai: ai, offline: offline, consent: { consentAnswer.value },
                                          isDemoMode: { demoFlag.value })
        return Rig(assistant: assistant, store: store, outbox: outbox, google: google)
    }

    private func ask(_ rig: Rig, _ text: String, focus: String? = nil) async throws -> Reply {
        try await rig.assistant.handle(text, focusEventID: focus, now: now)
    }

    /// What Gemini answers to "1個小時後買蛋給 Jocelyn" at 22:50: the call in `create_events.relative_time.json`.
    private func relativeTimeAnswer() throws -> DemoModeGeminiStub.Answer {
        let call = try Fixtures.call("create_events.relative_time.json")
        return .gemini(DemoModeGeminiStub.call(call.name, String(decoding: call.args, as: UTF8.self)))
    }

    private var requestBodies: [String] {
        DemoModeGeminiStub.recorder.bodies.map { String(decoding: $0, as: UTF8.self) }
    }

    private var requestCount: Int { DemoModeGeminiStub.recorder.bodies.count }

    /// Nothing left this iPhone for Google and nothing waits to be sent.
    private func assertNothingReachedGoogle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await rig.google.calls
        XCTAssertEqual(calls, 0, "no token or Calendar request", file: file, line: line)
        let waiting = await rig.outbox.items()
        XCTAssertTrue(waiting.isEmpty, "nothing in the outbox", file: file, line: line)
    }

    // MARK: The AI on the sample calendars

    func testWithConsentTheAIAnswersOnTheSampleCalendars() async throws {
        let rig = await makeRig()
        try DemoModeGeminiStub.recorder.answer([relativeTimeAnswer()])
        let reply = try await ask(rig, "1個小時後買蛋給 Jocelyn")

        XCTAssertEqual(requestCount, 1)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-"), event.id)
        XCTAssertFalse(event.id.hasPrefix("demo-chat-"), "the AI's event, not the offline rules'")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.reminderMinutes, [0])
        XCTAssertTrue(reply.text.hasSuffix(DemoAssistant.demoNote), reply.text)
        XCTAssertFalse(reply.text.contains(unavailableNote), reply.text)
        XCTAssertFalse(reply.text.contains(consentNote), reply.text)
        XCTAssertEqual(writes.entries, ["ai"])
        XCTAssertTrue(requestBodies.first?.contains("# DEMO MODE") == true)
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Falling back to the offline rules

    func testWithoutConsentTheOfflineRulesAnswerAndNothingIsSent() async throws {
        let rig = await makeRig(consent: Self.declined)
        let reply = try await ask(rig, "1個小時後買蛋給 Jocelyn")

        XCTAssertEqual(requestCount, 0)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-chat-"), event.id)
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.reminderMinutes, [0])
        XCTAssertTrue(reply.text.contains(DemoAssistant.demoNote), reply.text)
        XCTAssertTrue(reply.text.hasSuffix(consentNote), reply.text)
        XCTAssertEqual(writes.entries, ["offline"])
        await assertNothingReachedGoogle(rig)
    }

    func testWithoutAConnectionTheOfflineRulesAnswerAndTheNextMessageTriesTheAIAgain() async throws {
        let rig = await makeRig()
        try DemoModeGeminiStub.recorder.answer([.offline, relativeTimeAnswer()])

        let fallback = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(requestCount, 1)
        let offlineEvent = try XCTUnwrap(fallback.addedEvents.first)
        XCTAssertTrue(offlineEvent.id.hasPrefix("demo-chat-"), offlineEvent.id)
        XCTAssertEqual(offlineEvent.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertTrue(fallback.text.hasSuffix(unavailableNote), fallback.text)

        let next = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(requestCount, 2, "tried again")
        let event = try XCTUnwrap(next.addedEvents.first)
        XCTAssertFalse(event.id.hasPrefix("demo-chat-"), event.id)
        XCTAssertFalse(next.text.contains(unavailableNote), next.text)
        XCTAssertEqual(writes.entries, ["offline", "ai"])
        await assertNothingReachedGoogle(rig)
    }

    /// 401 attestation_required: no credential the server accepts (a Release build on the simulator). Asking again
    /// would fail the same way, so the AI is not tried until the conversation is reset.
    func testNoAcceptedCredentialIsNotTriedAgain() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.server(401, #"{"error":"attestation_required"}"#)])

        let first = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(first.addedEvents.map(\.title), ["買蛋給 Jocelyn"])
        XCTAssertTrue(first.text.hasSuffix(unavailableNote), first.text)

        let second = try await ask(rig, "兩小時後打給媽媽")
        XCTAssertEqual(requestCount, 1, "not tried again")
        XCTAssertEqual(second.addedEvents.map(\.title), ["打給媽媽"])
        XCTAssertFalse(second.text.contains(unavailableNote), "said once")

        await rig.assistant.resetConversation()
        _ = try await ask(rig, "今天有什麼行程")
        XCTAssertEqual(requestCount, 2, "a new conversation tries the AI again")
    }

    /// 401 invalid_attestation: the server refused this build's attestation (an App Attest environment, Team ID or
    /// bundle ID it does not check). Every new key is refused the same way, so the AI waits for a new conversation.
    func testARejectedAttestationIsNotTriedAgain() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.server(401, #"{"error":"invalid_attestation"}"#)])

        let first = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(first.addedEvents.map(\.title), ["買蛋給 Jocelyn"])
        XCTAssertTrue(first.text.hasSuffix(unavailableNote), first.text)

        _ = try await ask(rig, "兩小時後打給媽媽")
        XCTAssertEqual(requestCount, 1, "not tried again")
        await assertNothingReachedGoogle(rig)
    }

    /// 429 rate_limited: the limit passes, so the next message asks the AI again.
    func testTheServersRateLimitFallsBackForThatMessageOnly() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.server(429, #"{"error":"rate_limited"}"#)])

        let limited = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(requestCount, 1, "not retried")
        XCTAssertEqual(limited.addedEvents.map(\.title), ["買蛋給 Jocelyn"])
        XCTAssertTrue(limited.text.hasSuffix(unavailableNote), limited.text)

        _ = try await ask(rig, "今天有什麼行程")
        XCTAssertEqual(requestCount, 2, "the next message tries the AI")
    }

    func testEachReasonIsSaidOnceUntilTheAIAnswersAgain() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.offline, .offline])
        let first = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertTrue(first.text.hasSuffix(unavailableNote), first.text)
        let second = try await ask(rig, "兩小時後打給媽媽")
        XCTAssertEqual(second.addedEvents.count, 1)
        XCTAssertFalse(second.text.contains(unavailableNote), second.text)

        let answered = try await ask(rig, "今天有什麼行程") // the stub's plain "OK"
        XCTAssertEqual(answered.text, "OK")

        DemoModeGeminiStub.recorder.answer([.offline])
        let again = try await ask(rig, "半小時後提醒我喝水")
        XCTAssertEqual(again.addedEvents.map(\.title), ["喝水"])
        XCTAssertTrue(again.text.hasSuffix(unavailableNote), "said again after the AI answered: \(again.text)")
        XCTAssertEqual(requestCount, 4)

        // Another reason is said even right after one.
        consentAnswer.value = Self.declined
        let off = try await ask(rig, "10 分鐘後出門")
        XCTAssertEqual(off.addedEvents.count, 1)
        XCTAssertTrue(off.text.hasSuffix(consentNote), off.text)
        XCTAssertEqual(requestCount, 4)
    }

    // MARK: Only sample data

    func testAFocusThatIsNotASampleEventIsNeverUsed() async throws {
        let rig = await makeRig()
        _ = try await ask(rig, "延後 30 分鐘", focus: realEventID)
        _ = try await ask(rig, "延後 30 分鐘", focus: "demo-dentist")

        let bodies = requestBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(bodies[0].contains("# FOCUS"), bodies[0])
        XCTAssertFalse(bodies[0].contains(realEventID), bodies[0])
        XCTAssertFalse(bodies[0].contains(realTitle), bodies[0])
        XCTAssertTrue(bodies[1].contains("# FOCUS"), "a sample event is the focus as usual")

        // Nor by the offline rules, which would otherwise move that hidden copy.
        consentAnswer.value = Self.declined
        let moved = try await ask(rig, "延後 30 分鐘", focus: realEventID)
        XCTAssertTrue(moved.changed, moved.text)
        let real = await rig.store.snapshot().events.first { $0.id == realEventID }
        XCTAssertEqual(real?.start, TestClock.local(2026, 10, 14, 9), "the real event is untouched")
        XCTAssertEqual(requestCount, 2)
    }

    func testAfterDemoModeEndsNothingIsSentOrWritten() async throws {
        let rig = await makeRig()
        let before = await rig.store.snapshot().events
        demoFlag.value = false
        try DemoModeGeminiStub.recorder.answer([relativeTimeAnswer()])

        let reply = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        XCTAssertEqual(reply.text, "Demo mode has ended, so nothing was changed.")
        XCTAssertEqual(reply.text, DemoCalendarError.demoEnded.localizedDescription)
        XCTAssertFalse(reply.changed)
        XCTAssertTrue(reply.addedEvents.isEmpty)
        XCTAssertEqual(requestCount, 0)
        let after = await rig.store.snapshot().events
        XCTAssertEqual(after, before)
        XCTAssertTrue(writes.entries.isEmpty)
        await assertNothingReachedGoogle(rig)
    }

    // MARK: Taps on cards

    func testADeletionGoesToTheSideThatPreparedIt() async throws {
        let rig = await makeRig()
        // The offline rules' deletions carry no refs.
        let offlineDeletion = ScheduleAssistant.PendingDeletion(eventIDs: ["demo-concert"], planID: nil, summary: "Concert")
        let offline = try await rig.assistant.confirm(offlineDeletion)
        XCTAssertTrue(offline.text.hasPrefix("Deleted 1 item"), offline.text)
        XCTAssertEqual(writes.entries, ["offline"])

        // The AI's say where each event lives; its router deletes sample events from the cache only.
        let cached = await rig.store.snapshot().events
        let dentist = try XCTUnwrap(cached.first { $0.id == "demo-dentist" })
        let aiDeletion = ScheduleAssistant.PendingDeletion(
            eventIDs: [dentist.id], planID: nil, summary: dentist.title,
            refs: [EventRef(accountID: dentist.accountID, calendarID: dentist.calendarID, eventID: dentist.id)])
        let viaAI = try await rig.assistant.confirm(aiDeletion)
        XCTAssertTrue(viaAI.text.hasPrefix("Deleted 1 item"), viaAI.text)
        XCTAssertTrue(viaAI.text.contains("on this device."), viaAI.text)
        XCTAssertTrue(viaAI.text.hasSuffix(DemoAssistant.demoNote), viaAI.text)
        XCTAssertEqual(writes.entries, ["offline", "ai"])

        let left = await rig.store.snapshot().events.map(\.id)
        XCTAssertFalse(left.contains("demo-concert"))
        XCTAssertFalse(left.contains("demo-dentist"))
        XCTAssertTrue(left.contains(realEventID))
        XCTAssertEqual(requestCount, 0)
        await assertNothingReachedGoogle(rig)
    }

    func testAPlanIsAddedByTheSideThatDraftedIt() async throws {
        let rig = await makeRig()
        let name = "create_long_term_plan.muscle.json"
        let call = try Fixtures.call(name)
        let args = try TestJSON.decode(LongTermPlanArgs.self, data: call.args)
        let builder = PlanDraftBuilder(mapper: CalendarEventMapper(clock: TestClock.clock, policy: ReminderPolicy()))

        // The offline rules' drafts have demo- ids.
        let offlineDraft = try builder.draft(from: args, argsJSON: call.args, id: "demo-plan-muscle", revision: 1,
                                             utterance: Fixtures.utterance(name))
        let offline = try await rig.assistant.commitPlan(offlineDraft)
        XCTAssertEqual(offline.committedPlanID, offlineDraft.id)
        XCTAssertEqual(writes.entries, ["offline"])

        let aiDraft = try builder.draft(from: args, argsJSON: call.args, id: "planmuscle6m", revision: 1,
                                        utterance: Fixtures.utterance(name))
        let viaAI = try await rig.assistant.commitPlan(aiDraft)
        XCTAssertEqual(viaAI.committedPlanID, aiDraft.id)
        XCTAssertTrue(viaAI.text.hasPrefix("Added “\(aiDraft.title)” on this device."), viaAI.text)
        XCTAssertTrue(viaAI.text.hasSuffix(DemoAssistant.demoNote), viaAI.text)
        XCTAssertEqual(writes.entries, ["offline", "ai"])

        let planned = await rig.store.snapshot().events.filter { $0.planID == aiDraft.id }
        XCTAssertFalse(planned.isEmpty)
        XCTAssertTrue(planned.allSatisfy { $0.id.hasPrefix("demo-") && $0.calendarRef == DemoData.personalCalendar })
        XCTAssertEqual(requestCount, 0)
        await assertNothingReachedGoogle(rig)
    }

    /// "Ask me first" proposed by the offline rules: Add goes through the AI's writer, which keeps the reminder.
    func testPendingEventsAreAddedByTheAIsWriterWithoutTheAI() async throws {
        let rig = await makeRig(consent: Self.declined, askFirst: true)
        let proposed = try await ask(rig, "1個小時後買蛋給 Jocelyn")
        let batch = try XCTUnwrap(proposed.pendingEvents)
        XCTAssertTrue(proposed.addedEvents.isEmpty)

        let reply = try await rig.assistant.commitPendingEvents(batch)
        XCTAssertEqual(reply.committedEventBatchID, batch.id)
        let event = try XCTUnwrap(reply.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-"), event.id)
        XCTAssertEqual(event.title, "買蛋給 Jocelyn")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 13, 23, 50))
        XCTAssertEqual(event.reminderMinutes, [0])
        XCTAssertEqual(event.calendarRef, DemoData.personalCalendar)
        XCTAssertTrue(reply.text.hasPrefix("Added: 買蛋給 Jocelyn"), reply.text)
        XCTAssertFalse(reply.text.contains(ReplyFormatter.pendingEventsAdded(1)), reply.text)
        XCTAssertTrue(reply.text.hasSuffix(DemoAssistant.demoNote), reply.text)
        XCTAssertEqual(writes.entries, ["ai"])
        XCTAssertEqual(requestCount, 0, "Add needs no AI")
        await assertNothingReachedGoogle(rig)
    }

    // MARK: A question carries over

    func testTheOfflineRulesQuestionIsAnsweredByThem() async throws {
        let rig = await makeRig(consent: Self.declined)
        let asked = try await ask(rig, "明天開會")
        XCTAssertTrue(asked.needsClarification, asked.text)
        XCTAssertTrue(asked.text.hasSuffix(consentNote), asked.text)

        consentAnswer.value = Self.granted
        let answer = try await ask(rig, "14:00")
        XCTAssertEqual(requestCount, 0, "the answer goes to the rules that asked")
        let event = try XCTUnwrap(answer.addedEvents.first)
        XCTAssertEqual(event.title, "開會")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 14, 14, 0))
        XCTAssertFalse(answer.text.contains(consentNote), answer.text)

        _ = try await ask(rig, "今天有什麼行程")
        XCTAssertEqual(requestCount, 1, "answered: the next message goes to the AI")
    }

    func testTheAIsQuestionGoesToTheOfflineRulesWhenTheAIFails() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([
            .gemini(DemoModeGeminiStub.call("reply_to_user", #"""
                {"message": "明天幾點開會？", "needs_clarification": true, "suggested_replies": ["14:00"]}
                """#)),
            .offline
        ])
        let asked = try await ask(rig, "明天開會")
        XCTAssertTrue(asked.needsClarification)
        XCTAssertEqual(asked.text, "明天幾點開會？")

        let answer = try await ask(rig, "14:00")
        XCTAssertEqual(requestCount, 2)
        let event = try XCTUnwrap(answer.addedEvents.first)
        XCTAssertTrue(event.id.hasPrefix("demo-chat-"), event.id)
        XCTAssertEqual(event.title, "開會")
        XCTAssertEqual(event.start, TestClock.local(2026, 10, 14, 14, 0))
        XCTAssertEqual(event.notes, CalendarEventMapper.provenancePrefix + "明天開會 14:00")
        XCTAssertTrue(answer.text.hasSuffix(unavailableNote), answer.text)
    }

    // MARK: Consent

    func testWhenTheChatAsksForConsent() {
        let current = AIConsent.disclosureVersion
        XCTAssertTrue(DemoModeAssistant.shouldAskConsent(AIConsent()), "not asked")
        XCTAssertFalse(DemoModeAssistant.shouldAskConsent(AIConsent(status: .declined, version: current)))
        XCTAssertTrue(DemoModeAssistant.shouldAskConsent(AIConsent(status: .declined, version: current - 1)))
        XCTAssertFalse(DemoModeAssistant.shouldAskConsent(AIConsent(status: .granted, version: current)))
        XCTAssertFalse(DemoModeAssistant.shouldAskConsent(AIConsent(status: .revoked, version: current)))
        XCTAssertTrue(DemoModeAssistant.shouldAskConsent(AIConsent(status: .granted, version: current - 1)),
                      "granted for an older disclosure")
    }

    // MARK: AI suggestions on the event page

    /// A sample trip to Tokyo, all day 20–24 October (the rules suggest a passport, entry documents, an adapter and
    /// travel insurance).
    private var sampleTrip: ScheduleEvent {
        var trip = TestEvents.make(id: "demo-trip-tokyo", title: "Tokyo trip", start: TestClock.local(2026, 10, 20),
                                   end: TestClock.local(2026, 10, 25), allDay: true, calendar: DemoData.personalCalendar)
        trip.location = "Tokyo"
        return trip
    }

    private func rules(for event: ScheduleEvent) -> [NoteSuggestion] {
        NoteSuggester.ruleSuggestions(for: event, existingNotes: event.notes, limit: NoteSuggester.requestLimit,
                                      homeTimeZone: TestClock.zone)
    }

    func testSuggestionsForASampleEventComeFromTheAIWithConsent() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.gemini(DemoModeGeminiStub.call(
            "suggest_event_notes", #"{"items": ["Yen cash", "IC transit card"]}"#))])
        let suggestions = try await rig.assistant.suggestNotes(for: sampleTrip)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(suggestions.filter { $0.source == .ai }.map(\.text), ["Yen cash", "IC transit card"])
        XCTAssertFalse(suggestions.filter { $0.source == .rules }.isEmpty)
    }

    func testSuggestionsForAnyOtherEventAreTheRules() async throws {
        let rig = await makeRig()
        var real = sampleTrip
        real.id = realEventID
        real.accountID = "111"
        real.calendarID = realEmail
        let suggestions = try await rig.assistant.suggestNotes(for: real)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(suggestions, rules(for: real))
        XCTAssertFalse(suggestions.isEmpty)
    }

    func testSuggestionsWithoutConsent() async throws {
        // Not asked yet: the event page asks first.
        let rig = await makeRig(consent: AIConsent())
        do {
            _ = try await rig.assistant.suggestNotes(for: sampleTrip)
            XCTFail("expected consentRequired")
        } catch GeminiError.consentRequired {
            // nothing was sent
        } catch {
            XCTFail("unexpected \(error)")
        }

        // "Not now": the rules.
        consentAnswer.value = Self.declined
        let afterNotNow = try await rig.assistant.suggestNotes(for: sampleTrip)
        XCTAssertEqual(afterNotNow, rules(for: sampleTrip))
        XCTAssertEqual(requestCount, 0)
    }

    func testSuggestionsWhenTheAIFailsAreTheRules() async throws {
        let rig = await makeRig()
        DemoModeGeminiStub.recorder.answer([.offline])
        let suggestions = try await rig.assistant.suggestNotes(for: sampleTrip)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(suggestions, rules(for: sampleTrip))
    }
}

// MARK: - Test doubles

/// A value a test changes and the assistant reads, from any thread.
private final class DemoModeTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Which side wrote ("ai" or "offline"), in order: each side's reminder rescheduling, which runs after its writes.
private final class DemoModeWriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sides: [String] = []

    var entries: [String] { lock.lock(); defer { lock.unlock() }; return sides }

    func record(_ side: String) {
        lock.lock()
        sides.append(side)
        lock.unlock()
    }
}

/// No App Attest headers: the stub answers for the server.
private struct DemoModeAttestation: AttestationProviding {
    func headers(for body: Data) async throws -> [String: String] { [:] }
    func reset() async {}
}

/// Counts every token request and Calendar API request (there should be none).
private actor DemoModeGoogle: CalendarTransport {
    private(set) var calls = 0

    func accessToken(accountID: String?, forceRefresh: Bool) async throws -> String {
        calls += 1
        return "test-token"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let url = request.url ?? URL(string: "https://www.googleapis.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (request.httpBody ?? Data(#"{"items":[]}"#.utf8), response)
    }
}

/// Answers each request to the server with the next queued answer (Gemini's plain "OK" once none is left) and keeps
/// every request body.
private final class DemoModeGeminiStub: URLProtocol {
    enum Answer: Sendable {
        /// 200 with this Gemini response.
        case gemini(String)
        /// The server's own error, `{"error": "<code>"}`.
        case server(Int, String)
        /// No connection.
        case offline
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Data] = []
        private var queued: [Answer] = []

        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return recorded }

        /// The answers to the next requests, in order.
        func answer(_ answers: [Answer]) {
            lock.lock()
            queued += answers
            lock.unlock()
        }

        func reset() {
            lock.lock()
            recorded = []
            queued = []
            lock.unlock()
        }

        /// Records `body` and returns the answer for this request.
        func next(_ body: Data?) -> Answer {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(body ?? Data())
            if queued.isEmpty { return .gemini(DemoModeGeminiStub.call("reply_to_user", #"{"message": "OK"}"#)) }
            return queued.removeFirst()
        }
    }

    static let recorder = Recorder()

    /// A Gemini response with one function call; `args` is its JSON object.
    static func call(_ name: String, _ args: String) -> String {
        #"{"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "\#(name)", "args": \#(args)}}]}, "finishReason": "STOP"}]}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        let body: String
        switch Self.recorder.next(Self.bodyData(of: request)) {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case let .gemini(response):
            status = 200
            body = response
        case let .server(code, error):
            status = code
            body = error
        }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://gemini.example.invalid")!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
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
