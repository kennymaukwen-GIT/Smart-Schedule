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

    /// Preview-only: a goal typed into a reminder came back as a draft plan waiting for Add / Keep editing.
    static func planPreview() -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Smart Schedule"
        model.headerBody = "Good morning"
        model.turns = [
            Turn(role: .user, text: "I want to get stronger in 3 months"),
            Turn(role: .assistant, text: "Take a look: tap Add to put it in your calendar, or Keep editing to change something.")
        ]
        model.planDraft = previewPlanDraft()
        return model
    }
}

/// A 12-week, two-phase plan starting tomorrow. Preview events are left out: nothing here draws a calendar.
private func previewPlanDraft() -> PlanDraft {
    let calendar = WallClock().calendar
    let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start) ?? start }
    return PlanDraft(
        id: "plan-preview",
        revision: 1,
        utterance: "I want to get stronger in 3 months",
        goal: "Get stronger in 3 months",
        title: "12-week strength plan",
        startDate: start,
        endDate: day(83),
        summary: "Three sessions a week after work: full-body basics for four weeks, then an upper/lower split.",
        phases: [
            PlanDraft.Phase(name: "Foundation", start: start, end: day(27), focus: "Technique and habit"),
            PlanDraft.Phase(name: "Build", start: day(28), end: day(83), focus: "Add weight every week")
        ],
        sessions: [
            PlanDraft.Session(phaseIndex: 0, title: "Full body A", weekdays: ["MO", "TH"], startTime: "18:30",
                              durationMinutes: 60, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: "Upper body", weekdays: ["MO", "TH"], startTime: "18:30",
                              durationMinutes: 60, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: "Lower body", weekdays: ["TU", "FR"], startTime: "18:30",
                              durationMinutes: 60, notes: nil)
        ],
        milestones: [PlanDraft.Milestone(date: day(83), title: "Final check-in")],
        nudge: PlanDraft.Nudge(hour: 7, minute: 30, message: "Training today at 18:30"),
        assumptions: ["Workouts at 18:30 after work"],
        previewEvents: [],
        writeCount: 4,
        argsJSON: Data()
    )
}

#Preview("Hold to reply") {
    NotificationChatView(model: NotificationChatModel.preview())
        .frame(height: NotificationChatModel.expandedHeight)
}

#Preview("Hold to reply · plan draft") {
    NotificationChatView(model: NotificationChatModel.planPreview())
        .frame(height: NotificationChatModel.planHeight)
}
#endif
