#if DEBUG
import SwiftUI

// Xcode Canvas previews. Everything runs on in-memory `DemoData` and the offline `DemoAssistant`:
// no network, no keychain, no ActivityKit request.

extension ScheduleViewModel {
    /// Preview-only: demo events in memory; `bootstrap()` is never called, so nothing touches Google.
    /// `pendingPlan` draws that draft's occurrences as ghosts. Previews never load ranges on demand, so
    /// `alsoLoading` adds the weekly demo series of a far-off range in memory, as the app would load it.
    /// `accounts` nil: the sample accounts in demo mode, none otherwise (signed out).
    static func preview(focusDay: Date? = nil,
                        displayedMonth: Date? = nil,
                        alsoLoading range: DateInterval? = nil,
                        isDemo: Bool = true,
                        accounts: [GoogleAccount]? = nil,
                        pendingPlan: PlanDraft? = nil,
                        pendingEvents: PendingEventBatch? = nil) -> ScheduleViewModel {
        let model = ScheduleViewModel()
        model.events = DemoData.events(clock: model.clock)
        if let range {
            let seeded = Set(model.events.map(\.id))
            model.events += DemoData.recurringEvents(in: range, clock: model.clock).filter { !seeded.contains($0.id) }
            model.events.sort { $0.start < $1.start }
        }
        model.isDemo = isDemo
        model.accounts = accounts ?? (isDemo ? DemoData.accounts : [])
        model.isSignedIn = !isDemo && !model.accounts.isEmpty
        model.defaultWriteTarget = model.accounts.first?.primaryCalendar?.id
        model.pendingPlan = pendingPlan
        model.pendingEvents = pendingEvents
        if let focusDay { model.focusDay = focusDay }
        if let displayedMonth { model.displayedMonth = displayedMonth }
        return model
    }
}

/// Preview-only far-off dates: 12 March 2031 (a Wednesday) and January 2027, with six weeks of sample data
/// either side.
enum PreviewDates {
    static var march2031: Date { day(2031, 3, 12) }
    static var january2027: Date { day(2027, 1, 1) }

    static func around(_ date: Date) -> DateInterval {
        let calendar = WallClock().calendar
        let week = CalendarPaging.weekStart(containing: date, calendar: calendar)
        return DateInterval(start: CalendarPaging.week(-6, from: week, calendar: calendar),
                            end: CalendarPaging.week(7, from: week, calendar: calendar))
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        WallClock().calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
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
    static func strength(revision: Int = 1, chinese: Bool = false, summary: String? = nil, now: Date = Date(),
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
            summary: summary ?? (revision > 1
                ? text("The same 12-week plan with shorter sessions: 3 to 4 workouts a week, 45 minutes each.",
                       "同一份 12 週計畫，每次縮短：每週練 3 到 4 次，每次 45 分鐘。")
                : text("A 12-week strength plan: 3 to 4 workouts a week, about an hour each.",
                       "12 週肌力計畫：每週練 3 到 4 次，每次約 1 小時。")),
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

    /// What a model that ignores the 1-2 sentence rule writes.
    static func longSummary(chinese: Bool) -> String {
        chinese
            ? "12 週肌力計畫，先打好基礎再逐步加重。前四週練全身動作，熟悉深蹲、伏地挺身和划船的正確姿勢。之後改成上下半身分開練，每週稍微增加重量。每個月檢查一次進度，必要時調整課表。"
            : "A 12-week strength plan that builds a base before adding load. The first four weeks are full-body "
                + "sessions to learn the squat, push-up and row. After that, upper and lower body alternate and the "
                + "weight goes up a little every week. A monthly check-in looks at progress and adjusts the plan."
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

/// Scrolling up through the history pulls the conversation up too; drag its handle back down for the calendar.
#Preview("Quick Capture · conversation pulled up") {
    quickCapturePreview(.week, conversationExpanded: true)
}

/// Years from today: the year shows next to the range, and the Today pill comes back.
#Preview("Quick Capture · Week 2031") {
    quickCapturePreview(.week, focusDay: PreviewDates.march2031)
}

#Preview("Quick Capture · Month 2031") {
    quickCapturePreview(.month, focusDay: PreviewDates.march2031)
}

#Preview("Quick Capture · Day 2031 · zh-Hant") {
    quickCapturePreview(.day, chinese: true, focusDay: PreviewDates.march2031)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

/// Design 04 focuses the busy day (Lunch, Meeting With Andrew, Deadline for Plan 5008), two days from today,
/// unless `focusDay` picks another (with that range's sample data). The conversation panel holds the whole
/// history: scroll it up.
@MainActor
private func quickCapturePreview(_ mode: CalendarScope,
                                 chinese: Bool = false,
                                 focusDay: Date? = nil,
                                 conversationExpanded: Bool = false) -> some View {
    let busyDay = WallClock().calendar.date(byAdding: .day, value: 2, to: Date())
    let schedule = ScheduleViewModel.preview(focusDay: focusDay ?? busyDay,
                                             alsoLoading: focusDay.map(PreviewDates.around))
    return ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        QuickCaptureView(startsWithVoice: false, initialMode: mode, conversationExpanded: conversationExpanded,
                         onClose: {})
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
        .environment(AppRouter())
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
        .environment(AppRouter())
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
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Event detail") {
    let schedule = ScheduleViewModel.preview()
    EventDetailSheet(event: schedule.events.first(where: { $0.id == DemoData.meetingID }) ?? schedule.events[0])
        .environment(schedule)
}

#Preview("Month grid") {
    MonthGridPreview(schedule: ScheduleViewModel.preview())
        .frame(height: 440)
        .padding(12)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
}

