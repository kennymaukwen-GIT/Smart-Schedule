#if DEBUG
import SwiftUI

extension NotificationChatModel {
    /// Preview-only: the expanded reminder from Artboard 1 with a few exchanges (scroll up for the first);
    /// replies go to `DemoAssistant`.
    static func preview() -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Online meeting with Joe"
        model.headerBody = "In 30 min · 15:30 · Google Meet"
        let samples = NotificationPreviewSamples()
        model.turns = [
            Turn(role: .user, text: "Push it 30 min and add a note to bring the Q3 numbers"),
            Turn(role: .assistant, text: "Updated: **Online meeting with Joe** · 16:00–17:00\nThe reminder moved to 15:30."),
            Turn(role: .user, text: "What else do I have today?"),
            Turn(role: .assistant, text: "", agenda: samples.agenda(chinese: false)),
            Turn(role: .user, text: "Coffee with Mia tomorrow 9am at Blue Bottle"),
            Turn(role: .assistant, text: "", addedEvents: [samples.coffee(chinese: false)])
        ]
        return model
    }

    /// Preview-only: a goal typed into a reminder came back as a draft plan waiting for Add / Keep editing.
    static func planPreview(chinese: Bool = false) -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Smart Schedule"
        model.headerBody = chinese ? "早安" : "Good morning"
        model.turns = [
            Turn(role: .user, text: chinese ? "我想在 3 個月內變強壯" : "I want to get stronger in 3 months"),
            Turn(role: .assistant, text: "", planDraft: previewPlanDraft(chinese: chinese))
        ]
        return model
    }

    /// Preview-only: "Ask me first" is on, so the coffee waits for Add / Edit.
    static func pendingEventsPreview(chinese: Bool = false) -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Smart Schedule"
        model.headerBody = chinese ? "長按回覆" : "Hold to reply"
        var coffee = NotificationPreviewSamples().coffee(chinese: chinese)
        coffee.id = "draft-ev-preview0-0" // a draft id, as the assistant gives previews
        let batch = PendingEventBatch(id: "batch-preview0", createdAt: Date(), utterance: "", seed: "preview",
                                      argsJSON: Data("{}".utf8), target: nil,
                                      targetLabel: "My calendar · kenny@example.com", previewEvents: [coffee])
        model.turns = [
            Turn(role: .user, text: chinese ? "明天早上 9 點跟 Mia 在 Blue Bottle 喝咖啡" : "Coffee with Mia tomorrow 9am at Blue Bottle"),
            Turn(role: .assistant, text: "", pendingEvents: batch)
        ]
        return model
    }

    /// Preview-only: the reminder was set for 15:30, but the meeting moved in Google Calendar since (or was
    /// cancelled); the card says so under the title.
    static func reminderChangedPreview(chinese: Bool = false, cancelled: Bool = false) -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = chinese ? "跟 Joe 開線上會議" : "Online meeting with Joe"
        model.headerBody = chinese ? "30 分鐘後 · 15:30 · Google Meet" : "In 30 min · 15:30 · Google Meet"
        if cancelled {
            model.reminderChange = .cancelled
        } else {
            let clock = WallClock()
            let tomorrow = clock.calendar.date(byAdding: .day, value: 1, to: clock.calendar.startOfDay(for: Date())) ?? Date()
            let start = clock.combine(day: tomorrow, time: (hour: 16, minute: 0)) ?? tomorrow
            var moved = NotificationPreviewSamples().coffee(chinese: chinese)
            moved.start = start
            moved.end = start.addingTimeInterval(3600)
            let locale = Locale(identifier: chinese ? "zh-Hant" : "en_US")
            model.reminderChange = .moved(ReplyFormatter.when(moved, clock: clock, locale: locale))
        }
        return model
    }

    /// Preview-only: "Ask me first" added the session to "Gym", which this iPhone hides.
    static func hiddenCalendarPreview(chinese: Bool = false) -> NotificationChatModel {
        let model = NotificationChatModel(assistant: DemoAssistant())
        model.headerTitle = "Smart Schedule"
        model.headerBody = chinese ? "長按回覆" : "Hold to reply"
        var session = NotificationPreviewSamples().coffee(chinese: chinese)
        session.title = chinese ? "健身" : "Gym"
        session.location = nil
        let gym = HiddenCalendar(ref: CalendarRef(accountID: "preview-personal", calendarID: "gym"),
                                 name: chinese ? "健身" : "Gym")
        model.turns = [
            Turn(role: .user, text: chinese ? "明天早上 9 點健身" : "Gym tomorrow 9am"),
            Turn(role: .assistant, text: "", addedEvents: [session], hiddenCalendar: gym)
        ]
        return model
    }
}

/// Sample rows for the previews: events around today, nothing read from the App Group.
private struct NotificationPreviewSamples {
    let clock = WallClock()

