#if DEBUG
import SwiftUI

// Xcode Canvas previews. Everything runs on in-memory `DemoData` and the offline `DemoAssistant`:
// no network, no keychain, no ActivityKit request.

extension ScheduleViewModel {
    /// Preview-only: demo events in memory; `bootstrap()` is never called, so nothing touches Google.
    /// `pendingPlan` draws that draft's occurrences as ghosts.
    static func preview(focusDay: Date? = nil, isDemo: Bool = true, pendingPlan: PlanDraft? = nil) -> ScheduleViewModel {
        let model = ScheduleViewModel()
        model.events = DemoData.events(clock: model.clock)
        model.isDemo = isDemo
        model.pendingPlan = pendingPlan
        if let focusDay { model.focusDay = focusDay }
        return model
    }
}

extension ChatViewModel {
    /// Preview-only: a long Artboard 5 conversation (scroll up to read it all): two added events, an agenda and a
    /// formatted answer with suggestions. Backed by `DemoAssistant` if you send from the canvas.
    static func preview(schedule: ScheduleViewModel, chinese: Bool = false) -> ChatViewModel {
        let chat = ChatViewModel(schedule: schedule, assistant: DemoAssistant())
        let samples = PreviewChat(schedule: schedule, chinese: chinese)
        chat.messages = [
            Message(role: .assistant, text: samples.text("Type your schedule, aim, or plan with a date and time.",
                                                         "輸入行程、目標或計畫，加上日期和時間。")),
            Message(role: .user, text: samples.text("Lunch with Andrew tomorrow 1pm at Café Lucia",
                                                    "明天下午一點跟 Andrew 在 Café Lucia 吃午餐")),
            Message(role: .assistant, text: "", addedEvents: [samples.lunch]),
            Message(role: .user, text: samples.text("Online meeting with Joe on \(samples.meetingWeekday) at 10",
                                                    "\(samples.meetingWeekday)早上十點跟 Joe 開線上會議")),
            Message(role: .assistant, text: "⚠️ " + samples.text("Overlaps: Online meeting with Joe ↔ Dentist",
                                                                  "時間重疊：跟 Joe 開線上會議 ↔ Dentist"),
                    addedEvents: [samples.meeting]),
            Message(role: .user, text: samples.text("What do I have the day after tomorrow?", "後天有什麼行程？")),
            Message(role: .assistant, text: "", agenda: samples.agenda),
            Message(role: .user, text: samples.text("How should I get ready for the dentist?", "看牙醫前要準備什麼？")),
            Message(role: .assistant,
                    text: samples.text("Your **Dentist** visit is on Friday at 09:30.\n\n"
                                           + "• Brush and floss before you go\n• Bring your insurance card\n"
                                           + "• Arrive 10 minutes early",
                                       "你的**牙醫**預約在週五 09:30。\n\n• 出門前刷牙、用牙線\n• 帶健保卡\n• 提早 10 分鐘到"),
                    suggestions: [samples.text("Remind me the night before", "前一晚提醒我"),
                                  samples.text("Move it to 10:00", "改到 10:00")])
        ]
        return chat
    }

    /// Preview-only: the review loop. Revision 1 was replaced after "Make sessions shorter"; revision 2 waits
    /// for Add / Keep editing. An agenda question comes first, so there is history to scroll back to.
    static func planPreview(schedule: ScheduleViewModel, chinese: Bool = false) -> ChatViewModel {
        let chat = ChatViewModel(schedule: schedule, assistant: DemoAssistant())
        let samples = PreviewChat(schedule: schedule, chinese: chinese)
        let first = PreviewPlans.strength(revision: 1, chinese: chinese)
        let second = PreviewPlans.strength(revision: 2, chinese: chinese)
        chat.messages = [
            Message(role: .user, text: samples.text("What do I have the day after tomorrow?", "後天有什麼行程？")),
            Message(role: .assistant, text: "", agenda: samples.agenda),
            Message(role: .user, text: samples.text("I want to get stronger in 3 months", "我想在 3 個月內變強壯")),
            Message(role: .assistant, text: "", planDraft: first, planStatus: .replaced(revision: 2)),
            Message(role: .assistant, text: String(localized: "What would you like to change?"),
                    suggestions: ChatViewModel.keepEditingSuggestions),
            Message(role: .user, text: samples.text("Make sessions shorter", "縮短時長")),
            Message(role: .assistant, text: samples.text("Sessions are now 45 minutes.", "每次改成 45 分鐘。"),
                    planDraft: second)
        ]
        return chat
    }
}

