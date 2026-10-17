import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class NotificationChatModel {
    struct Turn: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        /// What the card shows. For replies this is `shownText(of:)`, not the whole `Reply.text`.
        var text: String
        /// Events the reply put in the calendar, shown as rows instead of a sentence.
        var addedEvents: [ScheduleEvent] = []
        /// The answer to a schedule question, shown as an aligned list.
        var agenda: AgendaDigest?
        /// A long-term plan shown for review; nothing is in the calendar until the user taps Add.
        var planDraft: PlanDraft?
        var planStatus: PlanStatus = .pending
        /// "Ask me first": single events waiting for Add.
        var pendingEvents: PendingEventBatch?
        var pendingEventsStatus: PendingEventsStatus = .pending
        /// The new events went to the default calendar, which this iPhone hides: the card offers Show.
        var hiddenCalendar: HiddenCalendar?

        var hasOpenPlan: Bool { planDraft != nil && planStatus == .pending }
        var hasOpenPendingEvents: Bool { pendingEvents != nil && pendingEventsStatus == .pending }
    }

    /// A calendar hidden in Smart Schedule that just received new events.
    struct HiddenCalendar: Equatable {
        let ref: CalendarRef
        let name: String
    }

    /// The reminder's event as Google has it now, when that differs from the notification.
    enum ReminderChange: Equatable {
        /// "Thu, Oct 16 · 15:00–16:00": the event's new day and time.
        case moved(String)
        case cancelled
    }

    /// Where a pending events card stands. Only `.pending` offers Add and Edit.
    enum PendingEventsStatus: Equatable {
        case pending
        case adding
        case added(demo: Bool)
        case discarded
        /// A newer batch took its place.
        case replaced

        var isOpen: Bool { self == .pending || self == .adding }
    }

    /// Where a plan card stands. Only `.pending` offers Add and Keep editing.
    enum PlanStatus: Equatable {
        case pending
        case adding
        case added(demo: Bool)
        /// A newer revision of the same plan took its place; nil when a different plan did.
        case replaced(revision: Int?)
        case discarded

        var isOpen: Bool { self == .pending || self == .adding }

        var isRetired: Bool {
            switch self {
            case .replaced, .discarded: true
            case .pending, .adding, .added: false
            }
        }
    }

    static let collapsedHeight: CGFloat = 230
    static let expandedHeight: CGFloat = 340
    /// Room for a plan card in the conversation.
    static let planHeight: CGFloat = 480

    /// Chips under "What would you like to change?" after Keep editing.
    static let keepEditingSuggestions = [
        String(localized: "Change the training days"),
        String(localized: "Change the time"),
        String(localized: "Make sessions shorter"),
        String(localized: "Start on a different date")
    ]

    var headerTitle = ""
    var headerBody = ""
    /// Set once Google says the reminder's event moved or was cancelled since the reminder was scheduled.
    var reminderChange: ReminderChange?
    /// The whole conversation in this card, plan cards included, oldest first.
    var turns: [Turn] = []
    var draft = ""
    var isWorking = false
    /// Waiting for the assistant's answer to the user's last line.
    private(set) var isThinking = false
    var pendingDeletion: ScheduleAssistant.PendingDeletion?
    /// The newest reply's suggestions; cleared when the user writes again.
    var suggestions: [String] = []
    /// Bumped when the inline field should take focus (after Keep editing).
    private(set) var inputFocusRequest = 0

    @ObservationIgnored var onPreferredHeightChange: ((CGFloat) -> Void)?
    @ObservationIgnored private var focusEventID: String?
    @ObservationIgnored private let assistant: any ScheduleAssisting
    @ObservationIgnored private let clock = WallClock()

    /// `assistant` nil = `DemoModeAssistant` in demo mode (the AI on the sample data with consent given in the app,
    /// its offline rules otherwise; it never refuses), otherwise a `ScheduleAssistant`.
    init(assistant: (any ScheduleAssisting)? = nil) {
        if let assistant {
            self.assistant = assistant
        } else if AppConstants.isDemoMode {
            self.assistant = DemoModeAssistant()
        } else {
            self.assistant = ScheduleAssistant() // own instance: the extension is a separate process from the app
        }
    }

    var isDemo: Bool { assistant is DemoAssistant || assistant is DemoModeAssistant }

    /// A plan or pending events card is in the conversation: the card needs the taller size.
    var hasPlan: Bool { turns.contains { $0.planDraft != nil || $0.pendingEvents != nil } }

    func load(_ content: UNNotificationContent) {
        headerTitle = content.title
        headerBody = [content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: " · ")
        focusEventID = content.userInfo[NotificationIDs.UserInfo.eventID] as? String

        if content.categoryIdentifier == NotificationIDs.Category.eventReminder, let focusEventID {
            checkReminderEvent(id: focusEventID)
        }

        // A follow-up that presented a draft plan: show its card while that draft is still the pending one.
        // (Plan nudges carry the planID of a plan already in the calendar, so they never match.)
        if let planID = content.userInfo[NotificationIDs.UserInfo.planID] as? String {
            Task {
                if let pending = await SharedStore.shared.pendingPlan(), pending.id == planID {
                    showPending(pending)
                }
            }
        }
        // Likewise "Ask me first" events presented by a follow-up.
        if let batchID = content.userInfo[NotificationIDs.UserInfo.pendingBatchID] as? String {
            Task {
                if let batch = await SharedStore.shared.pendingEventBatch(), batch.id == batchID {
                    showPendingEvents(batch)
                }
            }
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    func send(_ text: String) {
        suggestions = []
        turns.append(Turn(role: .user, text: text))
        isWorking = true
        isThinking = true
        onPreferredHeightChange?(hasPlan ? Self.planHeight : Self.expandedHeight)

        Task {
            do {
                let reply = try await assistant.handle(text, focusEventID: focusEventID, now: Date())
                let hidden = await Self.hiddenCalendar(reply.savedToHiddenCalendar)
                apply(reply, hiddenCalendar: hidden)
            } catch GeminiError.consentRequired {
                // Asking for consent needs the app; nothing was sent.
                turns.append(Turn(role: .assistant,
                                  text: String(localized: "Turn on AI data sharing in Smart Schedules › Settings › AI & privacy to reply here.")))
            } catch {
                turns.append(Turn(role: .assistant, text: error.localizedDescription))
            }
            isThinking = false
            isWorking = false
        }
    }

    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            let text = (try? await assistant.confirm(pending).text)
                ?? String(localized: "Couldn't delete. Try again from the app.")
            turns.append(Turn(role: .assistant, text: text))
        }
    }

    // MARK: Plan review

    /// "Add": writes the reviewed draft to the calendar.
    func addPlan(_ turnID: Turn.ID) {
        guard !isWorking,
              let turn = turns.first(where: { $0.id == turnID }), turn.hasOpenPlan,
              let plan = turn.planDraft else { return }
        setPlanStatus(.adding, turnID: turnID)
        isWorking = true
        Task {
            do {
                let reply = try await assistant.commitPlan(plan)
                setPlanStatus(.added(demo: isDemo), turnID: turnID)
                let hidden = await Self.hiddenCalendar(reply.savedToHiddenCalendar)
                setHiddenCalendar(hidden, turnID: turnID)
                turns.append(Turn(role: .assistant, text: reply.text))
            } catch {
                setPlanStatus(.pending, turnID: turnID)
                turns.append(Turn(role: .assistant, text: error.localizedDescription))
            }
            isWorking = false
        }
    }

    /// "Keep editing": asks what to change right here and focuses the inline field; the answer goes to the
    /// assistant, which replies with a complete new revision.
    func keepEditing(_ turnID: Turn.ID) {
        guard !isWorking, turns.contains(where: { $0.id == turnID && $0.hasOpenPlan }) else { return }
        turns.append(Turn(role: .assistant, text: String(localized: "What would you like to change?")))
        suggestions = Self.keepEditingSuggestions
        inputFocusRequest += 1
    }

    // MARK: "Ask me first" pending events

    /// "Add": writes the batch to its calendar.
    func addPendingEvents(_ turnID: Turn.ID) {
        guard !isWorking,
              let turn = turns.first(where: { $0.id == turnID }), turn.hasOpenPendingEvents,
              let batch = turn.pendingEvents else { return }
        setPendingEventsStatus(.adding, turnID: turnID)
        isWorking = true
        Task {
            do {
                let reply = try await assistant.commitPendingEvents(batch)
                setPendingEventsStatus(.added(demo: isDemo), turnID: turnID)
                let hidden = await Self.hiddenCalendar(reply.savedToHiddenCalendar)
                setHiddenCalendar(hidden, turnID: turnID)
                let text = Self.shownText(of: reply, clock: clock)
                if !text.isEmpty { turns.append(Turn(role: .assistant, text: text)) }
            } catch {
                setPendingEventsStatus(.pending, turnID: turnID)
                turns.append(Turn(role: .assistant, text: error.localizedDescription))
            }
            isWorking = false
        }
    }

    /// "Edit": asks what to change and focuses the inline field; the answer produces a new batch.
    func editPendingEvents(_ turnID: Turn.ID) {
        guard !isWorking, turns.contains(where: { $0.id == turnID && $0.hasOpenPendingEvents }) else { return }
        turns.append(Turn(role: .assistant, text: String(localized: "What would you like to change?")))
        inputFocusRequest += 1
    }

    // MARK: Hidden calendar

    /// "Show": the calendar becomes visible on this iPhone (the app and its reminders follow through `.accounts`).
    func showHiddenCalendar(_ turnID: Turn.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let hidden = turns[index].hiddenCalendar else { return }
        turns[index].hiddenCalendar = nil
        Task { await AccountStore.shared.setVisible(true, calendar: hidden.ref) }
    }

    /// The calendar's name while it is hidden in Smart Schedule; nil when it is visible (or not one of ours).
    private static func hiddenCalendar(_ ref: CalendarRef?) async -> HiddenCalendar? {
        guard let ref, let calendar = await AccountStore.shared.calendar(ref), !calendar.isVisible else { return nil }
        return HiddenCalendar(ref: ref, name: calendar.displayName)
    }

    private func setHiddenCalendar(_ hidden: HiddenCalendar?, turnID: Turn.ID) {
        guard let hidden, let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].hiddenCalendar = hidden
    }

    // MARK: Reminder freshness

    /// The reminder was scheduled from the cache, possibly hours ago: ask Google for the event as it is now
    /// (one `events.get`) and say so when it moved or was cancelled. The card shows at once; this only adds a line.
    /// The app reschedules the reminders on its next sync.
    private func checkReminderEvent(id: String) {
        guard !AppConstants.isDemoMode else { return } // demo events never reach Google
        Task {
            guard let cached = await SharedStore.shared.event(id: id) else { return }
            let fresh = await SyncEngine.shared.freshEvent(cached.ref)
            apply(fresh)
        }
    }

    private func apply(_ fresh: FreshEvent) {
        switch fresh {
        case let .current(event):
            if !event.title.isEmpty { headerTitle = event.title }
        case let .moved(event):
            if !event.title.isEmpty { headerTitle = event.title }
            reminderChange = .moved(ReplyFormatter.when(event, clock: clock))
        case .cancelled:
            reminderChange = .cancelled
        case .unavailable:
            break // offline or not allowed: the notification's own text stands
        }
    }

    // MARK: Private

    private func apply(_ reply: ScheduleAssistant.Reply, hiddenCalendar: HiddenCalendar?) {
        pendingDeletion = reply.pendingDeletion
        suggestions = reply.suggestions
        // Typed approval ("looks good", "加入") or abandonment ("cancel the plan") settles the open card.
        if let planID = reply.committedPlanID { settlePlans(planID: planID, as: .added(demo: isDemo)) }
        if let planID = reply.discardedPlanID { settlePlans(planID: planID, as: .discarded) }
        if let plan = reply.planDraft { prepareForPlan(plan) }
        if let batchID = reply.committedEventBatchID {
            settlePendingEvents(batchID: batchID, as: .added(demo: isDemo))
        }
        if let batchID = reply.discardedEventBatchID { settlePendingEvents(batchID: batchID, as: .discarded) }
        if reply.pendingEvents != nil { prepareForPendingEvents() }

        let turn = Turn(role: .assistant,
                        text: Self.shownText(of: reply, clock: clock),
                        addedEvents: reply.addedEvents,
                        agenda: reply.agenda,
                        planDraft: reply.planDraft,
                        pendingEvents: reply.pendingEvents,
                        hiddenCalendar: hiddenCalendar)
        if !turn.text.isEmpty || !turn.addedEvents.isEmpty || turn.agenda != nil || turn.planDraft != nil
            || turn.pendingEvents != nil {
            turns.append(turn)
        }
    }

    /// A batch that arrived with the notification (made from a collapsed reply or in the app).
    private func showPendingEvents(_ batch: PendingEventBatch) {
        guard !turns.contains(where: { $0.pendingEvents?.id == batch.id }) else { return }
        prepareForPendingEvents()
        turns.append(Turn(role: .assistant, text: "", pendingEvents: batch))
    }

    /// Older cards stop offering Add: there is one batch at a time.
    private func prepareForPendingEvents() {
        for index in turns.indices where turns[index].hasOpenPendingEvents {
            turns[index].pendingEventsStatus = .replaced
        }
        focusEventID = nil // the conversation is about the new events now, not the reminder's event
        onPreferredHeightChange?(Self.planHeight)
    }

    private func settlePendingEvents(batchID: String, as status: PendingEventsStatus) {
        for index in turns.indices
        where turns[index].pendingEvents?.id == batchID && turns[index].pendingEventsStatus.isOpen {
            turns[index].pendingEventsStatus = status
        }
    }

    private func setPendingEventsStatus(_ status: PendingEventsStatus, turnID: Turn.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].pendingEventsStatus = status
    }

    /// A draft that arrived with the notification (made from a collapsed reply or in the app).
    private func showPending(_ plan: PlanDraft) {
        let shown = turns.contains { $0.planDraft?.id == plan.id && $0.planDraft?.revision == plan.revision }
        guard !shown else { return }
        prepareForPlan(plan)
        turns.append(Turn(role: .assistant, text: "", planDraft: plan))
    }

    /// Older cards stop offering Add once `plan` is the one under review.
    private func prepareForPlan(_ plan: PlanDraft) {
        for index in turns.indices where turns[index].hasOpenPlan {
            let old = turns[index].planDraft
            turns[index].planStatus = .replaced(revision: old?.id == plan.id ? plan.revision : nil)
        }
        // From here on the conversation is about the plan: "looks good" or "make it 7am" must not be read as
        // being about the reminder's event (DemoAssistant skips draft review while a focus event is set).
        focusEventID = nil
        onPreferredHeightChange?(Self.planHeight)
    }

    private func settlePlans(planID: String, as status: PlanStatus) {
        for index in turns.indices where turns[index].planDraft?.id == planID && turns[index].planStatus.isOpen {
            turns[index].planStatus = status
        }
    }

    private func setPlanStatus(_ status: PlanStatus, turnID: Turn.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].planStatus = status
    }

    /// `Reply.text` is the full text version (it is also the collapsed notification's body). Here the plan card,
    /// pending events card, added-event rows and agenda show those parts, so their lines are left out; anything else
    /// (a revision's "what changed", an overlap warning, a settings change) stays. Mirrors `ChatViewModel.shownText`
    /// in the app, which also draws settings changes as a card.
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
}
