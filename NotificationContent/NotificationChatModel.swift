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

        var hasOpenPlan: Bool { planDraft != nil && planStatus == .pending }
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

    /// `assistant` nil = `DemoAssistant` in demo mode, otherwise a `ScheduleAssistant`.
    init(assistant: (any ScheduleAssisting)? = nil) {
        if let assistant {
            self.assistant = assistant
        } else if AppConstants.isDemoMode {
            self.assistant = DemoAssistant()
        } else {
            self.assistant = ScheduleAssistant() // own instance: the extension is a separate process from the app
        }
    }

    var isDemo: Bool { assistant is DemoAssistant }

    var hasPlan: Bool { turns.contains { $0.planDraft != nil } }

    func load(_ content: UNNotificationContent) {
        headerTitle = content.title
        headerBody = [content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: " · ")
        focusEventID = content.userInfo[NotificationIDs.UserInfo.eventID] as? String

        // A follow-up that presented a draft plan: show its card while that draft is still the pending one.
        // (Plan nudges carry the planID of a plan already in the calendar, so they never match.)
        if let planID = content.userInfo[NotificationIDs.UserInfo.planID] as? String {
            Task {
                if let pending = await SharedStore.shared.pendingPlan(), pending.id == planID {
                    showPending(pending)
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
                apply(reply)
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

    // MARK: Private

    private func apply(_ reply: ScheduleAssistant.Reply) {
        pendingDeletion = reply.pendingDeletion
        suggestions = reply.suggestions
        // Typed approval ("looks good", "加入") or abandonment ("cancel the plan") settles the open card.
        if let planID = reply.committedPlanID { settlePlans(planID: planID, as: .added(demo: isDemo)) }
        if let planID = reply.discardedPlanID { settlePlans(planID: planID, as: .discarded) }
        if let plan = reply.planDraft { prepareForPlan(plan) }

        let turn = Turn(role: .assistant,
                        text: Self.shownText(of: reply, clock: clock),
                        addedEvents: reply.addedEvents,
                        agenda: reply.agenda,
                        planDraft: reply.planDraft)
        if !turn.text.isEmpty || !turn.addedEvents.isEmpty || turn.agenda != nil || turn.planDraft != nil {
            turns.append(turn)
        }
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
    /// added-event rows and agenda show those parts, so their lines are left out; anything else (a revision's
    /// "what changed", an overlap warning) stays. Mirrors `ChatViewModel.shownText` in the app.
    static func shownText(of reply: ScheduleAssistant.Reply, clock: WallClock) -> String {
        var drawn: [String] = []
        if let plan = reply.planDraft {
            drawn += [plan.summary, ReplyFormatter.planReviewPrompt]
        }
        if !reply.addedEvents.isEmpty {
            drawn += [ReplyFormatter.confirmation(for: reply.addedEvents, clock: clock), DemoAssistant.demoNote]
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
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