/// January 2027: the chip shows the year ("JAN 2027"), and the Today pill leads back to this month.
#Preview("Main · January 2027") {
    let schedule = ScheduleViewModel.preview(displayedMonth: PreviewDates.january2027,
                                             alsoLoading: PreviewDates.around(PreviewDates.january2027))
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Main · January 2027 · zh-Hant") {
    let schedule = ScheduleViewModel.preview(displayedMonth: PreviewDates.january2027,
                                             alsoLoading: PreviewDates.around(PreviewDates.january2027))
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: true))
        .environment(AppRouter())
        .environment(\.locale, Locale(identifier: "zh-Hant"))
        .preferredColorScheme(.dark)
}

/// The month grid on its own; swipe it sideways.
private struct MonthGridPreview: View {
    let schedule: ScheduleViewModel
    @State private var month: Date

    init(schedule: ScheduleViewModel) {
        self.schedule = schedule
        _month = State(initialValue: schedule.displayedMonth)
    }

    var body: some View {
        MonthGridView(month: $month, today: Date(), eventsOnDay: schedule.events(on:), onSelect: { _ in })
    }
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
        .environment(AppRouter())
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

/// A model that ignored the 1-2 sentence rule: the card shows the first sentence and folds the rest.
#Preview("Plan card · long summary") {
    ScrollView {
        VStack(spacing: 16) {
            PlanPreviewCard(draft: PreviewPlans.strength(summary: PreviewPlans.longSummary(chinese: false)),
                            status: .pending)
            PlanPreviewCard(draft: PreviewPlans.strength(chinese: true, summary: PreviewPlans.longSummary(chinese: true)),
                            status: .pending, style: .compact)
        }
        .padding(12)
    }
    .background(Theme.surface)
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
// MARK: - Accounts, drawer, Settings (Artboard 5)

/// Preview-only accounts with example addresses: a personal account with a few calendars, a school account whose
/// sign-in expired, and one moved over from the single-account version (no calendar-list permission yet).
enum PreviewAccounts {
    static var personal: GoogleAccount {
        let email = "example@gmail.com"
        let id = "preview-personal"
        return GoogleAccount(id: id, email: email, connectedAt: Date(),
                             grantedScopes: [GoogleAccount.calendarListScope], needsReconnect: false,
                             calendars: [
                                 calendar(id, email, email, "Kenny", primary: true, "#039BE5"),
                                 calendar(id, email, "gym", "Gym", primary: false, "#0B8043"),
                                 calendar(id, email, "holidays", "Holidays in Hong Kong", primary: false, "#7986CB",
                                          role: "reader", visible: false)
                             ],
                             calendarsUpdatedAt: Date())
    }

