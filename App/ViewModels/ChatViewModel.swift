import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
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

        var hasOpenPlan: Bool { planDraft != nil && planStatus == .pending }
    }

    /// Chips under "What would you like to change?" after Keep editing.
    static let keepEditingSuggestions = [
        String(localized: "Change the training days"),
        String(localized: "Change the time"),
        String(localized: "Make sessions shorter"),
        String(localized: "Start on a different date")
    ]

    var messages: [Message] = [
        Message(role: .assistant, text: String(localized: "Type your schedule, aim, or plan with a date and time."))
    ]
    var draft = ""
    var isSending = false
    /// A reviewed plan is being written to the calendar.
    private(set) var isAddingPlan = false
    /// Bumped when the input field should take focus (after Keep editing). Views focus their field on change.
    private(set) var inputFocusRequest = 0
    /// Bumped when the open plan card should scroll into view (a ghost occurrence was tapped).
    private(set) var planRevealRequest = 0

    var isBusy: Bool { isSending || isAddingPlan }

    @ObservationIgnored private let schedule: ScheduleViewModel
    @ObservationIgnored private var assistant: any ScheduleAssisting

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

    /// Switches to the offline assistant ("Try demo" in the chat panel).
    func enableDemo() {
        assistant = DemoAssistant()
        messages.append(Message(role: .assistant,
                                text: String(localized: "Demo mode: sample data. Nothing leaves this device. Try one of these:"),
                                suggestions: Self.demoSuggestions))
    }

    func disableDemo() {
        assistant = ScheduleAssistant.shared
    }

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

    /// The card a tapped ghost occurrence should bring into view.
    var openPlanMessageID: Message.ID? {
        messages.last { $0.hasOpenPlan }?.id
    }

    func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        isSending = true

        Task {
            defer { isSending = false }
            do {
                let reply = try await assistant.handle(text, focusEventID: nil, now: Date())
                await apply(reply)
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

    // MARK: Private

    private var usesDemoAssistant: Bool { assistant is DemoAssistant }

    private func apply(_ reply: ScheduleAssistant.Reply) async {
        // Typed approval ("looks good", "加入") or abandonment ("cancel the plan") settles the open card.
        if let planID = reply.committedPlanID { settlePlanCards(planID: planID, as: .added(demo: usesDemoAssistant)) }
        if let planID = reply.discardedPlanID { settlePlanCards(planID: planID, as: .discarded) }
        if let plan = reply.planDraft { retirePlanCards(before: plan) }

        messages.append(Message(role: .assistant, text: Self.shownText(of: reply, clock: schedule.clock),
                                suggestions: reply.suggestions, assumptions: reply.assumptions,
                                pendingDeletion: reply.pendingDeletion, planDraft: reply.planDraft,
                                addedEvents: reply.addedEvents, agenda: reply.agenda))

        if let plan = reply.planDraft {
            // Quick Capture opens WEEK on the plan's first week, where its ghost sessions are.
            schedule.focus(reply.showRange ?? firstWeek(of: plan), scope: .week)
        } else if let range = reply.showRange {
            schedule.focus(range)
        }

        if reply.changed {
            await afterWrite()
        } else if reply.planDraft != nil || reply.committedPlanID != nil || reply.discardedPlanID != nil {
            await schedule.reloadPendingPlan()
        }
    }

    /// `Reply.text` is the full text version that Siri, notifications and the Live Activity read. In the chat a
    /// plan's summary and review prompt are on its card, and confirmations and agendas are drawn as rows, so
    /// those lines are left out; anything else (a revision's "what changed", an overlap warning) stays.
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
}
