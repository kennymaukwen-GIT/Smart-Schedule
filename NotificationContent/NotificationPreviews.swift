#if DEBUG
import SwiftUI

extension NotificationChatModel {
    /// Preview-only: the expanded reminder from Artboard 1 with one exchange; replies go to `DemoAssistant`.
    static func preview() -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Online meeting with Joe"
        model.headerBody = "In 30 min · 15:30 · Google Meet"
        model.turns = [
            Turn(role: .user, text: "Push it 30 min and add a note to bring the Q3 numbers"),
            Turn(role: .assistant, text: "Updated: Online meeting with Joe — 16:00. Reminder moved to 15:30.")
        ]
        return model
    }
}

#Preview("Hold to reply") {
    NotificationChatView(model: NotificationChatModel.preview())
        .frame(height: NotificationChatModel.expandedHeight)
}
#endif
