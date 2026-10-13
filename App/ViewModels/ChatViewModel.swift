import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        var id = UUID()
        var date = Date()
        let role: Role
        /// What the conversation shows. For replies this is `shownText(of:)`, not the whole `Reply.text`.
        var text: String
        var suggestions: [String] = []
        var assumptions: [String] = []
        var pendingDeletion: ScheduleAssistant.PendingDeletion?
        /// A long-term plan shown for review; nothing is in the calendar until the user taps Add.
        var planDraft: PlanDraft?
        var planStatus: PlanCardStatus = .pending
        /// Events the reply put in the calendar, shown as rows instead of a confirmation sentence.
        var addedEvents: [ScheduleEvent] = []
        /// The answer to a schedule question, shown as an aligned list.
        var agenda: AgendaDigest?
        /// "Settings updated": what a lasting instruction changed, with Undo.
        var preferenceReceipt: PreferenceChangeReceipt?
        var receiptUndo: ReceiptUndoState = .available
        /// "You dismissed the … reminder 5 times. Stop sending it?" Its `status` says how it was answered.
        var learnedSuggestion: LearnedSuggestion?
        /// "Ask me first": single events waiting for Add.
        var pendingEvents: PendingEventBatch?
        var pendingEventsStatus: PendingEventsStatus = .pending

        var hasOpenPlan: Bool { planDraft != nil && planStatus == .pending }
        var hasOpenPendingEvents: Bool { pendingEvents != nil && pendingEventsStatus == .pending }
    }

    /// The "Settings updated" card's Undo button.
    enum ReceiptUndoState: Equatable {
        case available
        case undone
        /// `PreferencesStore.undo` restored nothing: every key changed again since.
        case changedSince
    }

    /// Where an "Ask me first" card stands. Only `.pending` offers Add and Edit.
    enum PendingEventsStatus: Equatable {
        case pending
        case adding
        case added(demo: Bool)
        case discarded
        /// A newer batch took its place.
        case replaced

        var isOpen: Bool { self == .pending || self == .adding }
    }

    /// Drives the AI consent sheet; a fresh id each time it is asked.
    struct ConsentRequest: Identifiable, Equatable {
        let id = UUID()
    }

    /// Chips under "What would you like to change?" after Keep editing.
    static let keepEditingSuggestions = [
        String(localized: "Change the training days"),
        String(localized: "Change the time"),
        String(localized: "Make sessions shorter"),
        String(localized: "Start on a different date")
    ]

    nonisolated static var greeting: Message {
        Message(role: .assistant, text: String(localized: "Type your schedule, aim, or plan with a date and time."))
    }

    /// The conversation, oldest first. Every change is saved to the chat history (shortly after, see `scheduleSave`).
    var messages: [Message] {
        get { storedMessages }
        set {
            storedMessages = newValue
            scheduleSave()
        }
    }
    private var storedMessages: [Message] = [ChatViewModel.greeting]
    var draft = ""
    var isSending = false
    /// A reviewed plan or a batch of pending events is being written to the calendar.
    private(set) var isAddingPlan = false
    /// Bumped when the input field should take focus (after Keep editing). Views focus their field on change.
    private(set) var inputFocusRequest = 0
    /// Bumped when the open plan card should scroll into view (a ghost occurrence was tapped).
    private(set) var planRevealRequest = 0
    /// Set while the AI consent sheet should show (first send without consent, or "Review" on the banner).
    var consentRequest: ConsentRequest?
    /// What the user sent while consent was missing: run once they tap Allow, without a second bubble.
    private(set) var pendingConsentUtterance: String?
    private(set) var isConsentGranted = AIConsentStore.current.isGranted

    var isBusy: Bool { isSending || isAddingPlan }

    @ObservationIgnored private let schedule: ScheduleViewModel
    @ObservationIgnored private var assistant: any ScheduleAssisting
    /// Set once the saved conversation is back. Only then is it saved again: previews never load history, so they
    /// never write it either.
    @ObservationIgnored private var hasLoadedHistory = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var consentObservation: SharedChangeObservation?

    /// `assistant` nil = the mode's default: `DemoAssistant` in demo mode, otherwise `ScheduleAssistant.shared`.
    init(schedule: ScheduleViewModel, assistant: (any ScheduleAssisting)? = nil) {
        self.schedule = schedule
        if let assistant {
            self.assistant = assistant
        } else if AppConstants.isDemoMode {
            self.assistant = DemoAssistant()
        } else {
            self.assistant = ScheduleAssistant.shared
        }
    }

    /// Inputs the demo understands, offered as chips when it starts. They are sample input rather than UI text, so
    /// they are picked by language here instead of translated: a translation could stop `DemoAssistant` parsing them.
    static var demoSuggestions: [String] {
        ReplyFormatter.isChinese(ReplyFormatter.displayLocale)
            ? ["明天下午 1 點跟 Andrew 吃午餐", "團隊會議延後 30 分鐘", "我想在 6 個月內增肌"]
            : ["Lunch with Andrew tomorrow 1pm", "Push the team sync 30 min", "I want to be muscular in 6 months"]
    }

    // MARK: Launch

    /// Brings back the saved conversation (before `ScheduleViewModel.bootstrap`, so a draft found in the App Group
    /// is matched against cards that are already there) and starts following consent changes.
    func loadHistory() async {
        consentObservation = SharedChangeNotifier.observe(.consent) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshConsent() }
        }
        refreshConsent()
        let retention = PreferencesStore.shared.current().chatRetention
        let records = await ChatHistoryStore.shared.load(retention: retention)
        if !records.isEmpty {
            messages = records.map(Message.init(record:))
        }
        hasLoadedHistory = true
    }

    /// Learned suggestions not offered yet become cards ("Stop it" / "Keep"). On launch and whenever the app
    /// becomes active; each is offered in the chat once.
    func appendLearnedSuggestions() async {
        // Before the history is back, a card appended now would be replaced by it.
        guard hasLoadedHistory else { return }
        let store = PreferencesStore.shared
        let shown = Set(messages.compactMap { $0.learnedSuggestion?.id })
        // Launch and becoming active can ask at the same moment: each card once.
        let suggestions = await store.suggestionsToShowInChat().filter { !shown.contains($0.id) }
        guard !suggestions.isEmpty else { return }
        for suggestion in suggestions where !messages.contains(where: { $0.learnedSuggestion?.id == suggestion.id }) {
            messages.append(Message(role: .assistant, text: "", learnedSuggestion: suggestion))
        }
        await store.markShownInChat(suggestions.map(\.id))
    }

    func refreshConsent() {
        isConsentGranted = AIConsentStore.current.isGranted
    }

    // MARK: Demo

    /// Switches to the offline assistant ("Try without signing in", Settings › Demo mode).
    func enableDemo() {
        assistant = DemoAssistant()
        messages.append(Message(role: .assistant,
                                text: String(localized: "Demo mode: sample data. Nothing leaves this device. Try one of these:"),
                                suggestions: Self.demoSuggestions))
    }

    func disableDemo() {
        assistant = ScheduleAssistant.shared
    }

    // MARK: Conversation

    /// The newest message when it is a reply. Only its suggestions are on offer: once the user has written
    /// again, older chips answer a question the conversation has moved past.
    var latestReply: Message? {
        guard let last = messages.last, last.role == .assistant else { return nil }
        return last
    }

    /// What the conversation views follow: they scroll to a new message only while the reader is at the bottom.
    var conversationTail: ConversationTail {
        ConversationTail(lastID: messages.last?.id, isOwnMessage: messages.last?.role == .user, isTyping: isSending)
    }

    /// The card a tapped ghost occurrence should bring into view: the open plan, else open pending events.
    var openPlanMessageID: Message.ID? {
        messages.last { $0.hasOpenPlan }?.id ?? messages.last { $0.hasOpenPendingEvents }?.id
    }

    /// "The assistant is off until you allow AI data sharing." over the composer: signed in to Google, not in demo
    /// mode, and no consent (not asked yet, declined or revoked).
    var showsConsentBanner: Bool {
        !isConsentGranted && !usesDemoAssistant && !schedule.isDemo && schedule.isSignedIn
    }

    func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        // App Store guideline 5.1.2(i): nothing personal reaches Gemini before the user allows it.
        guard usesDemoAssistant || AIConsentStore.current.isGranted else {
            requestConsent(for: text)
            return
        }
        run(text)
    }

    /// The assistant answers `text`, whose bubble is already in the conversation.
    private func run(_ text: String) {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let reply = try await assistant.handle(text, focusEventID: nil, now: Date())
                await apply(reply)
            } catch GeminiError.consentRequired {
                // Revoked in another process since the check above: ask again for this message.
                requestConsent(for: text)
            } catch {
                messages.append(Message(role: .assistant, text: error.localizedDescription))
            }
        }
    }

    func confirmDeletion(in message: Message) {
        guard let pending = message.pendingDeletion,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].pendingDeletion = nil
        Task {
            do {
                let reply = try await assistant.confirm(pending)
                messages.append(Message(role: .assistant, text: reply.text))
                await afterWrite()
            } catch {
                messages.append(Message(role: .assistant, text: error.localizedDescription))
            }
        }
    }

    // MARK: AI consent

    /// Shows the consent sheet; `utterance` runs as soon as the user taps Allow.
    func requestConsent(for utterance: String? = nil) {
        if let utterance { pendingConsentUtterance = utterance }
        consentRequest = ConsentRequest()
    }

    /// "Review" on the composer banner.
    func reviewConsent() {
        consentRequest = ConsentRequest()
    }

    /// "Allow" on the sheet: records consent, then answers the message that was waiting for it.
    func allowConsent() {
        AIConsentStore.grant()
        isConsentGranted = true
        consentRequest = nil
        resumeAfterConsent()
    }

    /// "Not now": the assistant stays off; the banner explains how to turn it on.
    func declineConsent() {
        AIConsentStore.decline()
        isConsentGranted = false
        consentRequest = nil
        guard pendingConsentUtterance != nil else { return }
        pendingConsentUtterance = nil
        messages.append(Message(role: .assistant,
                                text: String(localized: "OK. The assistant stays off until you allow AI data sharing in Settings › AI & privacy.")))
    }

    func resumeAfterConsent() {
        guard let text = pendingConsentUtterance, !isBusy else { return }
        pendingConsentUtterance = nil
        run(text)
    }

    // MARK: Plan review

    /// "Add": writes the reviewed draft to the calendar.
    func addPlan(_ message: Message) {
        guard !isBusy,
              let current = messages.first(where: { $0.id == message.id }),
              current.hasOpenPlan, let plan = current.planDraft else { return }
        setPlanStatus(.adding, messageID: message.id)
        isAddingPlan = true

        Task {
            defer { isAddingPlan = false }
            do {
                let reply = try await assistant.commitPlan(plan)
                setPlanStatus(.added(demo: usesDemoAssistant), messageID: message.id)
                messages.append(Message(role: .assistant, text: reply.text, suggestions: reply.suggestions))
                if let range = reply.showRange { schedule.focus(range) }
                await afterWrite()
            } catch {
                setPlanStatus(.pending, messageID: message.id)
                messages.append(Message(role: .assistant, text: error.localizedDescription))
            }
        }
    }

    /// "Keep editing": the draft stays open while the assistant asks what to change; the answer goes to the
    /// assistant, which replies with a complete new revision.
    func keepEditing(_ message: Message) {
        guard !isBusy, messages.contains(where: { $0.id == message.id && $0.hasOpenPlan }) else { return }
        messages.append(Message(role: .assistant,
                                text: String(localized: "What would you like to change?"),
                                suggestions: Self.keepEditingSuggestions))
        inputFocusRequest += 1
    }

    func revealOpenPlan() {
        planRevealRequest += 1
    }

    /// Brings the cards in line with the draft in the App Group, which Siri or the notification extension may
    /// have created, added or discarded while this conversation wasn't looking. RootView calls this whenever
    /// `ScheduleViewModel.pendingPlan` changes; replies in flight carry their own outcome, so it waits for them.
    func syncPendingPlan(_ pending: PlanDraft?) {
        guard !isBusy else { return }
        if let pending {
            let shown = messages.contains { $0.planDraft?.id == pending.id && $0.planDraft?.revision == pending.revision }
            guard !shown else { return }
            retirePlanCards(before: pending)
            messages.append(Message(role: .assistant,
                                    text: String(localized: "This plan is waiting for your review."),
                                    planDraft: pending))
        } else {
            for index in messages.indices where messages[index].hasOpenPlan {
                guard let planID = messages[index].planDraft?.id else { continue }
                let added = schedule.events.contains { $0.planID == planID }
                messages[index].planStatus = added ? .added(demo: usesDemoAssistant) : .discarded
            }
        }
    }

    // MARK: "Ask me first" pending events

    /// "Add" on a pending events card: writes the batch to its calendar.
    func addPendingEvents(_ message: Message) {
        guard !isBusy,
              let current = messages.first(where: { $0.id == message.id }),
              current.hasOpenPendingEvents, let batch = current.pendingEvents else { return }
        setPendingEventsStatus(.adding, messageID: message.id)
        isAddingPlan = true

        Task {
            defer { isAddingPlan = false }
            do {
                let reply = try await assistant.commitPendingEvents(batch)
                setPendingEventsStatus(.added(demo: usesDemoAssistant), messageID: message.id)
                // The card now reads "Added to Google Calendar" and lists the events: only extra lines are shown.
                let text = Self.shownText(of: reply, clock: schedule.clock)
                if !text.isEmpty || !reply.suggestions.isEmpty {
                    messages.append(Message(role: .assistant, text: text, suggestions: reply.suggestions))
                }
                if let range = reply.showRange { schedule.focus(range) }
                await afterWrite()
            } catch {
                setPendingEventsStatus(.pending, messageID: message.id)
                messages.append(Message(role: .assistant, text: error.localizedDescription))
            }
        }
    }

    /// "Edit": like Keep editing, the batch waits while the user says what to change; the assistant answers with
    /// a new batch that replaces it.
    func editPendingEvents(_ message: Message) {
        guard !isBusy, messages.contains(where: { $0.id == message.id && $0.hasOpenPendingEvents }) else { return }
        messages.append(Message(role: .assistant, text: String(localized: "What would you like to change?")))
        inputFocusRequest += 1
    }

    /// Like `syncPendingPlan`, for the "Ask me first" slot: a batch made through Siri or a notification gets a card;
    /// a batch added or discarded elsewhere settles its card.
    func syncPendingEvents(_ pending: PendingEventBatch?) {
        guard !isBusy else { return }
        if let pending {
            guard !messages.contains(where: { $0.pendingEvents?.id == pending.id }) else { return }
            retirePendingEventCards()
            messages.append(Message(role: .assistant, text: "", pendingEvents: pending))
        } else {
            for index in messages.indices where messages[index].hasOpenPendingEvents {
                guard let batch = messages[index].pendingEvents else { continue }
                // Added events get Google ids of their own; title and start tell them apart from a discarded batch.
                let added = batch.previewEvents.contains { preview in
                    schedule.events.contains { $0.title == preview.title && $0.start == preview.start }
                }
                messages[index].pendingEventsStatus = added ? .added(demo: usesDemoAssistant) : .discarded
            }
        }
    }

    // MARK: Settings updated, learned suggestions

    /// "Undo" on a "Settings updated" card.
    func undoPreferences(_ message: Message) {
        guard let receipt = message.preferenceReceipt, message.receiptUndo == .available else { return }
        Task {
            let restored = await PreferencesStore.shared.undo(receipt)
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[index].receiptUndo = restored ? .undone : .changedSince
        }
    }

    /// "Stop it" / "Keep" on a learned suggestion card. Nothing changes until this tap.
    func resolveSuggestion(_ message: Message, accept: Bool) {
        guard let suggestion = message.learnedSuggestion, suggestion.status == .pending else { return }
        setSuggestionStatus(accept ? .accepted : .declined, messageID: message.id)
        Task {
            await PreferencesStore.shared.resolveSuggestion(id: suggestion.id, accept: accept)
        }
    }

    // MARK: Resetting

    /// Settings › Data › "Clear chat history" (the file is cleared by the caller): back to the greeting, and the
    /// assistant forgets the conversation too.
    func resetConversation() {
        saveTask?.cancel()
        storedMessages = [Self.greeting] // not saved until the next message
        draft = ""
        pendingConsentUtterance = nil
        Task { await ScheduleAssistant.shared.resetConversation() }
    }

    /// After "Erase all data on this device": the signed-out welcome state, with no consent.
    func resetAfterErase() {
        resetConversation()
        assistant = ScheduleAssistant.shared
        consentRequest = nil
        refreshConsent()
    }

    // MARK: Private

    private var usesDemoAssistant: Bool { assistant is DemoAssistant }

    private func apply(_ reply: ScheduleAssistant.Reply) async {
        // Typed approval ("looks good", "加入") or abandonment ("cancel the plan") settles the open card.
        if let planID = reply.committedPlanID { settlePlanCards(planID: planID, as: .added(demo: usesDemoAssistant)) }
        if let planID = reply.discardedPlanID { settlePlanCards(planID: planID, as: .discarded) }
        if let plan = reply.planDraft { retirePlanCards(before: plan) }
        if let batchID = reply.committedEventBatchID {
            settlePendingEventCards(batchID: batchID, as: .added(demo: usesDemoAssistant))
        }
        if let batchID = reply.discardedEventBatchID { settlePendingEventCards(batchID: batchID, as: .discarded) }
        if reply.pendingEvents != nil { retirePendingEventCards() }

        messages.append(Message(role: .assistant, text: Self.shownText(of: reply, clock: schedule.clock),
                                suggestions: reply.suggestions, assumptions: reply.assumptions,
                                pendingDeletion: reply.pendingDeletion, planDraft: reply.planDraft,
                                addedEvents: reply.addedEvents, agenda: reply.agenda,
                                preferenceReceipt: reply.preferenceReceipt,
                                pendingEvents: reply.pendingEvents))

        if let plan = reply.planDraft {
            // Quick Capture opens WEEK on the plan's first week, where its ghost sessions are.
            schedule.focus(reply.showRange ?? firstWeek(of: plan), scope: .week)
        } else if let range = reply.showRange ?? reply.pendingEvents.flatMap({ Self.span(of: $0.previewEvents) }) {
            schedule.focus(range)
        }

        if reply.changed {
            await afterWrite()
        } else if reply.planDraft != nil || reply.committedPlanID != nil || reply.discardedPlanID != nil
                    || reply.pendingEvents != nil || reply.committedEventBatchID != nil
                    || reply.discardedEventBatchID != nil {
            await schedule.reloadPendingPlan()
            await schedule.reloadPendingEvents()
        }
    }

    /// `Reply.text` is the full text version that Siri, notifications and the Live Activity read. In the chat a
    /// plan's summary and review prompt are on its card, confirmations, agendas and pending events are drawn as
    /// rows, and a settings change is a card, so those lines are left out; anything else (a revision's "what
    /// changed", an overlap warning, a setting that could not be changed) stays.
    static func shownText(of reply: ScheduleAssistant.Reply, clock: WallClock) -> String {
        var drawn: [String] = []
        if let plan = reply.planDraft {
            drawn += [plan.summary, ReplyFormatter.planReviewPrompt]
        }
        if !reply.addedEvents.isEmpty {
            drawn += [ReplyFormatter.confirmation(for: reply.addedEvents, clock: clock), DemoAssistant.demoNote]
            // Several create_events calls in one turn each append their own one-event confirmation.
            drawn += reply.addedEvents.map { ReplyFormatter.confirmation(for: [$0], clock: clock) }
        }
        if let agenda = reply.agenda {
            drawn.append(ReplyFormatter.agenda(agenda, clock: clock))
        }
        if let batch = reply.pendingEvents {
            drawn += [ReplyFormatter.pendingEventsSummary(batch, clock: clock), ReplyFormatter.pendingEventsPrompt]
        }
        if reply.committedEventBatchID != nil {
            drawn.append(ReplyFormatter.pendingEventsAdded(reply.addedEvents.count))
        }
        if let receipt = reply.preferenceReceipt {
            drawn.append(ReplyFormatter.preferencesUpdated(receipt))
        }
        guard !drawn.isEmpty else { return reply.text }

        var text = reply.text
        for block in drawn {
            let block = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { text = text.replacingOccurrences(of: block, with: "") }
        }
        // Drop the lines left empty, but keep one blank line where the model wrote a paragraph break.
        var lines: [String] = []
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func setPlanStatus(_ status: PlanCardStatus, messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].planStatus = status
    }

    private func settlePlanCards(planID: String, as status: PlanCardStatus) {
        for index in messages.indices where messages[index].planDraft?.id == planID && messages[index].planStatus.isOpen {
            messages[index].planStatus = status
        }
    }

    /// Older cards stop offering Add once `plan` (a revision, or a different plan) is the one under review.
    private func retirePlanCards(before plan: PlanDraft) {
        for index in messages.indices where messages[index].hasOpenPlan {
            guard let old = messages[index].planDraft else { continue }
            messages[index].planStatus = .replaced(revision: old.id == plan.id ? plan.revision : nil)
        }
    }

    private func setPendingEventsStatus(_ status: PendingEventsStatus, messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].pendingEventsStatus = status
    }

    private func settlePendingEventCards(batchID: String, as status: PendingEventsStatus) {
        for index in messages.indices
        where messages[index].pendingEvents?.id == batchID && messages[index].pendingEventsStatus.isOpen {
            messages[index].pendingEventsStatus = status
        }
    }

    /// A new batch replaces the one waiting (there is a single slot).
    private func retirePendingEventCards() {
        for index in messages.indices where messages[index].hasOpenPendingEvents {
            messages[index].pendingEventsStatus = .replaced
        }
    }

    private func setSuggestionStatus(_ status: LearnedSuggestion.Status, messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].learnedSuggestion?.status = status
    }

    /// From the first start to the last end: where the calendars go to show pending events.
    private static func span(of events: [ScheduleEvent]) -> DateInterval? {
        guard let start = events.map(\.start).min(), let end = events.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: max(start, end))
    }

    private func firstWeek(of plan: PlanDraft) -> DateInterval {
        let calendar = schedule.clock.calendar
        let start = calendar.startOfDay(for: plan.startDate)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    private func afterWrite() async {
        await schedule.reloadFromCache()
        await LiveActivityManager.shared.refreshIfRunning()
    }

    // MARK: History

    /// Saves shortly after the conversation changes (a reply often changes it several times in a row).
    private func scheduleSave() {
        guard hasLoadedHistory else { return }
        saveTask?.cancel()
        let records = messages.map(\.record)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let retention = PreferencesStore.shared.current().chatRetention
            await ChatHistoryStore.shared.save(records, retention: retention)
        }
    }
}