/// Preview-only replies built from the demo calendar: an added lunch, an added meeting, an agenda.
@MainActor
struct PreviewChat {
    let schedule: ScheduleViewModel
    let chinese: Bool

    func text(_ english: String, _ chineseText: String) -> String {
        chinese ? chineseText : english
    }

    private var calendar: Calendar { schedule.clock.calendar }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private func event(_ id: String, _ title: String, day offset: Int, _ hour: Int, _ minute: Int, minutes: Int,
                       location: String? = nil, meetURL: URL? = nil) -> ScheduleEvent {
        let start = schedule.clock.combine(day: day(offset), time: (hour: hour, minute: minute)) ?? day(offset)
        return ScheduleEvent(id: "preview-\(id)", seriesID: nil, title: title, start: start,
                             end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: false,
                             kind: .event, colorHex: DemoData.eventHex, location: location, meetURL: meetURL,
                             notes: nil, reminderMinutes: nil, planID: nil, htmlLink: nil, isCompleted: false)
    }

    var lunch: ScheduleEvent {
        event("lunch-andrew", text("Lunch with Andrew", "跟 Andrew 吃午餐"), day: 1, 13, 0, minutes: 60,
              location: "Café Lucia")
    }

    /// Lands on the demo Dentist (09:30–10:30, four days from today), so the reply carries an overlap warning.
    var meeting: ScheduleEvent {
        event("meeting-joe", text("Online meeting with Joe", "跟 Joe 開線上會議"), day: 4, 10, 0,
              minutes: 60, meetURL: URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    var meetingWeekday: String {
        day(4).formatted(.dateTime.weekday(.wide).locale(Locale(identifier: chinese ? "zh-Hant" : "en_US")))
    }

    /// The demo calendar's busy day (Lunch, Meeting With Andrew, Deadline for Plan 5008), two days from today.
    var agenda: AgendaDigest {
        let busyDay = day(2)
        let range = DateInterval(start: busyDay, end: day(3))
        let locale = Locale(identifier: chinese ? "zh-Hant" : "en_US")
        return AgendaDigest(range: range,
                            title: ReplyFormatter.agendaTitle(for: range, now: Date(), clock: schedule.clock,
                                                              locale: locale),
                            events: schedule.events(on: busyDay))
    }
}

/// Preview-only sample plans: 12 weeks from tomorrow, with ghost occurrences the way the assistant expands them.
enum PreviewPlans {
    /// Revision 2 answers "Make sessions shorter" (45 instead of 60 minutes). `chinese` writes the model's text
    /// (titles, summary, assumptions) in Traditional Chinese, as Gemini would for a Chinese request.
    static func strength(revision: Int = 1, chinese: Bool = false, now: Date = Date(),
                         clock: WallClock = WallClock()) -> PlanDraft {
        let calendar = clock.calendar
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start) ?? start }
        func text(_ english: String, _ chineseText: String) -> String { chinese ? chineseText : english }

        let id = "plan-preview"
        let minutes = revision > 1 ? 45 : 60
        let phases = [
            PlanDraft.Phase(name: text("Foundation", "基礎期"), start: start, end: day(27),
                            focus: text("Technique, full range of motion, build the habit", "練好動作、養成習慣")),
            PlanDraft.Phase(name: text("Build", "進步期"), start: day(28), end: day(83),
                            focus: text("Upper and lower body on separate days, add weight every week", "上下半身分開練，每週加重"))
        ]
        let sessions = [
            PlanDraft.Session(phaseIndex: 0, title: text("Full body A", "全身訓練 A"), weekdays: ["MO", "TH"],
                              startTime: "18:30", durationMinutes: minutes, notes: text("Squat, push-up, row", "深蹲、伏地挺身、划船")),
            PlanDraft.Session(phaseIndex: 0, title: text("Mobility", "伸展"), weekdays: ["SA"], startTime: "09:00",
                              durationMinutes: 30, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: text("Upper body", "上半身"), weekdays: ["MO", "TH"],
                              startTime: "18:30", durationMinutes: minutes, notes: text("Push and pull", "推和拉")),
            PlanDraft.Session(phaseIndex: 1, title: text("Lower body", "下半身"), weekdays: ["TU", "FR"],
                              startTime: "18:30", durationMinutes: minutes, notes: text("Squat or deadlift", "深蹲或硬舉"))
        ]
        let milestones = [
            PlanDraft.Milestone(date: day(27), title: text("Form check", "動作檢查")),
            PlanDraft.Milestone(date: day(55), title: text("Strength test", "肌力測試")),
            PlanDraft.Milestone(date: day(83), title: text("Final check-in", "最後檢查"))
        ]

        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        var preview: [ScheduleEvent] = []
        for offset in 0...83 {
            let date = day(offset)
            let code = codes[calendar.component(.weekday, from: date) - 1]
            for (index, session) in sessions.enumerated() where session.weekdays.contains(code) {
                let phase = phases[session.phaseIndex]
                guard date >= phase.start, date <= phase.end,
                      let time = clock.timeOfDay(session.startTime),
                      let begin = clock.combine(day: date, time: time) else { continue }
                preview.append(ScheduleEvent(
                    id: PlanDraft.eventIDPrefix + "\(index)-\(clock.dateString(date))",
                    seriesID: nil, title: session.title, start: begin,
                    end: begin.addingTimeInterval(TimeInterval(session.durationMinutes * 60)),
                    isAllDay: false, kind: .routine, colorHex: DemoData.routineHex,
                    location: nil, meetURL: nil, notes: session.notes, reminderMinutes: nil,
                    planID: id, htmlLink: nil, isCompleted: false))
            }
        }
        for (index, milestone) in milestones.enumerated() {
            preview.append(ScheduleEvent(
                id: PlanDraft.eventIDPrefix + "milestone-\(index)",
                seriesID: nil, title: milestone.title, start: milestone.date,
                end: calendar.date(byAdding: .day, value: 1, to: milestone.date) ?? milestone.date,
                isAllDay: true, kind: .deadline, colorHex: DemoData.deadlineHex,
                location: nil, meetURL: nil, notes: nil, reminderMinutes: nil,
                planID: id, htmlLink: nil, isCompleted: false))
        }

        return PlanDraft(
            id: id,
            revision: revision,
            utterance: text("I want to get stronger in 3 months", "我想在 3 個月內變強壯"),
            goal: text("Get stronger in 3 months", "3 個月內變強壯"),
            title: text("12-week strength plan", "12 週肌力計畫"),
            startDate: start,
            endDate: day(83),
            summary: revision > 1
                ? text("The same 12-week plan with shorter sessions: 3 to 4 workouts a week, 45 minutes each.",
                       "同一份 12 週計畫，每次縮短：每週練 3 到 4 次，每次 45 分鐘。")
                : text("A 12-week strength plan: 3 to 4 workouts a week, about an hour each.",
                       "12 週肌力計畫：每週練 3 到 4 次，每次約 1 小時。"),
            phases: phases,
            sessions: sessions,
            milestones: milestones,
            nudge: PlanDraft.Nudge(hour: 7, minute: 30, message: text("Training today at 18:30", "今天 18:30 訓練")),
            assumptions: [text("Workouts at 18:30 after work", "下班後 18:30 訓練"), text("Starts tomorrow", "明天開始")],
            previewEvents: preview,
            writeCount: sessions.count + milestones.count,
            argsJSON: Data()
        )
    }
}

