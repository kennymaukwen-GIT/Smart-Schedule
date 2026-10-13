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

    static let collapsedHeight: CGFloat = 230
    static let expandedHeight: CGFloat = 340

    var headerTitle = ""
    var headerBody = ""
    var turns: [Turn] = []
    var draft = ""
    var isWorking = false
    var pendingDeletion: ScheduleAssistant.PendingDeletion?

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
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    func send(_ text: String) {
        turns.append(Turn(role: .user, text: text))
        turns.append(Turn(role: .assistant, text: "…"))
        isWorking = true
        onPreferredHeightChange?(Self.expandedHeight)

        Task {
            let replyText: String
            do {
                let reply = try await assistant.handle(text, focusEventID: focusEventID, now: Date())
                pendingDeletion = reply.pendingDeletion
                replyText = reply.text
            } catch {
                replyText = error.localizedDescription
            }
            if let last = turns.indices.last { turns[last].text = replyText }
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
}
