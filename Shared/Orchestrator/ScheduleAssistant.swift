import Foundation

enum AssistantError: LocalizedError {
    case unknownEvent(String)
    case badRange
    case noPendingPlan

    var errorDescription: String? {
        switch self {
        // The id is left out: it means nothing to the user, and Gemini knows which id it sent.
        case .unknownEvent: String(localized: "I couldn't find that event. Try naming it and the day.")
        case .badRange: String(localized: "I couldn't work out which dates you meant.")
        case .noPendingPlan: String(localized: "There is no draft plan waiting for review.")
        }
    }
}

/// Utterance → Gemini (function calling) → Google Calendar → reply.
/// Shared by the chat panel, Quick Capture, Siri/App Intents and the notification content extension.
///
/// Preferences, the clock and the mapper are read per request (never cached in the singleton), so a change in
/// Settings or by voice applies to the very next request. Every Google write goes through `CalendarRouter`: new
/// events to the default calendar, edits and deletes to the calendar that owns the event.
actor ScheduleAssistant {
    struct PendingDeletion: Sendable, Equatable {
        let eventIDs: [String]
        let planID: String?
        let summary: String
        /// Where each id lives; empty in demo mode.
        var refs: [EventRef] = []
    }

    struct Reply: Sendable {
        /// Short text version of the reply: what Siri, notifications and VoiceOver read. Chat renders the
        /// structured fields below where they are set.
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
        /// Events this reply just created, one confirmation row each ("Added to Google Calendar").
        /// Plans are not listed here; their card shows the added state instead.
        var addedEvents: [ScheduleEvent] = []
        /// The answer to a schedule question, for the agenda card.
        var agenda: AgendaDigest?
        /// "Ask me first": single events waiting for Add. Nothing has been written yet.
        var pendingEvents: PendingEventBatch?
        /// Set when a pending batch was added to the calendar.
        var committedEventBatchID: String?
        /// Set when a pending batch was discarded.
        var discardedEventBatchID: String?
        /// update_preferences applied something: the "Settings updated" card with Undo.
        var preferenceReceipt: PreferenceChangeReceipt?
        var rejectedPreferences: [PreferenceRejection] = []
        /// New events went to a calendar this iPhone hides (the default calendar for new events). Google has them
        /// either way; the confirmation offers Show. Nothing is redirected to another calendar.
        var savedToHiddenCalendar: CalendarRef? = nil
        var savedToHiddenCalendarName: String? = nil
        /// Some change could not reach Google and waits in the outbox (shown at once, marked waiting to sync).
        var waitingToSync = false

        mutating func append(_ line: String?) {
            guard let line, !line.isEmpty else { return }
            text = text.isEmpty ? line : text + "\n" + line
        }
    }

    static let shared = ScheduleAssistant()

    /// Which proposal the user saw last, so confirm_plan applies to the newer one when a draft plan and pending
    /// events are both waiting.
    private enum Proposal { case plan, events }

    /// Everything a request reads from settings, built once per request.
    private struct Context {
        let clock: WallClock
        let preferences: AppPreferences
        let mapper: CalendarEventMapper
        let router: CalendarRouter
        var planBuilder: PlanDraftBuilder { PlanDraftBuilder(mapper: mapper) }
    }

    private let gemini: GeminiClient
    private let router: CalendarRouter
    private let store: SharedStore
    private let preferences: PreferencesStore
    private let fixedClock: WallClock?
    /// Each exchange = [user text, model turn, function responses]. Trimmed by whole exchanges so a
    /// functionCall is never separated from its functionResponse (Gemini rejects that).
    private var exchanges: [[GeminiTurn]] = []
    private let maxExchanges = 6
    private var lastProposal: Proposal?
    /// What the user asked before Gemini asked back ("明天下午開會" before "14:00"): the events the answer creates
    /// keep it in their notes, not only "14:00".
    private var clarifiedRequest: String?

    /// - Parameter clock: nil = `Settings › Time zone` and "Week starts on", read per request.
    init(gemini: GeminiClient = GeminiClient(),
         router: CalendarRouter = CalendarRouter(),
         store: SharedStore = .shared,
         preferences: PreferencesStore = .shared,
         clock: WallClock? = nil) {
        self.gemini = gemini
        self.router = router
        self.store = store
        self.preferences = preferences
        self.fixedClock = clock
    }

    func resetConversation() {
        exchanges.removeAll()
        lastProposal = nil
        clarifiedRequest = nil
    }

    private func context() -> Context {
        let current = self.preferences.current()
        let clock = fixedClock ?? WallClock(timeZone: current.timeZone, firstWeekday: current.firstWeekday)
        let mapper = CalendarEventMapper(clock: clock,
                                         policy: ReminderPolicy(preferences: current),
                                         defaultEventMinutes: current.defaultEventMinutes)
        var requestRouter = self.router
        requestRouter.clock = clock
        requestRouter.store = store
        return Context(clock: clock, preferences: current, mapper: mapper, router: requestRouter)
    }

    /// - Parameter focusEventID: set when replying from a reminder notification, so "push it 30 min"
    ///   resolves to that event without the user naming it.
    /// - Throws: `GeminiError.consentRequired` when AI data sharing is not allowed; nothing was sent.
    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        let ctx = context()
        let window = DateInterval(start: ctx.clock.calendar.startOfDay(for: now), duration: 14 * 86_400)
        let upcoming = await store.events(in: window)
        var focus: ScheduleEvent?
        if let focusEventID { focus = await store.event(id: focusEventID) }
        let draft = await store.pendingPlan()
        let pendingEvents = await store.pendingEventBatch()
        let calendars = await ctx.router.accounts.calendars()
        let defaultTarget = await ctx.router.accounts.defaultWriteTarget()?.id
        // The same names the prompt uses: function results name calendars this way too, and hold no account address.
        let aliases = CalendarAliases(calendars: calendars)

        let system = AssistantPrompt.system(now: now, clock: ctx.clock, locale: .current,
                                            upcoming: upcoming, focus: focus, policy: ctx.mapper.policy, draft: draft,
                                            preferences: ctx.preferences, calendars: calendars,
                                            defaultTarget: defaultTarget, pendingEvents: pendingEvents)
        // The user's own words, without their Google accounts' addresses ("use example@yourmail.com from now on" →
        // "[Account 2 email]"). The request kept for the events' notes and the reply keeps what they typed.
        var exchange = [GeminiTurn.user(aliases.scrubbingAccountEmails(utterance))]
        // suggest_event_notes has its own request (`suggestNotes`); a chat turn never calls it.
        let response = try await gemini.generate(system: system, history: exchanges.flatMap { $0 } + exchange,
                                                 allowedFunctions: AssistantFunction.conversational.map(\.rawValue))
        exchange.append(response.modelTurn)

        var reply = Reply()
        var results: [GeminiTurn.FunctionResult] = []
        let requestSeed = UUID().uuidString
        let request = clarifiedRequest.map { "\($0) → \(utterance)" } ?? utterance
        for (index, call) in response.functionCalls.enumerated() {
            let outcome: [String: Any]
            do {
                outcome = try await execute(call, seed: "\(requestSeed)|\(index)", utterance: utterance, request: request,
                                            upcoming: upcoming + [focus].compactMap { $0 }, now: now, aliases: aliases,
                                            ctx: ctx, reply: &reply)
            } catch {
                // Gemini reads the error on the next turn: no address in it ("Google sign-in for … expired" names
                // the account). The reply on this iPhone keeps the full text.
                outcome = ["ok": false, "error": aliases.redactingEmails(error.localizedDescription)]
                reply.append(error.localizedDescription)
            }
            let json = (try? JSONSerialization.data(withJSONObject: outcome)) ?? Data("{}".utf8)
            results.append(.init(name: call.name, id: call.id, responseJSON: json))
        }
        if !results.isEmpty { exchange.append(.functionResponses(results)) }
        remember(exchange)
        // A chain of questions keeps the first request; anything else ends it.
        clarifiedRequest = reply.needsClarification ? (clarifiedRequest ?? utterance) : nil

        if reply.text.isEmpty {
            reply.text = response.text.map { aliases.restoringAccountEmails($0) } ?? String(localized: "Done.")
        }
        if reply.waitingToSync { reply.append(Self.waitingToSyncNote) }
        if reply.changed { await ReminderScheduler.shared.reschedule(store: store) }
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func confirm(_ pending: PendingDeletion) async throws -> Reply {
        let ctx = context()
        // Without refs (a deletion prepared before events carried their calendar) the router uses the default one.
        let refs = pending.refs.isEmpty
            ? pending.eventIDs.map { EventRef(accountID: nil, calendarID: nil, eventID: $0) }
            : pending.refs
        let queued = try await ctx.router.delete(refs, now: Date())
        if let planID = pending.planID { await store.removeNudges(planID: planID) }
        await ReminderScheduler.shared.reschedule(store: store)
        var reply = Reply(changed: true)
        reply.append(String(localized: "Deleted \(pending.eventIDs.count) items from Google Calendar."))
        if queued {
            reply.waitingToSync = true
            reply.append(Self.waitingToSyncNote)
        }
        return reply
    }

    // MARK: - Draft plans

    func commitPlan(_ draft: PlanDraft) async throws -> Reply {
        let ctx = context()
        let reply = try await writePlan(draft, ctx: ctx, now: Date())
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
    private func writePlan(_ draft: PlanDraft, ctx: Context, now: Date) async throws -> Reply {
        let args = try PlanDraftBuilder.decodeArgs(draft.argsJSON)
        let mapped = try ctx.mapper.events(fromPlan: args, planID: draft.id, utterance: draft.utterance)
        let target = try await ctx.router.defaultTarget()
        let saved = try await ctx.router.insert(mapped, into: target, mapper: ctx.mapper, now: now)
        if let nudge = ctx.mapper.nudge(from: args, planID: draft.id) { await store.addNudge(nudge) }
        await clearPendingPlan(id: draft.id)

        var reply = Reply(changed: true)
        reply.committedPlanID = draft.id
        reply.showRange = firstWeek(of: draft, clock: ctx.clock)
        reply.append(ReplyFormatter.planAdded(draft.title))
        Self.noteHidden(target, in: &reply)
        if saved.contains(where: \.isWaitingToSync) {
            reply.waitingToSync = true
            reply.append(Self.waitingToSyncNote)
        }
        return reply
    }

    private func clearPendingPlan(id: String) async {
        if await store.pendingPlan()?.id == id { await store.setPendingPlan(nil) }
    }

    private func firstWeek(of draft: PlanDraft, clock: WallClock) -> DateInterval {
        let end = clock.calendar.date(byAdding: .day, value: 7, to: draft.startDate) ?? draft.startDate.addingTimeInterval(7 * 86_400)
        return DateInterval(start: draft.startDate, end: end)
    }

    // MARK: - "Ask me first" pending events

    /// "Add" on a pending events card: writes the batch to its calendar (the default one if that calendar is gone
    /// or read-only) and clears the slot. The batch's seed gives the same Google ids every time, so a second Add is
    /// an idempotent 409, not a duplicate.
    func commitPendingEvents(_ batch: PendingEventBatch) async throws -> Reply {
        let ctx = context()
        let (events, target) = try await writeBatch(batch, ctx: ctx, now: Date())
        remember([.user("[app] The user tapped Add; the pending events are now in the calendar.")])
        if lastProposal == .events { lastProposal = nil }
        await ReminderScheduler.shared.reschedule(store: store)

        var reply = Reply(changed: true)
        reply.created = events
        reply.addedEvents = events
        reply.committedEventBatchID = batch.id
        reply.showRange = Self.dayRange(of: events, clock: ctx.clock)
        reply.append(ReplyFormatter.pendingEventsAdded(events.count))
        Self.noteHidden(target, in: &reply)
        if events.contains(where: \.isWaitingToSync) {
            reply.waitingToSync = true
            reply.append(Self.waitingToSyncNote)
        }
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func discardPendingEvents(_ batch: PendingEventBatch) async -> Reply {
        await clearPendingBatch(id: batch.id)
        remember([.user("[app] The user discarded the pending events; nothing was added to the calendar.")])
        if lastProposal == .events { lastProposal = nil }
        var reply = Reply()
        reply.discardedEventBatchID = batch.id
        reply.append(ReplyFormatter.pendingEventsDiscarded)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    private func writeBatch(_ batch: PendingEventBatch, ctx: Context, now: Date) async throws -> (events: [ScheduleEvent], target: CalendarInfo) {
        let args = try Self.decodeCreateArgs(batch.argsJSON)
        let mapped = try args.events.prefix(20).enumerated().map { index, draft in
            try ctx.mapper.event(from: draft, seed: "\(batch.seed)|\(index)", utterance: batch.utterance)
        }
        let target: CalendarInfo
        if let ref = batch.target, let calendar = await ctx.router.accounts.calendar(ref), calendar.isWritable {
            target = calendar
        } else {
            target = try await ctx.router.defaultTarget()
        }
        let events = try await ctx.router.insert(mapped, into: target, mapper: ctx.mapper, now: now)
        await clearPendingBatch(id: batch.id)
        return (await keepSuggestedNotes(Self.suggestedNotes(args, mapped: mapped), on: events), target)
    }

    /// Mapped but not written: previews with draft ids, the args kept verbatim for Add.
    private func makeBatch(_ mapped: [MappedEvent], argsJSON: Data, seed: String, utterance: String,
                           suggested: [String: [String]] = [:], ctx: Context, now: Date) async -> PendingEventBatch {
        let target = try? await ctx.router.defaultTarget()
        // The single-account stand-in before migration has no account id: Add then uses the default calendar.
        let named = target.flatMap { $0.accountID.isEmpty ? nil : $0 }
        let id = PendingEventBatch.newID()
        let previews = mapped.enumerated().compactMap { (index, item) -> ScheduleEvent? in
            guard var preview = ctx.mapper.scheduleEvent(from: item.body) else { return nil }
            preview.suggestedNotes = item.body.id.flatMap { suggested[$0] }
            preview.id = PendingEventBatch.previewID(batchID: id, index: index)
            preview.seriesID = nil
            return preview
        }
        return PendingEventBatch(id: id, createdAt: now, utterance: utterance, seed: seed, argsJSON: argsJSON,
                                 target: named?.id,
                                 targetLabel: named.map { "\($0.displayName) · \($0.accountEmail)" },
                                 previewEvents: previews)
    }

    private func clearPendingBatch(id: String) async {
        if await store.pendingEventBatch()?.id == id { await store.setPendingEventBatch(nil) }
    }

    static func decodeCreateArgs(_ data: Data) throws -> CreateEventsArgs {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CreateEventsArgs.self, from: data)
    }

    /// The days `events` touch, for jumping the calendar there.
    static func dayRange(of events: [ScheduleEvent], clock: WallClock) -> DateInterval? {
        guard let first = events.map(\.start).min(), let last = events.map(\.end).max() else { return nil }
        let calendar = clock.calendar
        let start = calendar.startOfDay(for: first)
        let end = max(last, calendar.date(byAdding: .day, value: 1, to: start) ?? last)
        return DateInterval(start: start, end: end)
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
                         request: String,
                         upcoming: [ScheduleEvent],
                         now: Date,
                         aliases: CalendarAliases,
                         ctx: Context,
                         reply: inout Reply) async throws -> [String: Any] {
        let clock = ctx.clock
        switch AssistantFunction(rawValue: call.name) {
        case .createEvents:
            // "[Account N email]" back to the address before anything is written, kept or shown.
            let restored = Self.restoringAccountEmails(in: call, aliases: aliases)
            let args = try restored.decode(CreateEventsArgs.self)
            let mapped = try args.events.prefix(20).enumerated().map { index, draft in
                try ctx.mapper.event(from: draft, seed: "\(seed)|\(index)", utterance: request)
            }
            // suggested_notes stay on this iPhone: chips on the card and the event page, never in Google.
            let suggested = Self.suggestedNotes(args, mapped: mapped)
            if ctx.preferences.autonomy == .askFirst {
                // Nothing is written: the batch waits for Add (a newer batch replaces this one).
                let batch = await makeBatch(mapped, argsJSON: restored.argsJSON, seed: seed, utterance: request,
                                            suggested: suggested, ctx: ctx, now: now)
                await store.setPendingEventBatch(batch)
                lastProposal = .events
                reply.pendingEvents = batch
                reply.showRange = Self.dayRange(of: batch.previewEvents, clock: clock)
                reply.append(ReplyFormatter.pendingEventsSummary(batch, clock: clock))
                reply.append(ReplyFormatter.conflicts(batch.previewEvents, against: upcoming))
                reply.append(ReplyFormatter.pendingEventsPrompt)
                return ["ok": true, "status": "awaiting_user_approval", "count": batch.previewEvents.count,
                        "batch_id": batch.id]
            }
            let target = try await ctx.router.defaultTarget()
            let inserted = try await ctx.router.insert(mapped, into: target, mapper: ctx.mapper, now: now)
            let events = await keepSuggestedNotes(suggested, on: inserted)
            reply.created += events
            reply.addedEvents += events
            reply.changed = true
            reply.append(ReplyFormatter.confirmation(for: events, clock: clock))
            reply.append(ReplyFormatter.conflicts(events, against: upcoming))
            Self.noteHidden(target, in: &reply)
            if events.contains(where: \.isWaitingToSync) { reply.waitingToSync = true }
            // Back to Gemini: the titles without the accounts' addresses again.
            return ["ok": true, "created": events.map { ["id": $0.id, "title": aliases.scrubbingAccountEmails($0.title),
                                                         "start": clock.promptDateTimeString($0.start)] }]

        case .createLongTermPlan:
            // Review first: build and store a draft; nothing reaches Google until commitPlan / confirm_plan "add".
            let restored = Self.restoringAccountEmails(in: call, aliases: aliases)
            let args = try restored.decode(LongTermPlanArgs.self)
            let pending = await store.pendingPlan()
            let draft = try ctx.planBuilder.draft(from: args,
                                                  argsJSON: restored.argsJSON,
                                                  id: pending?.id ?? GoogleEventID.newPlanID(),
                                                  revision: (pending?.revision ?? 0) + 1,
                                                  utterance: pending?.utterance ?? request)
            await store.setPendingPlan(draft)
            lastProposal = .plan
            reply.planDraft = draft
            reply.append(args.summaryForUser)
            reply.append(ReplyFormatter.planReviewPrompt)
            reply.assumptions = args.assumptions ?? []
            reply.showRange = firstWeek(of: draft, clock: clock)
            return ["ok": true, "status": "draft_shown_for_review", "plan_id": draft.id, "revision": draft.revision]

        case .confirmPlan:
            let args = try call.decode(ConfirmPlanArgs.self)
            let draft = await store.pendingPlan()
            let batch = await store.pendingEventBatch()
            // Both waiting: the one shown last; in a fresh process (no memory of it) the pending events.
            let decidesEvents: Bool
            switch (draft, batch) {
            case (nil, nil): throw AssistantError.noPendingPlan
            case (.some, nil): decidesEvents = false
            case (nil, .some): decidesEvents = true
            case (.some, .some): decidesEvents = lastProposal != .plan
            }
            let decision = args.decision.lowercased()
            if decidesEvents, let batch {
                switch decision {
                case "add":
                    let (events, target) = try await writeBatch(batch, ctx: ctx, now: now)
                    if lastProposal == .events { lastProposal = nil }
                    reply.changed = true
                    reply.created += events
                    reply.addedEvents += events
                    reply.committedEventBatchID = batch.id
                    reply.showRange = Self.dayRange(of: events, clock: clock)
                    reply.append(ReplyFormatter.confirmation(for: events, clock: clock))
                    Self.noteHidden(target, in: &reply)
                    if events.contains(where: \.isWaitingToSync) { reply.waitingToSync = true }
                    return ["ok": true, "status": "added_to_calendar", "batch_id": batch.id, "count": events.count]
                case "discard":
                    await clearPendingBatch(id: batch.id)
                    if lastProposal == .events { lastProposal = nil }
                    reply.discardedEventBatchID = batch.id
                    reply.append(ReplyFormatter.pendingEventsDiscarded)
                    return ["ok": true, "status": "discarded", "batch_id": batch.id]
                default:
                    return ["ok": false, "error": "decision must be add or discard"]
                }
            }
            guard let draft else { throw AssistantError.noPendingPlan }
            switch decision {
            case "add":
                var done = try await writePlan(draft, ctx: ctx, now: now)
                if lastProposal == .plan { lastProposal = nil }
                reply.changed = true
                reply.committedPlanID = draft.id
                reply.showRange = done.showRange
                reply.savedToHiddenCalendar = done.savedToHiddenCalendar ?? reply.savedToHiddenCalendar
                reply.savedToHiddenCalendarName = done.savedToHiddenCalendarName ?? reply.savedToHiddenCalendarName
                if done.waitingToSync {
                    // handle() adds the note once for the whole turn.
                    done.text = done.text.replacingOccurrences(of: Self.waitingToSyncNote, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    reply.waitingToSync = true
                }
                reply.append(done.text)
                return ["ok": true, "status": "added_to_calendar", "plan_id": draft.id]
            case "discard":
                await clearPendingPlan(id: draft.id)
                if lastProposal == .plan { lastProposal = nil }
                reply.discardedPlanID = draft.id
                reply.append(ReplyFormatter.planDiscarded)
                return ["ok": true, "status": "discarded", "plan_id": draft.id]
            default:
                return ["ok": false, "error": "decision must be add or discard"]
            }

        case .modifyEvent:
            let args = try Self.restoringAccountEmails(in: call, aliases: aliases).decode(ModifyEventArgs.self)
            guard let existing = upcoming.first(where: { $0.id == args.eventId }) else {
                throw AssistantError.unknownEvent(args.eventId) // blocks hallucinated ids from touching real events
            }
            let patch = ctx.mapper.patch(from: args.changes, existing: existing)
            if args.scope == "all_occurrences", existing.seriesID != nil {
                // A new start moves every occurrence to its time of day, worked out against the series master.
                let newStart = args.changes.start.flatMap(clock.dateTime)
                let duration = args.changes.durationMinutes.map { TimeInterval($0) * 60 } ?? existing.duration
                let queued = try await ctx.router.patchSeries(of: existing, body: patch, newStart: newStart,
                                                              duration: duration, mapper: ctx.mapper, now: now)
                if queued { reply.waitingToSync = true }
                reply.append(ReplyFormatter.updated(nil, clock: clock))
            } else {
                let updated = try await ctx.router.patch(existing, body: patch, mapper: ctx.mapper, now: now)
                if updated?.isWaitingToSync == true { reply.waitingToSync = true }
                reply.append(ReplyFormatter.updated(updated, clock: clock))
            }
            reply.changed = true
            return ["ok": true]

        case .deleteEvents:
            let args = try call.decode(DeleteEventsArgs.self)
            let known = Dictionary(upcoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var refs: [EventRef] = (args.eventIds ?? []).compactMap { id in
                guard let event = known[id] else { return nil }
                let target = args.scope == "all_occurrences" ? (event.seriesID ?? id) : id
                return EventRef(accountID: event.accountID, calendarID: event.calendarID, eventID: target)
            }
            if let planID = args.planId {
                refs += try await ctx.router.planEventRefs(planID: planID, now: now)
            }
            var seenRefs = Set<EventRef>()
            refs = refs.filter { seenRefs.insert($0).inserted }
            var seenIDs = Set<String>()
            let ids = refs.map(\.eventID).filter { seenIDs.insert($0).inserted }
            guard !ids.isEmpty else { throw AssistantError.unknownEvent(args.eventIds?.first ?? args.planId ?? "?") }

            let titles = ids.compactMap { known[$0]?.title }
            let pending = PendingDeletion(eventIDs: ids, planID: args.planId,
                                          summary: titles.isEmpty ? ReplyFormatter.itemCount(ids.count)
                                                                  : titles.prefix(3).joined(separator: ", "),
                                          refs: refs)
            if ids.count == 1, args.planId == nil, args.scope != "all_occurrences" {
                var done = try await confirm(pending) // single, explicit, reversible in Google's Trash
                if done.waitingToSync {
                    done.text = done.text.replacingOccurrences(of: Self.waitingToSyncNote, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    reply.waitingToSync = true
                }
                reply.append(done.text)
                reply.changed = true
                return ["ok": true, "deleted": ids]
            }
            reply.pendingDeletion = pending // bulk deletes always need a tap
            reply.append(ReplyFormatter.deletePrompt(pending.summary))
            return ["ok": true, "status": "awaiting_user_confirmation", "count": ids.count]

        case .querySchedule:
            let args = try call.decode(QueryScheduleArgs.self)
            guard let first = clock.date(args.rangeStart) else { throw AssistantError.badRange }
            let last = max(args.rangeEnd.flatMap(clock.date) ?? first, first)
            let interval = DateInterval(start: first, end: clock.calendar.date(byAdding: .day, value: 1, to: last)!)
            let events = await store.events(in: interval)
            let digest = AgendaDigest(range: interval,
                                      title: ReplyFormatter.agendaTitle(for: interval, now: now, clock: clock),
                                      events: events)
            reply.showRange = interval
            reply.agenda = digest
            reply.append(ReplyFormatter.agenda(digest, clock: clock))
            return ["ok": true, "count": events.count]

        case .replyToUser:
            let args = try call.decode(ReplyToUserArgs.self)
            reply.append(aliases.restoringAccountEmails(args.message))
            reply.needsClarification = args.needsClarification ?? false
            reply.suggestions = (args.suggestedReplies ?? []).prefix(3).map { aliases.restoringAccountEmails($0) }
            return ["ok": true]

        case .updatePreferences:
            let args = try call.decode(UpdatePreferencesArgs.self)
            var requests: [PreferenceChangeRequest] = []
            var rejected: [PreferenceRejection] = []
            for change in args.changes.prefix(8) {
                let name = change.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let key = PreferenceKey(rawValue: name) {
                    requests.append(PreferenceChangeRequest(key: key, value: change.value))
                } else {
                    rejected.append(PreferenceRejection(key: change.key, value: change.value, reason: "unknown key"))
                }
            }
            let accounts = ctx.router.accounts
            let result = await preferences.apply(requests, source: .voice(utterance: utterance),
                                                 resolveCalendar: { text in
                // A CALENDARS line ("Gym | Account 2", or "[Account 2 email]" for an address the user typed) first.
                // The user's own words ("my school account") are then matched on this iPhone; an alias that matches no
                // single calendar (an "Account 3" that is gone, a name two accounts share) is refused so the model
                // asks, never guessed.
                if let calendar = aliases.writableCalendar(matching: text) {
                    return CalendarChoice(ref: calendar.id, label: calendar.promptLabel)
                }
                guard !aliases.refersToAlias(text) else { return nil }
                return await accounts.resolveWritableCalendar(matching: text)
                    .map { CalendarChoice(ref: $0.id, label: $0.promptLabel) }
            })
            rejected += result.rejected
            Self.describe(result.receipt, rejected: rejected, summary: aliases.restoringAccountEmails(args.summaryForUser),
                          in: &reply)
            if Self.touchesNotifications(result.receipt) { await ReminderScheduler.shared.reschedule(store: store) }
            // The stored label ("My calendar | <email>") stays on this iPhone: Gemini gets the CALENDARS label.
            let applied: [[String: String]] = (result.receipt?.changes ?? []).map { change in
                ["key": change.key.rawValue,
                 "old": aliases.promptValue(canonical: change.oldValue, for: change.key),
                 "new": aliases.promptValue(canonical: change.newValue, for: change.key)]
            }
            let refused: [[String: String]] = rejected.map { rejection in
                ["key": rejection.key, "value": aliases.redactingEmails(rejection.value),
                 "reason": aliases.redactingEmails(rejection.reason)]
            }
            return ["ok": rejected.isEmpty, "applied": applied, "rejected": refused]

        case .suggestEventNotes:
            // Only allowed in suggestNotes' own request; a chat turn that calls it changes nothing.
            return ["ok": false, "error": "suggest_event_notes is only for the note suggestion request"]

        case nil:
            return ["ok": false, "error": "unknown function \(call.name)"]
        }
    }

    /// `call` with "[Account N email]" turned back into the accounts' addresses in every string of its arguments
    /// (`CalendarAliases.restoringAccountEmails`), for the functions whose text reaches Google Calendar or the user.
    /// The call as Gemini sent it stays in the history. Unchanged when no placeholder could be in it.
    private static func restoringAccountEmails(in call: GeminiFunctionCall,
                                               aliases: CalendarAliases) -> GeminiFunctionCall {
        guard let text = String(data: call.argsJSON, encoding: .utf8),
              text.range(of: "account", options: .caseInsensitive) != nil,
              let object = try? JSONSerialization.jsonObject(with: call.argsJSON),
              object is [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: restoring(object, aliases: aliases)) else { return call }
        return GeminiFunctionCall(name: call.name, id: call.id, argsJSON: data)
    }

    private static func restoring(_ value: Any, aliases: CalendarAliases) -> Any {
        switch value {
        case let text as String: return aliases.restoringAccountEmails(text)
        case let list as [Any]: return list.map { restoring($0, aliases: aliases) }
        case let object as [String: Any]: return object.mapValues { restoring($0, aliases: aliases) }
        default: return value
        }
    }

    // MARK: - Note suggestions

    /// `suggested_notes` per new event, by the Google id the mapper gave it: tidied (`NoteSuggester.cleanedItems`),
    /// at most 4, none that the event's own notes already hold. Events without any are left out.
    static func suggestedNotes(_ args: CreateEventsArgs, mapped: [MappedEvent]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (draft, item) in zip(args.events.prefix(20), mapped) {
            guard let id = item.body.id else { continue }
            let notes = NoteSuggester.cleanedItems(draft.suggestedNotes, existingNotes: draft.notes)
            if !notes.isEmpty, result[id] == nil { result[id] = notes }
        }
        return result
    }

    /// The new events with their `suggestedNotes`, which are also kept on their cached copies (a repeating event's
    /// occurrences included) so the event page shows them. Local only.
    private func keepSuggestedNotes(_ suggested: [String: [String]], on events: [ScheduleEvent]) async -> [ScheduleEvent] {
        guard !suggested.isEmpty else { return events }
        var result = events
        for index in result.indices {
            let event = result[index]
            guard let notes = suggested[event.id] ?? event.seriesID.flatMap({ suggested[$0] }) else { continue }
            result[index].suggestedNotes = notes
            await store.setSuggestedNotes(notes, for: event)
        }
        return result
    }

    /// "✨ AI suggestions" on the event page: one `suggest_event_notes` request of its own (mode ANY, only that
    /// function; the chat history is neither sent nor changed), behind the AI consent like every Gemini call.
    /// Returns the rules the page already shows, then Gemini's items that say something new (at most 4). Nothing is
    /// written or kept.
    /// - Throws: `GeminiError.consentRequired` (nothing was sent), `URLError` offline, other Gemini errors.
    func suggestNotes(for event: ScheduleEvent) async throws -> [NoteSuggestion] {
        try await suggestNotes(for: event, now: Date())
    }

    /// Same, with the request's "today" given (unit tests).
    func suggestNotes(for event: ScheduleEvent, now: Date) async throws -> [NoteSuggestion] {
        let ctx = context()
        // The event as Gemini sees it: no connected account's address in its title, place or notes.
        let calendars = await ctx.router.accounts.calendars()
        let aliases = CalendarAliases(calendars: calendars)
        let chinese = NoteSuggester.usesChinese(for: event)
        let rules = NoteSuggester.ruleSuggestions(for: event, existingNotes: event.notes, preferChinese: chinese,
                                                  homeTimeZone: ctx.clock.timeZone)
        let shown = NoteSuggester.merging(rules, into: NoteSuggester.storedSuggestions(for: event, existingNotes: event.notes),
                                          existingNotes: event.notes, limit: NoteSuggester.requestLimit)
        let response = try await gemini.generate(
            system: NoteSuggestionPrompt.system(chinese: chinese),
            history: [.user(NoteSuggestionPrompt.request(for: aliases.scrubbed(event), clock: ctx.clock, now: now,
                                                         chinese: chinese, alreadySuggested: shown.map(\.text)))],
            mode: "ANY",
            allowedFunctions: [AssistantFunction.suggestEventNotes.rawValue])
        return Self.noteSuggestions(from: response, rules: rules, shown: shown, existingNotes: event.notes)
    }

    /// `rules`, then the items of the response's `suggest_event_notes` call that are not alike anything in `shown`
    /// (the rules and the event's kept suggestions) or in the notes; at most 4 of those.
    static func noteSuggestions(from response: GeminiResponse, rules: [NoteSuggestion], shown: [NoteSuggestion],
                                existingNotes: String?) -> [NoteSuggestion] {
        let call = response.functionCalls.first { $0.name == AssistantFunction.suggestEventNotes.rawValue }
        let items = (call.flatMap { try? $0.decode(SuggestEventNotesArgs.self) })?.items ?? []
        let known = NoteSuggester.merging(shown, into: rules, existingNotes: nil, limit: .max)
        let fresh = NoteSuggester.cleanedItems(items, existingNotes: existingNotes, limit: NoteSuggester.requestLimit)
            .map { NoteSuggestion.ai($0) }
        let merged = NoteSuggester.merging(fresh, into: known, existingNotes: existingNotes, limit: .max)
        let added = merged.filter { suggestion in !known.contains { $0.id == suggestion.id } }.prefix(4)
        return rules + Array(added)
    }

    /// Said when a change could not reach Google: it is on this iPhone and goes out from the outbox.
    static var waitingToSyncNote: String {
        String(localized: "Saved on this iPhone. It will sync to Google Calendar as soon as Google can be reached.")
    }

    /// "Saved to «Gym» (hidden in Smart Schedules)": for Siri and other text-only surfaces; the chat shows a card
    /// with Show instead.
    static func hiddenCalendarNote(_ name: String) -> String {
        String(localized: "Saved to «\(name)» (hidden in Smart Schedules)")
    }

    /// Marks the reply when new events went to a calendar this iPhone hides (its local visibility setting).
    static func noteHidden(_ target: CalendarInfo, in reply: inout Reply) {
        guard !target.isVisible, !target.accountID.isEmpty else { return }
        reply.savedToHiddenCalendar = target.id
        reply.savedToHiddenCalendarName = target.displayName
    }

    /// Reminders, urgency, quiet hours, briefings and the daily limit change what is scheduled; the calendar for new
    /// events, the default length, the week start, the reply language and autonomy do not.
    static func touchesNotifications(_ receipt: PreferenceChangeReceipt?) -> Bool {
        let unrelated: Set<PreferenceKey> = [.defaultCalendar, .defaultDuration, .weekStart, .replyLanguage, .autonomy]
        return receipt?.changes.contains { !unrelated.contains($0.key) } ?? false
    }

    /// The reply to a preference change, shared with `DemoAssistant`: the sentence about what happens from now on
    /// (unless everything was refused), then the text versions of the receipt and the refusals.
    static func describe(_ receipt: PreferenceChangeReceipt?, rejected: [PreferenceRejection], summary: String,
                         in reply: inout Reply) {
        reply.preferenceReceipt = receipt
        reply.rejectedPreferences = rejected
        if receipt != nil || rejected.isEmpty { reply.append(summary) }
        if let receipt { reply.append(ReplyFormatter.preferencesUpdated(receipt)) }
        reply.append(ReplyFormatter.preferencesRejected(rejected))
    }
}
