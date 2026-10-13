import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var suggestions: [String] = []
        var assumptions: [String] = []
        var pendingDeletion: ScheduleAssistant.PendingDeletion?
    }

    var messages: [Message] = [
        Message(role: .assistant, text: String(localized: "Type your schedule, aim, or plan with a date and time."))
    ]
    var draft = ""
    var isSending = false

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

    /// Switches to the offline assistant ("Try demo" in the chat panel).
    func enableDemo() {
        assistant = DemoAssistant()
        let hint = String(localized: "Demo mode: sample data, nothing leaves this device. Try “Lunch with Andrew tomorrow 1pm”, “push the team sync 30 min” or “I want to be muscular in 6 months”.")
        messages.append(Message(role: .assistant, text: hint))
    }

    func disableDemo() {
        assistant = ScheduleAssistant.shared
    }

    /// The latest user line + reply, for Quick Capture (Artboard 4 shows only the last exchange).
    var lastExchange: (user: Message?, reply: Message?) {
        let reply = messages.last { $0.role == .assistant }
        let user = messages.last { $0.role == .user }
        return (user, user == nil ? nil : reply)
    }

    func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        isSending = true

        Task {
            defer { isSending = false }
            do {
                let reply = try await assistant.handle(text, focusEventID: nil, now: Date())
                messages.append(Message(role: .assistant, text: reply.text, suggestions: reply.suggestions,
                                        assumptions: reply.assumptions, pendingDeletion: reply.pendingDeletion))
                if let range = reply.showRange { schedule.focus(range) }
                if reply.changed { await afterWrite() }
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

    private func afterWrite() async {
        await schedule.reloadFromCache()
        await LiveActivityManager.shared.refreshIfRunning()
    }
}