    static var school: GoogleAccount {
        let email = "example@yourmail.com"
        let id = "preview-school"
        return GoogleAccount(id: id, email: email, connectedAt: Date(),
                             grantedScopes: [GoogleAccount.calendarListScope], needsReconnect: true,
                             calendars: [calendar(id, email, email, "Student", primary: true, "#E67C73")],
                             calendarsUpdatedAt: Date())
    }

    static var migrated: GoogleAccount {
        let email = "work@example.com"
        let id = "preview-work"
        return GoogleAccount(id: id, email: email, connectedAt: Date(), grantedScopes: [], needsReconnect: false,
                             calendars: [calendar(id, email, email, email, primary: true, "#039BE5")],
                             calendarsUpdatedAt: nil)
    }

    static var all: [GoogleAccount] { [personal, school, migrated] }

    private static func calendar(_ accountID: String, _ email: String, _ calendarID: String, _ name: String,
                                 primary: Bool, _ hex: String, role: String = "owner",
                                 visible: Bool = true) -> CalendarInfo {
        CalendarInfo(accountID: accountID, accountEmail: email, calendarID: calendarID, name: name, isPrimary: primary,
                     accessRole: role, googleColorHex: hex, timeZone: "Europe/London", isVisible: visible,
                     colorOverrideHex: nil, notificationsEnabled: true)
    }
}

/// Preview-only cards: a settings change made by voice, a learned suggestion and "Ask me first" events.
@MainActor
enum PreviewCards {
    static func receipt(chinese: Bool) -> PreferenceChangeReceipt {
        var after = AppPreferences()
        after.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        after.setReminders([120], for: .routine)
        let before = AppPreferences()
        let changes = [PreferenceKey.quietHours, .routineReminders].map { key in
            PreferenceChange(key: key, oldValue: before.canonicalValue(for: key), newValue: after.canonicalValue(for: key),
                             oldDisplay: before.displayValue(for: key), newDisplay: after.displayValue(for: key),
                             replacedEntry: nil)
        }
        return PreferenceChangeReceipt(id: UUID(), date: Date(),
                                       source: .voice(utterance: chinese ? "以後 8 點前不要提醒我，健身提前 2 小時提醒"
                                                                         : "From now on don't remind me before 8am"),
                                       changes: changes)
    }

    static func suggestion(_ status: LearnedSuggestion.Status = .pending) -> LearnedSuggestion {
        LearnedSuggestion(id: UUID(), kind: .event, offsetMinutes: 1440, isAllDay: false, dismissCount: 5,
                          createdAt: Date(), status: status, shownInChat: true)
    }

    static func batch(schedule: ScheduleViewModel, chinese: Bool) -> PendingEventBatch {
        let samples = PreviewChat(schedule: schedule, chinese: chinese)
        var lunch = samples.lunch
        lunch.id = "draft-ev-preview0-0" // a draft id: drawn as a ghost
        let previews = [lunch]
        return PendingEventBatch(id: "batch-preview0", createdAt: Date(), utterance: "", seed: "preview",
                                 argsJSON: Data("{}".utf8), target: DemoData.defaultCalendar,
                                 targetLabel: "My calendar · example@gmail.com", previewEvents: previews)
    }

    static func chat(schedule: ScheduleViewModel, chinese: Bool) -> ChatViewModel {
        let chat = ChatViewModel(schedule: schedule, assistant: DemoAssistant())
        let samples = PreviewChat(schedule: schedule, chinese: chinese)
        chat.messages = [
            .init(role: .user, text: samples.text("From now on don't remind me before 8am", "以後 8 點前不要提醒我")),
            .init(role: .assistant,
                  text: samples.text("OK. From now on, reminders before 08:00 arrive silently.",
                                     "好的，以後 08:00 前的提醒會靜音送達。"),
                  preferenceReceipt: receipt(chinese: chinese)),
            .init(role: .assistant, text: "", learnedSuggestion: suggestion()),
            .init(role: .user, text: samples.text("Lunch with Andrew tomorrow 1pm at Café Lucia",
                                                  "明天下午一點跟 Andrew 在 Café Lucia 吃午餐")),
            .init(role: .assistant, text: "", pendingEvents: batch(schedule: schedule, chinese: chinese))
        ]
        return chat
    }