    func coffee(chinese: Bool) -> ScheduleEvent {
        let calendar = clock.calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let start = clock.combine(day: tomorrow, time: (hour: 9, minute: 0)) ?? tomorrow
        return ScheduleEvent(id: "preview-coffee", seriesID: nil, title: chinese ? "跟 Mia 喝咖啡" : "Coffee with Mia",
                             start: start, end: start.addingTimeInterval(3600), isAllDay: false, kind: .event,
                             colorHex: DemoData.eventHex, location: "Blue Bottle", meetURL: nil, notes: nil,
                             reminderMinutes: nil, planID: nil, htmlLink: nil, isCompleted: false)
    }

    func agenda(chinese: Bool) -> AgendaDigest {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: Date())
        let range = DateInterval(start: today, end: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        func event(_ id: String, _ title: String, _ hour: Int, _ minute: Int, _ minutes: Int) -> ScheduleEvent {
            let start = clock.combine(day: today, time: (hour: hour, minute: minute)) ?? today
            return ScheduleEvent(id: "preview-\(id)", seriesID: nil, title: title, start: start,
                                 end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: false,
                                 kind: .event, colorHex: DemoData.eventHex, location: nil, meetURL: nil, notes: nil,
                                 reminderMinutes: nil, planID: nil, htmlLink: nil, isCompleted: false)
        }
        let locale = Locale(identifier: chinese ? "zh-Hant" : "en_US")
        return AgendaDigest(range: range,
                            title: ReplyFormatter.agendaTitle(for: range, now: Date(), clock: clock, locale: locale),
                            events: [event("lunch", chinese ? "午餐" : "Lunch", 12, 30, 60),
                                     event("joe", chinese ? "跟 Joe 開線上會議" : "Online meeting with Joe", 16, 0, 60),
                                     event("gym", chinese ? "健身" : "Gym", 18, 30, 60)])
    }
}

/// A 12-week, two-phase plan starting tomorrow. Preview events are left out: nothing here draws a calendar.
private func previewPlanDraft(chinese: Bool = false) -> PlanDraft {
    let calendar = WallClock().calendar
    let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start) ?? start }
    func text(_ english: String, _ chineseText: String) -> String { chinese ? chineseText : english }
    return PlanDraft(
        id: "plan-preview",
        revision: 1,
        utterance: text("I want to get stronger in 3 months", "我想在 3 個月內變強壯"),
        goal: text("Get stronger in 3 months", "3 個月內變強壯"),
        title: text("12-week strength plan", "12 週肌力計畫"),
        startDate: start,
        endDate: day(83),
        summary: text("A 12-week strength plan: 2 to 4 workouts a week, about an hour each.",
                      "12 週肌力計畫：每週練 2 到 4 次，每次約 1 小時。"),
        phases: [
            PlanDraft.Phase(name: text("Foundation", "基礎期"), start: start, end: day(27), focus: text("Technique and habit", "動作和習慣")),
            PlanDraft.Phase(name: text("Build", "進步期"), start: day(28), end: day(83), focus: text("Add weight every week", "每週加重"))
        ],
        sessions: [
            PlanDraft.Session(phaseIndex: 0, title: text("Full body A", "全身訓練 A"), weekdays: ["MO", "TH"],
                              startTime: "18:30", durationMinutes: 60, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: text("Upper body", "上半身"), weekdays: ["MO", "TH"],
                              startTime: "18:30", durationMinutes: 60, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: text("Lower body", "下半身"), weekdays: ["TU", "FR"],
                              startTime: "18:30", durationMinutes: 60, notes: nil)
        ],
        milestones: [
            PlanDraft.Milestone(date: day(27), title: text("Form check", "動作檢查")),
            PlanDraft.Milestone(date: day(55), title: text("Strength test", "肌力測試")),
            PlanDraft.Milestone(date: day(83), title: text("Final check-in", "最後檢查"))
        ],
        nudge: PlanDraft.Nudge(hour: 7, minute: 30, message: text("Training today at 18:30", "今天 18:30 訓練")),
        assumptions: [text("Workouts at 18:30 after work", "下班後 18:30 訓練"), text("Starts tomorrow", "明天開始")],
        previewEvents: [],
        writeCount: 6,
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

#Preview("Hold to reply · ask me first") {
    NotificationChatView(model: NotificationChatModel.pendingEventsPreview())
        .frame(height: NotificationChatModel.planHeight)
}

#Preview("Hold to reply · ask me first · zh-Hant") {
    NotificationChatView(model: NotificationChatModel.pendingEventsPreview(chinese: true))
        .frame(height: NotificationChatModel.planHeight)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

#Preview("Hold to reply · reminder moved") {
    NotificationChatView(model: NotificationChatModel.reminderChangedPreview())
        .frame(height: NotificationChatModel.collapsedHeight)
}

#Preview("Hold to reply · reminder cancelled · zh-Hant") {
    NotificationChatView(model: NotificationChatModel.reminderChangedPreview(chinese: true, cancelled: true))
        .frame(height: NotificationChatModel.collapsedHeight)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

#Preview("Hold to reply · saved to a hidden calendar") {
    NotificationChatView(model: NotificationChatModel.hiddenCalendarPreview())
        .frame(height: NotificationChatModel.expandedHeight)
}

#Preview("Hold to reply · zh-Hant") {
    NotificationChatView(model: NotificationChatModel.planPreview(chinese: true))
        .frame(height: NotificationChatModel.planHeight)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}
#endif
