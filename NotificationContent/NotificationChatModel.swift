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
        var text: String
    }

    /// Where the draft plan card stands. Only the latest draft is shown here, so there is no "replaced" state.
    enum PlanStatus: Equatable {
        case pending
        case adding
        case added(demo: Bool)
        case discarded

        var isOpen: Bool { self == .pending || self == .adding }
    }

    static let collapsedHeight: CGFloat = 230
    static let expandedHeight: CGFloat = 340
    /// Room for the plan card under the conversation.
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
    var turns: [Turn] = []
    var draft = ""
    var isWorking = false
    var pendingDeletion: ScheduleAssistant.PendingDeletion?
    var suggestions: [String] = []
    /// A long-term plan shown for review; nothing is in the calendar until the user taps Add.
    var planDraft: PlanDraft?
    var planStatus: PlanStatus = .pending
    /// Bumped when the inline field should take focus (after Keep editing).
    private(set) var inputFocusRequest = 0

    @ObservationIgnored var onPreferredHeightChange: ((CGFloat) -> Void)?
    @ObservationIgnored private var focusEventID: String?
    @ObservationIgnored private let assistant: any ScheduleAssisting

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

    func load(_ content: UNNotificationContent) {
        headerTitle = content.title
        headerBody = [content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: " · ")
        focusEventID = content.userInfo[NotificationIDs.UserInfo.eventID] as? String

        // A follow-up that presented a draft plan: show its card while that draft is still the pending one.
        // (Plan nudges carry the planID of a plan already in the calendar, so they never match.)
        if let planID = content.userInfo[NotificationIDs.UserInfo.planID] as? String {
            Task {
                if let pending = await SharedStore.shared.pendingPlan(), pending.id == planID {
                    show(pending)
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
        turns.append(Turn(role: .assistant, text: "…"))
        isWorking = true
        onPreferredHeightChange?(planDraft == nil ? Self.expandedHeight : Self.planHeight)

        Task {
            var replyText: String
            do {
                let reply = try await assistant.handle(text, focusEventID: focusEventID, now: Date())
                pendingDeletion = reply.pendingDeletion
                suggestions = reply.suggestions
                replyText = reply.text
                // Typed approval ("looks good", "加入") or abandonment ("cancel the plan").
                if let planID = reply.committedPlanID, planDraft?.id == planID { planStatus = .added(demo: isDemo) }
                if let planID = reply.discardedPlanID, planDraft?.id == planID { planStatus = .discarded }
                if let plan = reply.planDraft {
                    show(plan)
                    // The card carries the summary; the turn keeps the rest ("tap Add or Keep editing").
                    replyText = Self.leadText(reply.text, summary: plan.summary) ?? ""
                }
            } catch {
                replyText = error.localizedDescription
            }
            if let last = turns.indices.last {
                if replyText.isEmpty { turns.remove(at: last) } else { turns[last].text = replyText }
            }
            isWorking = false
        }
    }

    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            let text = (try? await assistant.confirm(pending).text) ?? "Couldn't delete — try again from the app."
            turns.append(Turn(role: .assistant, text: text))
        }
    }

    // MARK: Plan review

    /// "Add": writes the reviewed draft to the calendar.
    func addPlan() {
        guard let plan = planDraft, planStatus == .pending, !isWorking else { return }
        planStatus = .adding
        isWorking = true
        Task {
            do {
                let reply = try await assistant.commitPlan(plan)
                planStatus = .added(demo: isDemo)
                turns.append(Turn(role: .assistant, text: reply.text))
            } catch {
                planStatus = .pending
                turns.append(Turn(role: .assistant, text: error.localizedDescription))
            }
            isWorking = false
        }
    }

    /// "Keep editing": asks what to change right here and focuses the inline field; the answer goes to the
    /// assistant, which replies with a complete new revision.
    func keepEditing() {
        guard planDraft != nil, planStatus == .pending, !isWorking else { return }
        turns.append(Turn(role: .assistant, text: String(localized: "What would you like to change?")))
        suggestions = Self.keepEditingSuggestions
        inputFocusRequest += 1
    }

    // MARK: Private

    private var isDemo: Bool { assistant is DemoAssistant }

    private func show(_ plan: PlanDraft) {
        planDraft = plan
        planStatus = .pending
        // From here on the conversation is about the plan: "looks good" or "make it 7am" must not be read as
        // being about the reminder's event (DemoAssistant skips draft review while a focus event is set).
        focusEventID = nil
        onPreferredHeightChange?(Self.planHeight)
    }

    /// The reply text without the plan's summary, which the card already shows (nil when nothing is left).
    private static func leadText(_ text: String, summary: String) -> String? {
        var rest = text
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, let range = rest.range(of: summary) {
            rest.removeSubrange(range)
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}