    static func ledger(chinese: Bool) -> [LedgerEntry] {
        receipt(chinese: chinese).changes.map { change in
            LedgerEntry(id: UUID(), key: change.key, value: change.newValue, display: change.newDisplay,
                        previousDisplay: change.oldDisplay, source: receipt(chinese: chinese).source, date: Date())
        }
    }

    static func settings(chinese: Bool = false) -> SettingsModel {
        var preferences = AppPreferences()
        preferences.quietHours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        preferences.setReminders([120], for: .routine)
        return SettingsModel(preview: preferences, ledger: ledger(chinese: chinese), suggestions: [suggestion()],
                             consent: AIConsent(status: .granted, version: AIConsent.disclosureVersion, decidedAt: Date()))
    }
}

@MainActor
private func signedInSchedule() -> ScheduleViewModel {
    ScheduleViewModel.preview(isDemo: false, accounts: PreviewAccounts.all)
}

#Preview("Main · signed in") {
    let schedule = signedInSchedule()
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Header · zh-Hant") {
    VStack(spacing: 20) {
        AppHeader(month: PreviewDates.january2027, calendar: WallClock().calendar, avatarInitial: "K")
        AppHeader(month: PreviewDates.march2031, calendar: WallClock().calendar, avatarInitial: nil)
    }
    .padding(12)
    .background(Theme.canvas)
    .environment(\.locale, Locale(identifier: "zh-Hant"))
    .preferredColorScheme(.dark)
}

/// Swipe it towards the left edge or tap the dimmed side to close (in the app).
@MainActor
private func drawerPreview(_ schedule: ScheduleViewModel, chinese: Bool = false) -> some View {
    ZStack(alignment: .top) {
        Theme.canvas.ignoresSafeArea()
        Color.black.opacity(0.45).ignoresSafeArea()
        CalendarDrawer(onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel.preview(schedule: schedule, chinese: chinese))
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Drawer · signed in") {
    drawerPreview(signedInSchedule())
}

#Preview("Drawer · demo · zh-Hant") {
    drawerPreview(ScheduleViewModel.preview(), chinese: true)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

#Preview("Drawer · signed out") {
    drawerPreview(ScheduleViewModel.preview(isDemo: false))
}

#Preview("Calendar details") {
    let schedule = signedInSchedule()
    NavigationStack {
        CalendarDetailsView(ref: PreviewAccounts.personal.calendars[1].id)
    }
    .environment(schedule)
    .preferredColorScheme(.dark)
}

#Preview("Calendar details · read-only · zh-Hant") {
    let schedule = signedInSchedule()
    NavigationStack {
        CalendarDetailsView(ref: PreviewAccounts.personal.calendars[2].id)
    }
    .environment(schedule)
    .environment(\.locale, Locale(identifier: "zh-Hant"))
    .preferredColorScheme(.dark)
}

#Preview("Account sheet") {
    let schedule = signedInSchedule()
    AccountSheet()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
}

#Preview("Account sheet · demo · zh-Hant") {
    let schedule = ScheduleViewModel.preview()
    AccountSheet()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: true))
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

// MARK: - Adding and removing Google accounts

/// Preview-only: what Google's page hands back. Nothing here is stored or sent anywhere.
@MainActor
enum PreviewAddAccount {
    static func signIn(email: String, accountID: String = "preview-signed-in") -> GoogleSignInResult {
        let scopes = GoogleTokenProvider.scopes
        let tokens = GoogleTokens(accessToken: "preview", refreshToken: "preview", expiresAt: Date().addingTimeInterval(3600),
                                  email: email, accountID: accountID, scopes: scopes)
        return GoogleSignInResult(tokens: tokens, accountID: accountID, email: email, grantedScopes: scopes)
    }

    /// example@gmail.com was typed; Google signed in example@yourmail.com.
    static var mismatch: AddAccountView.Mismatch {
        AddAccountView.Mismatch(signedIn: "example@yourmail.com", typed: "example@gmail.com",
                                pending: signIn(email: "example@yourmail.com"))
    }

    static var calendarUnticked: AddAccountView.Problem {
        AddAccountView.Problem(message: GoogleSignInFailure.calendarAccessMissing.localizedDescription, canRetry: true,
                               email: "example@gmail.com")
    }
}