#Preview("Main") {
    let schedule = ScheduleViewModel.preview()
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Quick Capture · Day") {
    quickCapturePreview(.day)
}

#Preview("Quick Capture · Week") {
    quickCapturePreview(.week)
}

#Preview("Quick Capture · Month") {
    quickCapturePreview(.month)
}

#Preview("Quick Capture · zh-Hant") {
    quickCapturePreview(.week, chinese: true)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

/// Design 04 focuses the busy day (Lunch, Meeting With Andrew, Deadline for Plan 5008), two days from today.
/// The conversation panel holds the whole history: scroll it up.
@MainActor
private func quickCapturePreview(_ mode: CalendarScope, chinese: Bool = false) -> some View {
    let schedule = ScheduleViewModel.preview(focusDay: WallClock().calendar.date(byAdding: .day, value: 2, to: Date()))
    return ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        QuickCaptureView(startsWithVoice: false, initialMode: mode, onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel.preview(schedule: schedule, chinese: chinese))
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Chat panel · demo") {
    let schedule = ScheduleViewModel.preview()
    ChatPanel()
        .frame(height: 380)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
        .preferredColorScheme(.dark)
}

#Preview("Chat panel · zh-Hant") {
    let schedule = ScheduleViewModel.preview()
    ChatPanel()
        .frame(height: 380)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: true))
        .environment(\.locale, Locale(identifier: "zh-Hant"))
        .preferredColorScheme(.dark)
}

