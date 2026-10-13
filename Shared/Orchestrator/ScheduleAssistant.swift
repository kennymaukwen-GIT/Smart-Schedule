import Foundation

enum AssistantError: LocalizedError {
    case unknownEvent(String)
    case badRange

    var errorDescription: String? {
        switch self {
        case let .unknownEvent(id): "I couldn't find that event (\(id)). Try naming it and the day."
        case .badRange: "I couldn't work out which dates you meant."
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
        self.mapper = CalendarEventMapper(clock: clock, policy: policy)
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

        let system = AssistantPrompt.system(now: now, clock: clock, locale: .current,
                                            upcoming: upcoming, focus: focus, policy: mapper.policy)
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
        exchanges.append(exchange)
        if exchanges.count > maxExchanges { exchanges.removeFirst(exchanges.count - maxExchanges) }

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
            let args = try call.decode(LongTermPlanArgs.self)
            let planID = GoogleEventID.newPlanID()
            let mapped = try mapper.events(fromPlan: args, planID: planID, utterance: utterance)
            let saved = try await calendar.insertAll(mapped)
            if let nudge = mapper.nudge(from: args, planID: planID) { await store.addNudge(nudge) }
            try? await CalendarSync(client: calendar, store: store, clock: clock).refreshWindow(now: now)
            reply.changed = true
            reply.append(args.summaryForUser)
            reply.append(String(localized: "\(saved.count) recurring items added to Google Calendar (\(args.phases.count) phases)."))
            reply.assumptions = args.assumptions ?? []
            reply.showRange = clock.date(args.startDate).map { DateInterval(start: $0, duration: 7 * 86_400) }
            return ["ok": true, "plan_id": planID, "series_created": saved.count]

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