/// The add page as the drawer and the welcome state open it (a sheet with Cancel).
@MainActor
private func addAccountPreview(_ page: AddAccountView, schedule: ScheduleViewModel? = nil,
                               chinese: Bool = false) -> some View {
    let schedule = schedule ?? signedInSchedule()
    return NavigationStack { page }
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: chinese))
        .environment(\.locale, Locale(identifier: chinese ? "zh-Hant" : "en_US"))
        .preferredColorScheme(.dark)
}

#Preview("Add account") {
    addAccountPreview(AddAccountView(showsCancel: true))
}

#Preview("Add account · invalid email") {
    addAccountPreview(AddAccountView(showsCancel: true, email: "example@gmail", showsValidation: true))
}

#Preview("Add account · signed in as another account") {
    addAccountPreview(AddAccountView(showsCancel: true, email: "example@gmail.com", mismatch: PreviewAddAccount.mismatch))
}

#Preview("Add account · calendar permission unticked") {
    addAccountPreview(AddAccountView(showsCancel: true, email: "example@gmail.com",
                                     problem: PreviewAddAccount.calendarUnticked))
}

#Preview("Add account · demo · zh-Hant") {
    addAccountPreview(AddAccountView(showsCancel: true, email: "example@yourmail.com"),
                      schedule: ScheduleViewModel.preview(), chinese: true)
}

#Preview("Remove account · changes not synced") {
    let schedule = signedInSchedule()
    AccountSheet(removal: ScheduleViewModel.AccountRemoval(account: PreviewAccounts.personal, unsentChanges: 2))
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
}

#Preview("Notices") {
    VStack(spacing: 12) {
        NoticeBanner(notice: ScheduleViewModel.Notice(text: "Connected example@gmail.com"))
        NoticeBanner(notice: ScheduleViewModel.Notice(text: "example@gmail.com is already connected."))
        NoticeBanner(notice: ScheduleViewModel.Notice(text: "Removed example@gmail.com",
                                                      detail: "New events now go to “My calendar · example@yourmail.com”."))
        NoticeBanner(notice: ScheduleViewModel.Notice(text: "已移除 example@gmail.com",
                                                      detail: "新行程改存到「我的行事曆 · example@yourmail.com」。"))
    }
    .padding(16)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.canvas)
    .preferredColorScheme(.dark)
}

@MainActor
private func settingsPreview<Page: View>(chinese: Bool = false, @ViewBuilder page: () -> Page) -> some View {
    let schedule = signedInSchedule()
    let content = page()
    return NavigationStack { content }
        .environment(PreviewCards.settings(chinese: chinese))
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: chinese))
        .environment(\.locale, Locale(identifier: chinese ? "zh-Hant" : "en_US"))
        .preferredColorScheme(.dark)
}

#Preview("Settings") {
    let schedule = signedInSchedule()
    SettingsView(model: PreviewCards.settings())
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
}

#Preview("Settings · zh-Hant") {
    let schedule = signedInSchedule()
    SettingsView(model: PreviewCards.settings(chinese: true))
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule, chinese: true))
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

#Preview("Settings · Notifications") {
    settingsPreview { NotificationSettingsView() }
}

#Preview("Settings · Notifications · zh-Hant") {
    settingsPreview(chinese: true) { NotificationSettingsView() }
}

#Preview("Settings · Default reminders") {
    settingsPreview { ReminderListEditor(kind: .event) }
}

#Preview("Settings · Calendar & new events") {
    settingsPreview { CalendarSettingsView() }
}

#Preview("Settings · Assistant · zh-Hant") {
    settingsPreview(chinese: true) { AssistantSettingsView() }
}

#Preview("Settings · AI & privacy") {
    settingsPreview { PrivacySettingsView() }
}

#Preview("Settings · AI & privacy · zh-Hant") {
    settingsPreview(chinese: true) { PrivacySettingsView() }
}

#Preview("Settings · Data") {
    settingsPreview { DataSettingsView() }
}

#Preview("Settings · Shortcuts and Siri · zh-Hant") {
    settingsPreview(chinese: true) { ShortcutsGuideView() }
}

#Preview("AI consent") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            AIConsentSheet(onAllow: {}, onNotNow: {})
        }
}