#Preview("Chat panel · signed out") {
    let schedule = ScheduleViewModel.preview(isDemo: false)
    ChatPanel()
        .frame(height: 380)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(ChatViewModel(schedule: schedule, assistant: DemoAssistant()))
        .preferredColorScheme(.dark)
}

#Preview("Event detail") {
    let events = DemoData.events()
    EventDetailSheet(event: events.first(where: { $0.id == DemoData.meetingID }) ?? events[0])
}

#Preview("Month grid") {
    let schedule = ScheduleViewModel.preview()
    MonthGridView(
        month: schedule.displayedMonth,
        today: Date(),
        eventsOnDay: schedule.events(on:),
        onSelect: { _ in }
    )
    .frame(height: 440)
    .padding(12)
    .background(Theme.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Main · plan draft") {
    let schedule = ScheduleViewModel.preview(pendingPlan: PreviewPlans.strength(revision: 2))
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.planPreview(schedule: schedule))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Quick Capture · plan draft") {
    let plan = PreviewPlans.strength(revision: 2)
    let schedule = ScheduleViewModel.preview(focusDay: plan.startDate, pendingPlan: plan)
    ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        QuickCaptureView(startsWithVoice: false, initialMode: .week, onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel.planPreview(schedule: schedule))
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Chat panel · plan draft") {
    let schedule = ScheduleViewModel.preview(pendingPlan: PreviewPlans.strength(revision: 2))
    ChatPanel()
        .frame(height: 560)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(ChatViewModel.planPreview(schedule: schedule))
        .preferredColorScheme(.dark)
}

#Preview("Plan card · states") {
    ScrollView {
        VStack(spacing: 16) {
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 2), status: .pending)
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 2), status: .added(demo: false))
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 1), status: .replaced(revision: 2))
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 1), status: .discarded)
        }
        .padding(12)
    }
    .background(Theme.surface)
    .preferredColorScheme(.dark)
}

#Preview("Plan card · compact") {
    ScrollView {
        VStack(spacing: 16) {
            PlanPreviewCard(draft: PreviewPlans.strength(), status: .pending, style: .compact)
            PlanPreviewCard(draft: PreviewPlans.strength(), status: .adding, style: .compact)
            PlanPreviewCard(draft: PreviewPlans.strength(), status: .added(demo: true), style: .compact)
        }
        .padding(12)
    }
    .background(Color(white: 0.15))
    .preferredColorScheme(.dark)
}

#Preview("Plan card · zh-Hant") {
    ScrollView {
        VStack(spacing: 16) {
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 2, chinese: true), status: .pending)
            PlanPreviewCard(draft: PreviewPlans.strength(revision: 1, chinese: true), status: .replaced(revision: 2))
        }
        .padding(12)
    }
    .background(Theme.surface)
    .environment(\.locale, Locale(identifier: "zh-Hant"))
    .preferredColorScheme(.dark)
}

/// Each kind of reply on its own: prose with a list and bold, added events, an agenda, an empty agenda.
@MainActor
private func repliesPreview(chinese: Bool) -> some View {
    let schedule = ScheduleViewModel.preview()
    let samples = PreviewChat(schedule: schedule, chinese: chinese)
    let chat = ChatViewModel.preview(schedule: schedule, chinese: chinese)
    let today = schedule.clock.calendar.startOfDay(for: Date())
    let tomorrow = schedule.clock.calendar.date(byAdding: .day, value: 1, to: today) ?? today
    let empty = AgendaDigest(range: DateInterval(start: today, end: tomorrow),
                             title: ReplyFormatter.agendaTitle(for: DateInterval(start: today, end: tomorrow),
                                                               now: Date(), clock: schedule.clock,
                                                               locale: Locale(identifier: chinese ? "zh-Hant" : "en_US")),
                             events: [])
    return ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            if let answer = chat.messages.last {
                AssistantMessageView(message: answer, showsSuggestions: true)
            }
            EventAddedRows(events: [samples.lunch, samples.meeting])
            EventAddedRows(events: [samples.lunch], isDemo: true)
            AgendaList(digest: samples.agenda)
            AgendaList(digest: empty)
        }
        .padding(16)
    }
    .background(Theme.surface)
    .preferredColorScheme(.dark)
}

#Preview("Replies") {
    repliesPreview(chinese: false)
}

#Preview("Replies · zh-Hant") {
    repliesPreview(chinese: true)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}
#endif
