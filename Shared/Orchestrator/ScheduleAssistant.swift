import Foundation

enum AssistantError: LocalizedError {
    case unknownEvent(String)
    case badRange
    case noPendingPlan

    var errorDescription: String? {
        switch self {
        case let .unknownEvent(id): "I couldn't find that event (\(id)). Try naming it and the day."
        case .badRange: "I couldn't work out which dates you meant."
        case .noPendingPlan: "There is no draft plan waiting for review."
        }
    }
}

/// Utterance → Gemini (function calling) → Google Calendar → reply.
/// Shared by the chat panel, Quick Capture, Siri/App Intents and the notification content extension.
actor ScheduleAssistant {
    struct PendingDeletion: Sendable, Equatable {
        let eventIDs: [String]
        let planID: String?
        let summary: String
    }

    struct Reply: Sendable {
        var text = ""
        var created: [ScheduleEvent] = []
        var changed = false
        var showRange: DateInterval?
        var needsClarification = false
        var suggestions: [String] = []
        var assumptions: [String] = []
        var pendingDeletion: PendingDeletion?
        /// A plan (or a revision of one) ready for review. Nothing has been written yet.
        var planDraft: PlanDraft?
        /// Set when a draft was added to the calendar.
        var committedPlanID: String?
        /// Set when a draft was discarded.
        var discardedPlanID: String?

        mutating func append(_ line: String?) {
            guard let line, !line.isEmpty else { return }
            text = text.isEmpty ? line : text + "\n" + line
        }
    }

    static let shared = ScheduleAssistant()

    private let gemini: GeminiClient
    private let calendar: GoogleCalendarClient
    private let store: SharedStore
    private let mapper: CalendarEventMapper
    private let planBuilder: PlanDraftBuilder
    private let clock: WallClock
    /// Each exchange = [user text, model turn, function responses]. Trimmed by whole exchanges so a
    /// functionCall is never separated from its functionResponse (Gemini rejects that).
    private var exchanges: [[GeminiTurn]] = []
    private let maxExchanges = 6

    init(gemini: GeminiClient = GeminiClient(),
         calendar: GoogleCalendarClient = GoogleCalendarClient(),
         store: SharedStore = .shared,
         clock: WallClock = WallClock(),
         policy: ReminderPolicy = ReminderPolicy()) {
        self.gemini = gemini
        self.calendar = calendar
        self.store = store
        self.clock = clock
        let mapper = CalendarEventMapper(clock: clock, policy: policy)
        self.mapper = mapper
        self.planBuilder = PlanDraftBuilder(mapper: mapper)
    }

    func resetConversation() {
        exchanges.removeAll()
    }

    /// - Parameter focusEventID: set when replying from a reminder notification, so "push it 30 min"
    ///   resolves to that event without the user naming it.
    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        let window = DateInterval(start: clock.calendar.startOfDay(for: now), duration: 14 * 86_400)
        let upcoming = await store.events(in: window)
        var focus: ScheduleEvent?
        if let focusEventID { focus = await store.event(id: focusEventID) }
        let draft = await store.pendingPlan()

        let system = AssistantPrompt.system(now: now, clock: clock, locale: .current,
                                            upcoming: upcoming, focus: focus, policy: mapper.policy, draft: draft)
        var exchange = [GeminiTurn.user(utterance)]
        let response = try await gemini.generate(system: system, history: exchanges.flatMap { $0 } + exchange)
        exchange.append(response.modelTurn)

        var reply = Reply()
        var results: [GeminiTurn.FunctionResult] = []
        let requestSeed = UUID().uuidString
        for (index, call) in response.functionCalls.enumerated() {
            let outcome: [String: Any]
            do {
                outcome = try await execute(call, seed: "\(requestSeed)|\(index)", utterance: utterance,
                                            upcoming: upcoming + [focus].compactMap { $0 }, now: now, reply: &reply)
            } catch {
                outcome = ["ok": false, "error": error.localizedDescription]
                reply.append(error.localizedDescription)
            }
            let json = (try? JSONSerialization.data(withJSONObject: outcome)) ?? Data("{}".utf8)
            results.append(.init(name: call.name, id: call.id, responseJSON: json))
        }
        if !results.isEmpty { exchange.append(.functionResponses(results)) }
        remember(exchange)

        if reply.text.isEmpty { reply.text = response.text ?? String(localized: "Done.") }
        if reply.changed { await ReminderScheduler.shared.reschedule(store: store) }
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func confirm(_ pending: PendingDeletion) async throws -> Reply {
        for id in pending.eventIDs { try await calendar.delete(eventID: id) }
        await store.remove(ids: Set(pending.eventIDs), seriesIDs: Set(pending.eventIDs))
        if let planID = pending.planID { await store.removeNudges(planID: planID) }
        await ReminderScheduler.shared.reschedule(store: store)
        var reply = Reply(changed: true)
        reply.append(String(localized: "Deleted \(pending.eventIDs.count) item(s) from Google Calendar."))
        return reply
    }

    // MARK: - Draft plans

    func commitPlan(_ draft: PlanDraft) async throws -> Reply {
        let reply = try await writePlan(draft, now: Date())
        // Tell Gemini, so "move the gym to 7am" next turn edits the real plan instead of re-drafting it.
        remember([.user("[app] The user tapped Add; the draft plan is now in the calendar.")])
        await ReminderScheduler.shared.reschedule(store: store)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func discardPlan(_ draft: PlanDraft) async -> Reply {
        await clearPendingPlan(id: draft.id)
        remember([.user("[app] The user discarded the draft plan; nothing was added to the calendar.")])
        var reply = Reply()
        reply.discardedPlanID = draft.id
        reply.append(ReplyFormatter.planDiscarded)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    /// The only place a plan reaches Google: the reviewed args, under the draft's id, so every revision the
    /// user saw maps to the same series ids (a double tap on Add is an idempotent 409, not a duplicate).
    private func writePlan(_ draft: PlanDraft, now: Date) async throws -> Reply {
        let args = try PlanDraftBuilder.decodeArgs(draft.argsJSON)
        let mapped = try mapper.events(fromPlan: args, planID: draft.id, utterance: draft.utterance)
        let saved = try await calendar.insertAll(mapped)
        if let nudge = mapper.nudge(from: args, planID: draft.id) { await store.addNudge(nudge) }
        try? await CalendarSync(client: calendar, store: store, clock: clock).refreshWindow(now: now)
        await clearPendingPlan(id: draft.id)

        var reply = Reply(changed: true)
        reply.committedPlanID = draft.id
        reply.showRange = firstWeek(of: draft)
        reply.append(String(localized: "Added \(saved.count) recurring items to Google Calendar."))
        return reply
    }

    private func clearPendingPlan(id: String) async {
        if await store.pendingPlan()?.id == id { await store.setPendingPlan(nil) }
    }

    private func firstWeek(of draft: PlanDraft) -> DateInterval {
        let end = clock.calendar.date(byAdding: .day, value: 7, to: draft.startDate) ?? draft.startDate.addingTimeInterval(7 * 86_400)
        return DateInterval(start: draft.startDate, end: end)
    }

    /// Appends one exchange and trims by whole exchanges.
    private func remember(_ exchange: [GeminiTurn]) {
        exchanges.append(exchange)
        if exchanges.count > maxExchanges { exchanges.removeFirst(exchanges.count - maxExchanges) }
    }

    // MARK: - Function execution

    private func execute(_ call: GeminiFunctionCall,
                         seed: String,
                         utterance: String,
                         upcoming: [ScheduleEvent],
                         now: Date,
                         reply: inout Reply) async throws -> [String: Any] {
        switch AssistantFunction(rawValue: call.name) {
        case .createEvents:
            let args = try call.decode(CreateEventsArgs.self)
            let mapped = try args.events.prefix(20).enumerated().map { index, draft in
                try mapper.event(from: draft, seed: "\(seed)|\(index)", utterance: utterance)
            }
            let saved = try await calendar.insertAll(mapped)
            let events = saved.compactMap(mapper.scheduleEvent(from:))
            if saved.contains(where: { $0.recurrence != nil }) {
                try? await CalendarSync(client: calendar, store: store, clock: clock).refreshWindow(now: now)
            } else {
                await store.upsert(events)
            }
            reply.created += events
            reply.changed = true
            reply.append(ReplyFormatter.confirmation(for: events, clock: clock))
            reply.append(ReplyFormatter.conflicts(events, against: upcoming))
            return ["ok": true, "created": events.map { ["id": $0.id, "title": $0.title,
                                                         "start": clock.promptDateTimeString($0.start)] }]

        case .createLongTermPlan:
            // Review first: build and store a draft; nothing reaches Google until commitPlan / confirm_plan "add".
            let args = try call.decode(LongTermPlanArgs.self)
            let pending = await store.pendingPlan()
            let draft = try planBuilder.draft(from: args,
                                              argsJSON: call.argsJSON,
                                              id: pending?.id ?? GoogleEventID.newPlanID(),
                                              revision: (pending?.revision ?? 0) + 1,
                                              utterance: pending?.utterance ?? utterance)
            await store.setPendingPlan(draft)
            reply.planDraft = draft
            reply.append(args.summaryForUser)
            reply.append(ReplyFormatter.planReviewPrompt)
            reply.assumptions = args.assumptions ?? []
            reply.showRange = firstWeek(of: draft)
            return ["ok": true, "status": "draft_shown_for_review", "plan_id": draft.id, "revision": draft.revision]

        case .confirmPlan:
            let args = try call.decode(ConfirmPlanArgs.self)
            guard let draft = await store.pendingPlan() else { throw AssistantError.noPendingPlan }
            switch args.decision.lowercased() {
            case "add":
                let done = try await writePlan(draft, now: now)
                reply.changed = true
                reply.committedPlanID = draft.id
                reply.showRange = done.showRange
                reply.append(done.text)
                return ["ok": true, "status": "added_to_calendar", "plan_id": draft.id]
            case "discard":
                await clearPendingPlan(id: draft.id)
                reply.discardedPlanID = draft.id
                reply.append(ReplyFormatter.planDiscarded)
                return ["ok": true, "status": "discarded", "plan_id": draft.id]
            default:
                return ["ok": false, "error": "decision must be add or discard"]
            }

        case .modifyEvent:
            let args = try call.decode(ModifyEventArgs.self)
            guard let existing = upcoming.first(where: { $0.id == args.eventId }) else {
                throw AssistantError.unknownEvent(args.eventId) // blocks hallucinated ids from touching real events
            }
            var patch = mapper.patch(from: args.changes, existing: existing)
            if args.scope == "all_occurrences", let seriesID = existing.seriesID {
                if let newStart = args.changes.start.flatMap(clock.dateTime) {
                    let master = try await calendar.get(eventID: seriesID)
                    let duration = args.changes.durationMinutes.map { TimeInterval($0) * 60 } ?? existing.duration
                    let shifted = mapper.seriesTimePatch(master: master, newStart: newStart, duration: duration)
                    patch.start = shifted?.start
                    patch.end = shifted?.end
                }
                _ = try await calendar.patch(eventID: seriesID, patch)
                try? await CalendarSync(client: calendar, store: store, clock: clock).refreshWindow(now: now)
                reply.append(ReplyFormatter.updated(nil, clock: clock))
            } else {
                let saved = try await calendar.patch(eventID: existing.id, patch)
                let updated = mapper.scheduleEvent(from: saved)
                if let updated { await store.upsert([updated]) }
                reply.append(ReplyFormatter.updated(updated, clock: clock))
            }
            reply.changed = true
            return ["ok": true]

        case .deleteEvents:
            let args = try call.decode(DeleteEventsArgs.self)
            let known = Dictionary(upcoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var ids: [String] = (args.eventIds ?? []).compactMap { id in
                guard let event = known[id] else { return nil }
                return args.scope == "all_occurrences" ? (event.seriesID ?? id) : id
            }
            if let planID = args.planId {
                let masters = try await calendar.list(from: now.addingTimeInterval(-365 * 86_400),
                                                      to: now.addingTimeInterval(730 * 86_400),
                                                      singleEvents: false,
                                                      privateProperty: (SSProperty.planID, planID))
                ids += masters.compactMap(\.id)
            }
            ids = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
            guard !ids.isEmpty else { throw AssistantError.unknownEvent(args.eventIds?.first ?? args.planId ?? "?") }

            let titles = ids.compactMap { known[$0]?.title }
            let pending = PendingDeletion(eventIDs: ids, planID: args.planId,
                                          summary: titles.isEmpty ? "\(ids.count) item(s)" : titles.prefix(3).joined(separator: ", "))
            if ids.count == 1, args.planId == nil, args.scope != "all_occurrences" {
                let done = try await confirm(pending) // single, explicit, reversible in Google's Trash
                reply.append(done.text)
                reply.changed = true
                return ["ok": true, "deleted": ids]
            }
            reply.pendingDeletion = pending // bulk deletes always need a tap
            reply.append(String(localized: "Delete \(pending.summary)? Tap Confirm."))
            return ["ok": true, "status": "awaiting_user_confirmation", "count": ids.count]

        case .querySchedule:
            let args = try call.decode(QueryScheduleArgs.self)
            guard let first = clock.date(args.rangeStart) else { throw AssistantError.badRange }
            let last = max(args.rangeEnd.flatMap(clock.date) ?? first, first)
            let interval = DateInterval(start: first, end: clock.calendar.date(byAdding: .day, value: 1, to: last)!)
            let events = await store.events(in: interval)
            reply.showRange = interval
            reply.append(ReplyFormatter.agenda(events, clock: clock))
            return ["ok": true, "count": events.count]

        case .replyToUser:
            let args = try call.decode(ReplyToUserArgs.self)
            reply.append(args.message)
            reply.needsClarification = args.needsClarification ?? false
            reply.suggestions = Array((args.suggestedReplies ?? []).prefix(3))
            return ["ok": true]

        case nil:
            return ["ok": false, "error": "unknown function \(call.name)"]
        }
    }
}