#Preview("Chat cards") {
    let schedule = signedInSchedule()
    ChatPanel()
        .frame(height: 640)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(PreviewCards.chat(schedule: schedule, chinese: false))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Chat cards · zh-Hant") {
    let schedule = signedInSchedule()
    ChatPanel()
        .frame(height: 640)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(PreviewCards.chat(schedule: schedule, chinese: true))
        .environment(\.locale, Locale(identifier: "zh-Hant"))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Chat cards · settled") {
    let schedule = signedInSchedule()
    ScrollView {
        VStack(spacing: 16) {
            SettingsUpdatedCard(receipt: PreviewCards.receipt(chinese: false), undo: .undone)
            SettingsUpdatedCard(receipt: PreviewCards.receipt(chinese: false), undo: .changedSince)
            LearnedSuggestionCard(suggestion: PreviewCards.suggestion(.accepted))
            LearnedSuggestionCard(suggestion: PreviewCards.suggestion(.declined))
            PendingEventsCard(batch: PreviewCards.batch(schedule: schedule, chinese: false), status: .added(demo: false))
            PendingEventsCard(batch: PreviewCards.batch(schedule: schedule, chinese: false), status: .replaced)
            ConsentBanner(onReview: {})
        }
        .padding(12)
    }
    .background(Theme.surface)
    .preferredColorScheme(.dark)
}

// MARK: - Two-way sync

/// Preview-only sync states. The only place previews build `SyncStatus`, `FailedChange` and pending events.
@MainActor
enum PreviewSync {
    /// Two changes Google refused: an edit in a calendar shared read-only, and a new event it rejected.
    static func failed(chinese: Bool) -> [FailedChange] {
        func text(_ english: String, _ chineseText: String) -> String { chinese ? chineseText : english }
        return [
            FailedChange(id: UUID(), title: text("Team offsite", "團隊外訓"),
                         summary: text("Move to Fri, Oct 16 · 13:00–17:00", "改到 10月16日（週五）13:00–17:00"),
                         failedAt: Date().addingTimeInterval(-600),
                         reason: text("You can't change events in “Holidays in Hong Kong”.",
                                      "你無法修改「Holidays in Hong Kong」裡的行程。")),
            FailedChange(id: UUID(), title: text("Coffee with Mia", "跟 Mia 喝咖啡"),
                         summary: text("New event · Thu, Oct 15 · 09:00–10:00", "新行程 · 10月15日（週四）09:00–10:00"),
                         failedAt: Date().addingTimeInterval(-120),
                         reason: text("Google Calendar rejected the change.", "Google 日曆拒絕了這項變更。"))
        ]
    }

    /// `syncedAgo`: seconds since every account last synced; nil = never.
    static func status(pending: Int = 0, offline: Bool = false, failed: [FailedChange] = [],
                       syncedAgo: TimeInterval? = 300,
                       accounts: [GoogleAccount] = PreviewAccounts.all) -> SyncStatus {
        var status = SyncStatusStore.current
        status.pendingCount = pending
        status.isOffline = offline
        status.failed = failed
        status.lastSuccess = [:]
        if let syncedAgo {
            for account in accounts { status.lastSuccess[account.id] = Date().addingTimeInterval(-syncedAgo) }
        }
        return status
    }

    /// A copy made on this iPhone that Google has not confirmed yet.
    static func waiting(_ event: ScheduleEvent) -> ScheduleEvent {
        var copy = event
        copy.isPendingSync = true
        return copy
    }

    /// Signed in with two changes waiting and two refused; the first few events of the month wait too.
    static func schedule(offline: Bool = false, chinese: Bool = false) -> ScheduleViewModel {
        let schedule = signedInSchedule()
        let refused = offline ? [] : Self.failed(chinese: chinese)
        schedule.syncStatus = status(pending: offline ? 3 : 2, offline: offline, failed: refused)
        schedule.isNetworkOffline = offline
        // From today on: chips on screen in the month grid and Quick Capture.
        let today = schedule.clock.calendar.startOfDay(for: Date())
        var marked = 0
        schedule.events = schedule.events.map { event in
            guard marked < 4, event.start >= today, !event.isAllDay else { return event }
            marked += 1
            return waiting(event)
        }
        return schedule
    }