// MARK: - Chat history records

extension ChatViewModel.Message {
    /// What `ChatHistoryStore` keeps. A pending deletion is left out on purpose: a stale Confirm after a relaunch
    /// could delete the wrong thing. A card caught mid-write is saved as still waiting for its tap.
    var record: ChatRecord {
        ChatRecord(id: id,
                   date: date,
                   role: role == .user ? .user : .assistant,
                   text: text,
                   suggestions: suggestions,
                   assumptions: assumptions,
                   planDraft: planDraft,
                   planStatus: planDraft == nil ? nil : Self.recordValue(planStatus),
                   addedEvents: addedEvents,
                   agenda: agenda,
                   preferenceReceipt: preferenceReceipt,
                   preferenceUndone: Self.recordValue(receiptUndo),
                   learnedSuggestion: learnedSuggestion,
                   pendingEvents: pendingEvents,
                   pendingEventsStatus: pendingEvents == nil ? nil : Self.recordValue(pendingEventsStatus))
    }

    init(record: ChatRecord) {
        self.init(id: record.id,
                  date: record.date,
                  role: record.role == .user ? .user : .assistant,
                  text: record.text,
                  suggestions: record.suggestions,
                  assumptions: record.assumptions,
                  planDraft: record.planDraft,
                  planStatus: Self.planStatus(record.planStatus),
                  addedEvents: record.addedEvents,
                  agenda: record.agenda,
                  preferenceReceipt: record.preferenceReceipt,
                  receiptUndo: Self.receiptUndo(record.preferenceUndone),
                  learnedSuggestion: record.learnedSuggestion,
                  pendingEvents: record.pendingEvents,
                  pendingEventsStatus: Self.pendingEventsStatus(record.pendingEventsStatus))
    }

