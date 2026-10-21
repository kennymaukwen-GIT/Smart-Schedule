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
///
/// With a router whose new events go to a sample calendar (demo mode: `AccountStore.sampleCalendarsOnly()`), every
/// write stays on this iPhone (`CalendarRouter+Sample.swift`): the prompt adds `AssistantPrompt.demoModeBlock` and
/// the replies say "on this device" where they would name Google Calendar.
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
        /// A departure answer 「該出發了」: `text` holds its kept version (no time from Google); the chat shows `shown`.
        /// In memory only.
        var departure: DepartureReply? = nil

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
    private let rescheduleReminders: @Sendable (SharedStore) async -> Void
    /// Departure reminders 「該出發了」: what `handleFromChat` may use (owner decision 3A: never `handle`).
    private let departureSource: DepartureSource
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
        self.init(gemini: gemini, router: router, store: store, preferences: preferences, clock: clock,
                  rescheduleReminders: { cache in await ReminderScheduler.shared.reschedule(store: cache) })
    }

    /// Every dependency given, none defaulted (so no call can match both initializers).
    /// - Parameter rescheduleReminders: runs after every write. Unit tests pass a no-op because a hostless test
    ///   bundle has no notification center.
    init(gemini: GeminiClient,
         router: CalendarRouter,
         store: SharedStore,
         preferences: PreferencesStore,
         clock: WallClock?,
         rescheduleReminders: @escaping @Sendable (SharedStore) async -> Void) {
        self.init(gemini: gemini, router: router, store: store, preferences: preferences, clock: clock,
                  rescheduleReminders: rescheduleReminders, departures: .installed)
    }

    /// The same, with the departure services given (unit tests pass fakes; the others use what the app installed).
    init(gemini: GeminiClient,
         router: CalendarRouter,
         store: SharedStore,
         preferences: PreferencesStore,
         clock: WallClock?,
         rescheduleReminders: @escaping @Sendable (SharedStore) async -> Void,
         departures: DepartureSource) {
        self.gemini = gemini
        self.router = router
        self.store = store
        self.preferences = preferences
        self.fixedClock = clock
        self.rescheduleReminders = rescheduleReminders
        self.departureSource = departures
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

    /// New events go to a sample calendar (demo mode's router): every write stays on this iPhone.
    private func writesOnDevice(_ ctx: Context) async -> Bool {
        guard let target = try? await ctx.router.defaultTarget() else { return false }
        return CalendarRouter.isSample(target.id)
    }

    /// - Parameter focusEventID: set when replying from a reminder notification, so "push it 30 min"
    ///   resolves to that event without the user naming it.
    /// - Throws: `GeminiError.consentRequired` when AI data sharing is not allowed; nothing was sent.
    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        try await respond(utterance, focusEventID: focusEventID, now: now, offered: nil)
    }

    /// The in-app chat and Quick Capture: the only requests that may plan departures 「該出發了」 (owner decision 3A).
    /// Siri, replies typed on a notification and the long-press card call `handle`, which never does.
    func handleFromChat(_ utterance: String, now: Date = Date()) async throws -> Reply {
        try await respond(utterance, focusEventID: nil, now: now, offered: departureSource.services)
    }

    /// - Parameter offered: the departure services the caller may use; nil = the request behaves exactly as without
    ///   the feature.
    private func respond(_ utterance: String, focusEventID: String?, now: Date,
                         offered: DepartureServices?) async throws -> Reply {
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
        let onDevice = await writesOnDevice(ctx)
        // Off (no services, demo mode, or not available here): Gemini gets exactly what it gets without the feature.
        let departures = await activeDepartures(offered, onDevice: onDevice)

        let system = AssistantPrompt.system(now: now, clock: ctx.clock, locale: .current,
                                            upcoming: upcoming, focus: focus, policy: ctx.mapper.policy, draft: draft,
                                            preferences: ctx.preferences, calendars: calendars,
                                            defaultTarget: defaultTarget, pendingEvents: pendingEvents,
                                            departures: departures != nil)
            + (onDevice ? "\n\n" + AssistantPrompt.demoModeBlock : "")
        // The user's own words, without their Google accounts' addresses ("use example@yourmail.com from now on" →
        // "[Account 2 email]"). The request kept for the events' notes and the reply keeps what they typed.
        var exchange = [GeminiTurn.user(aliases.scrubbingAccountEmails(utterance))]
        // suggest_event_notes has its own request (`suggestNotes`); a chat turn never calls it.
        let earlier = exchanges.flatMap { $0 }
        let response = try await gemini.generate(
            system: system,
            history: (departures == nil ? DepartureTurn.withoutDepartureCalls(earlier) : earlier) + exchange,
            mode: "ANY",
            allowedFunctions: AssistantFunction.conversational(departures: departures != nil).map(\.rawValue),
            including: departures == nil ? [] : GeminiClient.optInFunctions)
        exchange.append(response.modelTurn)

        var reply = Reply()
        var results: [GeminiTurn.FunctionResult] = []
        let requestSeed = UUID().uuidString
        let request = clarifiedRequest.map { "\($0) → \(utterance)" } ?? utterance
        let known = upcoming + [focus].compactMap { $0 }
        // 「該出發了」: a new event's departure is worked out before create_events writes it.
        var plan = departures.map { DeparturePlanState(services: $0.services, availability: $0.availability) }
        if var state = plan {
            await prepareDeparture(&state, calls: response.functionCalls, requestSeed: requestSeed, request: request,
                                   now: now, ctx: ctx, aliases: aliases)
            if ctx.preferences.autonomy == .askFirst {
                Self.carryDepartures(&state, calls: response.functionCalls, replacing: pendingEvents, aliases: aliases)
            }
            plan = state
        }
        for (index, call) in response.functionCalls.enumerated() {
            if let state = plan, state.answers, call.name == AssistantFunction.replyToUser.rawValue {
                // The app answers about the departure itself: Gemini's own words could state a travel time.
                results.append(.init(name: call.name, id: call.id, responseJSON: Data(#"{"ok":true}"#.utf8)))
                continue
            }
            let outcome: [String: Any]
            do {
                outcome = try await execute(call, seed: "\(requestSeed)|\(index)", utterance: utterance, request: request,
                                            upcoming: known, now: now, aliases: aliases, ctx: ctx,
                                            newEventDepartures: index == plan?.createCallIndex
                                                ? plan?.departuresToWrite ?? [:] : [:],
                                            reply: &reply)
            } catch {
                // Gemini reads the error on the next turn: no address in it ("Google sign-in for … expired" names
                // the account). The reply on this iPhone keeps the full text.
                outcome = ["ok": false, "error": aliases.redactingEmails(error.localizedDescription)]
                reply.append(error.localizedDescription)
            }
            let json = (try? JSONSerialization.data(withJSONObject: outcome)) ?? Data("{}".utf8)
            results.append(.init(name: call.name, id: call.id, responseJSON: json))
        }
        if let state = plan, let index = state.callIndex, results.indices.contains(index) {
            // Only a fixed value goes back to Gemini: never a place, a time, a route or a reason.
            let saved = await finishDeparture(state, known: known, now: now, ctx: ctx, reply: &reply)
            let json = (try? JSONSerialization.data(withJSONObject: DepartureTurn.functionResult(saved))) ?? Data("{}".utf8)
            results[index] = .init(name: results[index].name, id: results[index].id, responseJSON: json)
        }
        if !results.isEmpty { exchange.append(.functionResponses(results)) }
        remember(exchange)
        // A chain of questions keeps the first request; anything else ends it.
        clarifiedRequest = reply.needsClarification ? (clarifiedRequest ?? utterance) : nil

        if reply.text.isEmpty {
            reply.text = response.text.map { aliases.restoringAccountEmails($0) } ?? String(localized: "Done.")
        }
        if reply.waitingToSync { reply.append(Self.waitingToSyncNote) }
        if reply.changed { await rescheduleReminders(store) }
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
        await rescheduleReminders(store)
        var reply = Reply(changed: true)
        let onDevice = await writesOnDevice(ctx)
        if onDevice {
            reply.append(String(localized: "Deleted \(pending.eventIDs.count) items on this device."))
        } else {
            reply.append(String(localized: "Deleted \(pending.eventIDs.count) items from Google Calendar."))
        }
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
        await rescheduleReminders(store)
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
        if CalendarRouter.isSample(target.id) {
            reply.append(String(localized: "Added “\(draft.title)” on this device."))
        } else {
            reply.append(ReplyFormatter.planAdded(draft.title))
        }
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
        try await commitPendingEvents(batch, now: Date())
    }

    /// Same, with the moment of Add given (unit tests): the events are created then, which decides the same-day
    /// reminders (`ReminderPolicy.sameDayMinutes`).
    func commitPendingEvents(_ batch: PendingEventBatch, now: Date) async throws -> Reply {
        let ctx = context()
        let (events, target) = try await writeBatch(batch, ctx: ctx, now: now)
        remember([.user("[app] The user tapped Add; the pending events are now in the calendar.")])
        if lastProposal == .events { lastProposal = nil }
        await rescheduleReminders(store)

        var reply = Reply(changed: true)
        reply.created = events
        reply.addedEvents = events
        reply.committedEventBatchID = batch.id
        reply.showRange = Self.dayRange(of: events, clock: ctx.clock)
        if CalendarRouter.isSample(target.id) {
            reply.append(ReplyFormatter.confirmation(for: events, clock: ctx.clock))
        } else {
            reply.append(ReplyFormatter.pendingEventsAdded(events.count))
        }
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
        let mapped = try args.events.prefix(20).enumerated().map { index, draft -> MappedEvent in
            // Created now, at Add: an item for later today gets the same-day reminders.
            let item = try ctx.mapper.event(from: draft, seed: "\(batch.seed)|\(index)", utterance: batch.utterance,
                                            createdAt: now)
            // A departure planned with the proposal ("Ask me first") is written with the event.
            return Self.withPreviewDeparture(item, batch: batch, index: index)
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
                         newEventDepartures: [Int: DepartureSettings],
                         reply: inout Reply) async throws -> [String: Any] {
        let clock = ctx.clock
        switch AssistantFunction(rawValue: call.name) {
        case .createEvents:
            // "[Account N email]" back to the address before anything is written, kept or shown.
            let restored = Self.restoringAccountEmails(in: call, aliases: aliases)
            let args = try restored.decode(CreateEventsArgs.self)
            let mapped = try args.events.prefix(20).enumerated().map { index, draft -> MappedEvent in
                let item = try ctx.mapper.event(from: draft, seed: "\(seed)|\(index)", utterance: request, createdAt: now)
                // 「該出發了」: the departure worked out for this new event goes into the same insert.
                return newEventDepartures[index].map { CalendarEventMapper.addingDeparture($0, to: item) } ?? item
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
            if CalendarRouter.isSample(target.id) { Self.noteSampleLimits(mapped, saved: inserted, in: &reply) }
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
            // The prompt allows one reply_to_user per turn, but Gemini may still send two (a question, then a decline
            // of an off-topic part): a later call never drops the question or its one-tap answers.
            reply.needsClarification = reply.needsClarification || (args.needsClarification ?? false)
            let suggestions = (args.suggestedReplies ?? []).prefix(3).map { aliases.restoringAccountEmails($0) }
            if !suggestions.isEmpty { reply.suggestions = suggestions }
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
            if Self.touchesNotifications(result.receipt) { await rescheduleReminders(store) }
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

        case .planDeparture:
            // Departure reminders 「該出發了」 (docs/SETTINGS.md §7.11): handle() works the plan out around the calls
            // and replaces this answer with a fixed value. Off, or a second call in one turn: not_set. Never throws
            // (an error's text would go to Gemini).
            return DepartureTurn.functionResult(.notSet)

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
            guard let notes = suggested[Self.mappedID(event.id)]
                ?? event.seriesID.flatMap({ suggested[Self.mappedID($0)] }) else { continue }
            result[index].suggestedNotes = notes
            await store.setSuggestedNotes(notes, for: event)
        }
        return result
    }

    /// The id the mapper gave an event, which `suggestedNotes` is keyed by: a sample calendar's copy carries it after
    /// `demo-` (`CalendarRouter.insertSample`). Google ids never contain "-", so theirs are unchanged.
    private static func mappedID(_ id: String) -> String {
        DemoData.isDemoID(id) ? String(id.dropFirst(DemoData.idPrefix.count)) : id
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

    /// Said when an online event went to a sample calendar: demo mode adds no Google Meet link.
    static var sampleMeetNote: String { String(localized: "Demo mode doesn't create Google Meet links.") }

    /// Said when a repeating event went to a sample calendar as one event: only weekly and every-day repeats expand
    /// there (`CalendarRouter.insertSample`).
    static var sampleRepeatNote: String {
        String(localized: "Demo mode repeats only daily and weekly events, so this one was added once.")
    }

    /// What the sample calendars left out of new events: a Meet link, or the repeat of a series that was not
    /// expanded (none of its occurrences carries its series id).
    static func noteSampleLimits(_ mapped: [MappedEvent], saved: [ScheduleEvent], in reply: inout Reply) {
        if mapped.contains(where: \.wantsConference) { reply.append(sampleMeetNote) }
        let series = Set(saved.compactMap(\.seriesID))
        let addedOnce = mapped.contains { item in
            guard item.body.recurrence != nil, let id = item.body.id else { return false }
            return !series.contains(DemoData.idPrefix + id)
        }
        if addedOnce { reply.append(sampleRepeatNote) }
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

// MARK: - Departures 「該出發了」 (docs/SETTINGS.md §7.11, build step G4d)

extension ScheduleAssistant {
    /// One turn's departure plan. Kept per request (a local value, never on the actor), so a request that arrives while
    /// another waits for Google can't change it.
    private struct DeparturePlanState {
        let services: DepartureServices
        let availability: DepartureAvailability
        /// The turn's first plan_departure call: the one planned for. Any other gets not_set.
        var callIndex: Int?
        var args = PlanDepartureArgs()
        var target: DepartureTurn.Target = .none
        /// A clarifying question in the same turn: nothing is planned until it is answered.
        var asksFirst = false
        /// A new event's departure, worked out before its create_events call runs.
        var createCallIndex: Int?
        var newEventSettings: [Int: DepartureSettings] = [:]
        var newEventAnswer: DepartureAnswer?
        var newEventPlace = ""
        var newEventTarget: Date?
        /// The turn also creates events (create_events).
        var createsEvents = false
        /// The event of create_events this turn's plan was for.
        var plannedIndex: Int?
        /// "Ask me first" revised: the departures new events keep from the proposal they replace, without a new plan.
        var carried: [Int: DepartureSettings] = [:]

        /// What create_events writes: a new plan's settings, else the ones carried over (an event planned this turn
        /// and given none, because it is late, passed or refused, keeps none).
        var departuresToWrite: [Int: DepartureSettings] {
            carried.filter { $0.key != plannedIndex }.merging(newEventSettings) { _, planned in planned }
        }

        /// The app answers about the departure this turn. A call with nothing to plan (no event and no place) leaves
        /// the answer to Gemini's reply_to_user.
        var answers: Bool { callIndex != nil && !asksFirst && target != .none }
    }

    /// What one plan gave.
    private enum DepartureAnswer {
        case planned(DeparturePlanned)
        case refused(DepartureLines.Reason)
    }

    /// Google's answer to one plan.
    private struct DeparturePlanned {
        let outcome: DepartureTurn.Outcome
        /// The way of travelling the answer is for (by car after the one retry).
        let mode: TravelMode
        /// The way of travelling the event keeps: the user's choice, or the app's public transport even when the retry
        /// went by car, so the next plan tries public transport again.
        let keptMode: TravelMode
        let fellBack: Bool
        let plansLeft: Int
        let planToken: String?
        /// The time the plan was checked against: later than the request's after a first 「使用 Google 地圖規劃出發時間？」.
        let now: Date

        /// A time to leave still ahead, for a trip of at most 24 hours.
        var setsReminders: Bool { DepartureTurn.setsReminders(outcome, now: now) }
    }

    /// The departure services for this request, or nil: only what the chat offered, never in demo mode, and only
    /// where the feature is available and not turned off (owner decision 3A).
    private func activeDepartures(_ offered: DepartureServices?,
                                  onDevice: Bool) async -> (services: DepartureServices, availability: DepartureAvailability)? {
        // Not now turns it off here too, whatever the installed availability check reads.
        guard let offered, !onDevice, offered.consent.read() != .declined else { return nil }
        let availability = await offered.availability()
        return availability == .off ? nil : (offered, availability)
    }

    /// Finds the turn's plan_departure and, for a new event, plans it now so create_events writes its departure.
    private func prepareDeparture(_ state: inout DeparturePlanState, calls: [GeminiFunctionCall], requestSeed: String,
                                  request: String, now: Date, ctx: Context, aliases: CalendarAliases) async {
        guard let index = calls.firstIndex(where: { $0.name == AssistantFunction.planDeparture.rawValue }) else { return }
        state.callIndex = index
        state.asksFirst = calls.contains { call in
            call.name == AssistantFunction.replyToUser.rawValue
                && (try? call.decode(ReplyToUserArgs.self))?.needsClarification == true
        }
        guard !state.asksFirst else { return }
        state.args = (try? calls[index].decode(PlanDepartureArgs.self)) ?? PlanDepartureArgs()

        let createIndex = calls.firstIndex { $0.name == AssistantFunction.createEvents.rawValue }
        let drafts: [EventDraft] = createIndex.flatMap { createIndex in
            (try? Self.restoringAccountEmails(in: calls[createIndex], aliases: aliases).decode(CreateEventsArgs.self))
                .map { Array($0.events.prefix(20)) }
        } ?? []
        let starts: [Date?] = drafts.map { $0.allDay == true ? nil : ctx.clock.dateTime($0.start) }
        state.target = DepartureTurn.target(state.args, newEventStarts: starts, clock: ctx.clock)
        state.createsEvents = createIndex != nil
        guard case let .newEvent(eventIndex) = state.target, let createIndex else { return }
        state.createCallIndex = createIndex
        state.plannedIndex = eventIndex

        // The event as create_events will write it (a weekly series starts on its first day).
        let draft = drafts[eventIndex]
        let mapped = try? ctx.mapper.event(from: draft, seed: "\(requestSeed)|\(createIndex)|\(eventIndex)",
                                           utterance: request, createdAt: now)
        let place = Self.nonBlank(state.args.destination) ?? Self.nonBlank(draft.location)
        guard let start = mapped.flatMap({ ctx.mapper.scheduleEvent(from: $0.body) })?.start else {
            state.newEventAnswer = .refused(.allDay)
            return
        }
        guard let place else {
            state.newEventAnswer = .refused(.noPlace)
            return
        }
        let early = DepartureTurn.arriveEarlyMinutes(said: state.args.arriveEarlyMinutes, kept: nil)
        let target = DepartureTurn.target(start: start, arriveEarlyMinutes: early)
        let answer = await planTrip(to: place, by: target, choice: DepartureTurn.mode(said: state.args.mode, kept: nil),
                                    startingPoint: state.args.startingPoint, forEvent: false, services: state.services,
                                    availability: state.availability, now: now, clock: ctx.clock)
        if case let .planned(planned) = answer, planned.setsReminders {
            state.newEventSettings[eventIndex] = DepartureSettings(arriveEarlyMinutes: early, travelMode: planned.keptMode)
        }
        state.newEventAnswer = answer
        state.newEventPlace = place
        state.newEventTarget = target
    }

    /// Plans what the turn's plan_departure was for (an event in the calendar, an arrival or a trip), or reports the
    /// new event's plan, and puts the answer in the reply. Returns what Gemini may be told. Never throws.
    private func finishDeparture(_ state: DeparturePlanState, known: [ScheduleEvent], now: Date, ctx: Context,
                                 reply: inout Reply) async -> DepartureTurn.Saved {
        guard state.answers else { return .notSet }
        let clock = ctx.clock
        switch state.target {
        case .none:
            return .notSet

        case .newEvent:
            guard let answer = state.newEventAnswer else { return .notSet }
            let wanted = !state.newEventSettings.isEmpty
            let saved: DepartureTurn.Saved
            var note: String?
            if wanted, reply.pendingEvents != nil {
                saved = .awaitingApproval
                note = DepartureLines.whenAdded
            } else if wanted, reply.created.contains(where: { $0.departure != nil }) {
                saved = .set
            } else {
                saved = .notSet
                if wanted { note = DepartureLines.notSet }
            }
            if note == nil, case let .planned(planned) = answer, DepartureTurn.isTooLongForReminders(planned.outcome) {
                note = DepartureLines.tooLongForReminders
            }
            Self.add(answer, place: state.newEventPlace, target: state.newEventTarget, note: note, clock: clock, to: &reply)
            return saved

        case let .existingEvent(id):
            guard known.contains(where: { $0.id == id }), let event = await store.event(id: id) else {
                reply.append(AssistantError.unknownEvent(id).localizedDescription)
                return .notSet
            }
            guard !event.isAllDay else {
                Self.add(.refused(.allDay), place: "", target: nil, note: nil, clock: clock, to: &reply)
                return .notSet
            }
            guard let place = Self.nonBlank(event.location) else {
                Self.add(.refused(.noPlace), place: "", target: nil, note: nil, clock: clock, to: &reply)
                return .notSet
            }
            let early = DepartureTurn.arriveEarlyMinutes(said: state.args.arriveEarlyMinutes,
                                                         kept: event.departure?.arriveEarlyMinutes)
            let target = DepartureTurn.target(start: event.start, arriveEarlyMinutes: early)
            let answer = await planTrip(to: place, by: target,
                                        choice: DepartureTurn.mode(said: state.args.mode, kept: event.departure?.travelMode),
                                        startingPoint: state.args.startingPoint, forEvent: true, services: state.services,
                                        availability: state.availability, now: now, clock: clock)
            var saved = DepartureTurn.Saved.notSet
            var note: String?
            if case let .planned(planned) = answer {
                if planned.setsReminders {
                    let settings = DepartureSettings(arriveEarlyMinutes: early, travelMode: planned.keptMode)
                    do {
                        // A repeating event: the whole series (owner decision 2026-10-20).
                        if event.seriesID != nil {
                            let queued = try await ctx.router.patchSeries(of: event, body: ctx.mapper.departurePatch(settings),
                                                                          mapper: ctx.mapper, now: now)
                            if queued { reply.waitingToSync = true }
                        } else {
                            let updated = try await ctx.router.patch(event, body: ctx.mapper.departurePatch(settings),
                                                                     mapper: ctx.mapper, now: now)
                            if updated?.isWaitingToSync == true { reply.waitingToSync = true }
                        }
                        reply.changed = true
                        saved = .set
                    } catch {
                        // To the user only; Gemini gets not_set.
                        note = DepartureLines.notSet + "\n" + error.localizedDescription
                    }
                } else if DepartureTurn.isTooLongForReminders(planned.outcome) {
                    note = DepartureLines.tooLongForReminders
                }
            }
            Self.add(answer, place: place, target: target, note: note, clock: clock, to: &reply)
            return saved

        case let .arriveBy(destination, at):
            let early = DepartureTurn.arriveEarlyMinutes(said: state.args.arriveEarlyMinutes, kept: nil)
            let target = DepartureTurn.target(start: at, arriveEarlyMinutes: early)
            let answer = await planTrip(to: destination, by: target,
                                        choice: DepartureTurn.mode(said: state.args.mode, kept: nil),
                                        startingPoint: state.args.startingPoint, forEvent: false, services: state.services,
                                        availability: state.availability, now: now, clock: clock)
            Self.add(answer, place: destination, target: target, note: Self.noEventNote(state), clock: clock, to: &reply)
            return .notSet

        case let .howLong(destination):
            let answer = await planTrip(to: destination, by: nil,
                                        choice: DepartureTurn.mode(said: state.args.mode, kept: nil),
                                        startingPoint: state.args.startingPoint, forEvent: false, services: state.services,
                                        availability: state.availability, now: now, clock: clock)
            Self.add(answer, place: destination, target: nil, note: Self.noEventNote(state), clock: clock, to: &reply)
            return .notSet
        }
    }

    /// A plan_departure meant for a new event (create_event) that matched none of the turn's new events (Gemini's
    /// arrive_at_local isn't any event's start) is answered as an arrival: say that the new event got no reminders.
    private static func noEventNote(_ state: DeparturePlanState) -> String? {
        state.args.createEvent == true && state.createsEvents && state.carried.isEmpty ? DepartureLines.notSet : nil
    }

    /// "Ask me first" revised ("make it 17:00", a new title or length): a new event that is the same as one in the
    /// proposal it replaces (the same title, or the same place) keeps that one's departure, with no new plan and
    /// nothing sent. The event keeps only the user's two choices, so they hold for a new time too; rule 13 asks Gemini
    /// to plan again when the time or the place changes, to show the new time to leave.
    private static func carryDepartures(_ state: inout DeparturePlanState, calls: [GeminiFunctionCall],
                                        replacing batch: PendingEventBatch?, aliases: CalendarAliases) {
        guard let batch, batch.previewEvents.contains(where: { $0.departure != nil }),
              let createIndex = calls.firstIndex(where: { $0.name == AssistantFunction.createEvents.rawValue }),
              state.createCallIndex == nil || state.createCallIndex == createIndex,
              let args = try? restoringAccountEmails(in: calls[createIndex], aliases: aliases).decode(CreateEventsArgs.self)
        else { return }
        state.carried = carriedDepartures(Array(args.events.prefix(20)), from: batch.previewEvents)
        if !state.carried.isEmpty { state.createCallIndex = createIndex }
    }

    /// Each timed new event takes the departure of the first unmatched earlier preview with the same title or place.
    static func carriedDepartures(_ drafts: [EventDraft], from previews: [ScheduleEvent]) -> [Int: DepartureSettings] {
        func key(_ text: String?) -> String? {
            nonBlank(text)?.lowercased()
        }
        var left = previews.filter { $0.departure != nil && !$0.isAllDay }
        var carried: [Int: DepartureSettings] = [:]
        for (index, draft) in drafts.enumerated() where draft.allDay != true && draft.start.contains("T") {
            guard let match = left.firstIndex(where: { preview in
                (key(preview.title) != nil && key(preview.title) == key(draft.title))
                    || (key(preview.location) != nil && key(preview.location) == key(draft.location))
            }) else { continue }
            carried[index] = left[match].departure
            left.remove(at: match)
        }
        return carried
    }

    /// Asks the server for the trip (once, or twice with the one driving retry). Never throws. A request once sent is
    /// never cancelled, even when the turn is: the server counts a plan it answered.
    /// - Parameter target: when to be there; nil for "how long" (leaving now).
    private func planTrip(to destination: String, by target: Date?, choice: DepartureTurn.ModeChoice,
                          startingPoint: String?, forEvent: Bool, services: DepartureServices,
                          availability: DepartureAvailability, now requested: Date,
                          clock: WallClock) async -> DepartureAnswer {
        var now = requested
        var arrival = target.map { DepartureTurn.arrival(by: $0, now: now) }
        if arrival == .passed { return .refused(.passed) }
        let start = DepartureTurn.start(startingPoint: startingPoint, availability: availability)
        if start == .needsTypedStart { return .refused(.needsTypedStart) }
        // 「使用 Google 地圖規劃出發時間？」 and iOS's location prompt wait for the user: the time to be there is checked
        // again, with the time that has gone by, before the location is read and before anything is sent.
        let began = services.currentTime()
        func waited() -> Date {
            requested.addingTimeInterval(max(0, services.currentTime().timeIntervalSince(began)))
        }
        // Nothing goes to Google, and the location isn't read, before Allow (docs/SETTINGS.md §7.11).
        guard await Self.hasConsent(services) else { return .refused(.declined) }
        now = waited()
        arrival = target.map { DepartureTurn.arrival(by: $0, now: now) }
        if arrival == .passed { return .refused(.passed) }
        let origin: TravelOrigin
        switch start {
        case let .typed(text):
            origin = .typed(text)
        case .needsTypedStart:
            return .refused(.needsTypedStart)
        case .currentLocation:
            do {
                origin = .current(try await services.location.currentLocation())
            } catch let error as TravelTimeError {
                return .refused(DepartureLines.reason(error))
            } catch {
                return .refused(.noLocation)
            }
        }
        now = waited()
        arrival = target.map { DepartureTurn.arrival(by: $0, now: now) }
        if arrival == .passed { return .refused(.passed) }
        var mode = choice.mode
        var fellBack = false
        while true {
            guard !Task.isCancelled else { return .refused(.unavailable) }
            let request = DepartureTurn.request(mode: mode, origin: origin, destination: destination,
                                                arrival: arrival ?? .leaveNow(target: now), now: now,
                                                timeZone: clock.timeZone, appLanguage: services.appLanguage,
                                                isoRegion: services.isoRegion, debugBuild: services.debugBuild)
            let routing = services.routing
            // An unstructured task: cancelling this turn doesn't cancel a request already on its way.
            let result = await Task { try await routing.route(request) }.result
            switch result {
            case let .success(.route(route)):
                return .planned(DeparturePlanned(outcome: DepartureTurn.outcome(route, target: arrival?.target, now: now),
                                                 mode: TravelMode(route.mode), keptMode: fellBack ? choice.mode : mode,
                                                 fellBack: fellBack, plansLeft: route.plansLeft, planToken: route.plan,
                                                 now: now))
            case .success(.noRoute):
                if !fellBack, let next = DepartureTurn.fallback(after: choice) {
                    mode = next
                    fellBack = true
                    continue
                }
                return .refused(.noRoute(mode))
            case let .success(.placeNotFound(place, _)):
                return .refused(place == .start ? .startNotFound : .destinationNotFound(forEvent: forEvent))
            case let .failure(error as DepartureRouteError):
                return .refused(DepartureLines.reason(error))
            case .failure:
                return .refused(.unavailable)
            }
        }
    }

    /// The user's answer to 「使用 Google 地圖規劃出發時間？」, asked the first time and kept. Not now turns the feature off.
    private static func hasConsent(_ services: DepartureServices) async -> Bool {
        switch services.consent.read() {
        case .allowed: return true
        case .declined: return false
        case .notAsked:
            let allowed = await services.askConsent()
            services.consent.write(allowed ? .allowed : .declined)
            return allowed
        }
    }

    /// Puts a departure answer in the reply: its kept version in `text` (what history and the Live Activity keep: no
    /// time from Google), the shown version in `departure` for the chat.
    private static func add(_ answer: DepartureAnswer, place: String, target: Date?, note: String?, clock: WallClock,
                            to reply: inout Reply) {
        var shown: [String]
        var kept: [String]
        var mode: TravelMode?
        var token: String?
        switch answer {
        case let .planned(planned):
            shown = [DepartureLines.shown(planned.outcome, place: place, target: target, fellBack: planned.fellBack,
                                          clock: clock)]
            kept = [DepartureLines.kept(planned.outcome, place: place, target: target, clock: clock)]
            if let note {
                shown.append(note)
                kept.append(note)
            }
            let left = DepartureLines.plansLeft(planned.plansLeft)
            shown.append(left)
            kept.append(left)
            mode = planned.mode
            token = planned.planToken
        case let .refused(reason):
            shown = [DepartureLines.failure(reason)]
            kept = shown
        }
        let keptText = kept.joined(separator: "\n")
        reply.append(keptText)
        reply.departure = DepartureReply(shown: shown.joined(separator: "\n"), kept: keptText,
                                         destination: place.isEmpty ? nil : place, mode: mode, planToken: token)
    }

    /// `item` with the departure its preview carried (`PendingEventBatch.previewEvents`, matched by the preview's id).
    /// Unchanged when there is none, which is every batch made without the feature.
    static func withPreviewDeparture(_ item: MappedEvent, batch: PendingEventBatch, index: Int) -> MappedEvent {
        let id = PendingEventBatch.previewID(batchID: batch.id, index: index)
        guard let settings = batch.previewEvents.first(where: { $0.id == id })?.departure else { return item }
        return CalendarEventMapper.addingDeparture(settings, to: item)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