    /// "Gym" is hidden on this iPhone and just received a new session.
    static func hiddenGymSchedule() -> ScheduleViewModel {
        var personal = PreviewAccounts.personal
        if let index = personal.calendars.firstIndex(where: { $0.calendarID == "gym" }) {
            personal.calendars[index].isVisible = false
        }
        return ScheduleViewModel.preview(isDemo: false, accounts: [personal, PreviewAccounts.school])
    }

    static var gymRef: CalendarRef { CalendarRef(accountID: PreviewAccounts.personal.id, calendarID: "gym") }
}

#Preview("Drawer · waiting and failed changes") {
    drawerPreview(PreviewSync.schedule())
}

#Preview("Drawer · offline · zh-Hant") {
    drawerPreview(PreviewSync.schedule(offline: true, chinese: true), chinese: true)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}

#Preview("Sync status lines") {
    let summaries: [SyncSummary] = [
        .synced(Date()), .synced(Date().addingTimeInterval(-5 * 60)), .synced(Date().addingTimeInterval(-3 * 3600)),
        .synced(Date().addingTimeInterval(-2 * 86_400)), .waiting(pending: 1), .waiting(pending: 4), .syncing,
        .offline(pending: 0), .offline(pending: 3), .unreachable, .demo, .notSynced
    ]
    List {
        ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
            SyncStatusLine(summary: summary)
        }
        FailedChangeRow(change: PreviewSync.failed(chinese: false)[0])
        FailedChangeRow(change: PreviewSync.failed(chinese: false)[1], isRetrying: true)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.surface)
    .preferredColorScheme(.dark)
}

#Preview("Header · sync indicators · offline") {
    let schedule = PreviewSync.schedule(offline: true)
    VStack(spacing: 20) {
        // Offline with three changes waiting (what the main screen shows below).
        AppHeader(month: Date(), calendar: WallClock().calendar, avatarInitial: "K",
                  syncIndicator: .pending(count: 3, offline: true))
        AppHeader(month: Date(), calendar: WallClock().calendar, avatarInitial: "K",
                  syncIndicator: .pending(count: 2, offline: false))
        AppHeader(month: Date(), calendar: WallClock().calendar, avatarInitial: "K",
                  syncIndicator: .failing(count: 1))
        AppHeader(month: Date(), calendar: WallClock().calendar, avatarInitial: "K")
        MonthGridView(month: .constant(Date()), today: Date(), showsTitle: false,
                      eventsOnDay: schedule.events(on:), onSelect: { _ in })
            .frame(height: 420)
    }
    .padding(12)
    .background(Theme.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Main · waiting to sync") {
    let schedule = PreviewSync.schedule()
    MainView()
        .environment(schedule)
        .environment(ChatViewModel.preview(schedule: schedule))
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Quick Capture · Week · waiting to sync") {
    let schedule = PreviewSync.schedule()
    ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        QuickCaptureView(startsWithVoice: false, initialMode: .week, onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel.preview(schedule: schedule))
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

/// A new session went to "Gym", which this iPhone hides: the added card offers Show (tap it to see the notice go).
@MainActor
private func hiddenCalendarPreview(chinese: Bool) -> some View {
    let schedule = PreviewSync.hiddenGymSchedule()
    schedule.syncStatus = PreviewSync.status(pending: 1)
    let samples = PreviewChat(schedule: schedule, chinese: chinese)
    var session = samples.lunch
    session.title = samples.text("Gym", "健身")
    session.accountID = PreviewAccounts.personal.id
    session.calendarID = "gym"
    let added = ChatViewModel.Message(role: .assistant, text: "", addedEvents: [session],
                                      savedToHiddenCalendar: PreviewSync.gymRef)
    let offline = ChatViewModel.Message(role: .assistant, text: "", addedEvents: [PreviewSync.waiting(samples.meeting)])
    return ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            AssistantMessageView(message: added)
            AssistantMessageView(message: offline)
            HiddenCalendarNotice(calendarName: samples.text("Gym", "健身"))
        }
        .padding(16)
    }
    .background(Theme.surface)
    .environment(schedule)
    .preferredColorScheme(.dark)
}

#Preview("Saved to a hidden calendar") {
    hiddenCalendarPreview(chinese: false)
}

#Preview("Saved to a hidden calendar · zh-Hant") {
    hiddenCalendarPreview(chinese: true)
        .environment(\.locale, Locale(identifier: "zh-Hant"))
}
#endif