    /// "pending" | "added" | "added_demo" | "replaced" | "replaced:<revision>" | "discarded".
    static func recordValue(_ status: PlanCardStatus) -> String {
        switch status {
        case .pending, .adding: "pending"
        case let .added(demo): demo ? "added_demo" : "added"
        case let .replaced(revision): revision.map { "replaced:\($0)" } ?? "replaced"
        case .discarded: "discarded"
        }
    }

    static func planStatus(_ value: String?) -> PlanCardStatus {
        switch value {
        case "added": return .added(demo: false)
        case "added_demo": return .added(demo: true)
        case "discarded": return .discarded
        case "replaced": return .replaced(revision: nil)
        case let value? where value.hasPrefix("replaced:"):
            return .replaced(revision: Int(value.dropFirst("replaced:".count)))
        default: return .pending
        }
    }

    /// nil = Undo still offered, true = undone, false = changed again since.
    static func recordValue(_ undo: ChatViewModel.ReceiptUndoState) -> Bool? {
        switch undo {
        case .available: nil
        case .undone: true
        case .changedSince: false
        }
    }

    static func receiptUndo(_ value: Bool?) -> ChatViewModel.ReceiptUndoState {
        switch value {
        case nil: .available
        case true?: .undone
        case false?: .changedSince
        }
    }

    /// "pending" | "added" | "added_demo" | "discarded" | "replaced".
    static func recordValue(_ status: ChatViewModel.PendingEventsStatus) -> String {
        switch status {
        case .pending, .adding: "pending"
        case let .added(demo): demo ? "added_demo" : "added"
        case .discarded: "discarded"
        case .replaced: "replaced"
        }
    }

    static func pendingEventsStatus(_ value: String?) -> ChatViewModel.PendingEventsStatus {
        switch value {
        case "added": .added(demo: false)
        case "added_demo": .added(demo: true)
        case "discarded": .discarded
        case "replaced": .replaced
        default: .pending
        }
    }
}
