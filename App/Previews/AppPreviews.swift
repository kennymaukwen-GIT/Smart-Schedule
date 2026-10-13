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
    /// Preview-only: the Artboard 5 conversation, backed by `DemoAssistant` if you send from the canvas.
    static func preview(schedule: ScheduleViewModel) -> ChatViewModel {
        let chat = ChatViewModel(schedule: schedule, assistant: DemoAssistant())
        chat.messages = [
            Message(role: .user, text: "I want to be muscular in 6 month design me a daily routine"),
            Message(role: .assistant,
                    text: "Here is a plan I designed for you: exercise 4 days a week — Mon/Thu upper body, "
                        + "Tue/Fri lower body at 18:30 — in 3 phases (Foundation → Hypertrophy → Strength), "
                        + "with a 07:30 morning nudge and a monthly check-in.",
                    assumptions: ["Workouts at 18:30 after work", "Starts tomorrow"])
        ]
        return chat
    }

    /// Preview-only: the review loop. Revision 1 was replaced after "Make sessions shorter"; revision 2 waits
    /// for Add / Keep editing.
    static func planPreview(schedule: ScheduleViewModel) -> ChatViewModel {
        let chat = ChatViewModel(schedule: schedule, assistant: DemoAssistant())
        let first = PreviewPlans.strength(revision: 1)
        let second = PreviewPlans.strength(revision: 2)
        chat.messages = [
            Message(role: .user, text: "I want to get stronger in 3 months"),
            Message(role: .assistant, text: first.summary + "\n" + PreviewPlans.reviewLine,
                    planDraft: first, planStatus: .replaced(revision: 2)),
            Message(role: .user, text: "Make sessions shorter"),
            Message(role: .assistant, text: second.summary + "\n" + PreviewPlans.reviewLine, planDraft: second)
        ]
        return chat
    }
}

/// Preview-only sample plans: 12 weeks from tomorrow, with ghost occurrences the way the assistant expands them.
enum PreviewPlans {
    static let reviewLine = "Take a look: tap Add to put it in your calendar, or Keep editing to change something."

    /// Revision 2 answers "Make sessions shorter" (45 instead of 60 minutes).
    static func strength(revision: Int = 1, now: Date = Date(), clock: WallClock = WallClock()) -> PlanDraft {
        let calendar = clock.calendar
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start) ?? start }

        let id = "plan-preview"
        let minutes = revision > 1 ? 45 : 60
        let phases = [
            PlanDraft.Phase(name: "Foundation", start: start, end: day(27), focus: "Technique, full range of motion, build the habit"),
            PlanDraft.Phase(name: "Build", start: day(28), end: day(83), focus: "Upper/lower split, add weight every week")
        ]
        let sessions = [
            PlanDraft.Session(phaseIndex: 0, title: "Full body A", weekdays: ["MO", "TH"], startTime: "18:30",
                              durationMinutes: minutes, notes: "Squat, push-up, row"),
            PlanDraft.Session(phaseIndex: 0, title: "Mobility", weekdays: ["SA"], startTime: "09:00",
                              durationMinutes: 30, notes: nil),
            PlanDraft.Session(phaseIndex: 1, title: "Upper body", weekdays: ["MO", "TH"], startTime: "18:30",
                              durationMinutes: minutes, notes: "Push + pull"),
            PlanDraft.Session(phaseIndex: 1, title: "Lower body", weekdays: ["TU", "FR"], startTime: "18:30",
                              durationMinutes: minutes, notes: "Squat or deadlift")
        ]
        let milestones = [
            PlanDraft.Milestone(date: day(27), title: "Form check"),
            PlanDraft.Milestone(date: day(83), title: "Final check-in")
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
            utterance: "I want to get stronger in 3 months",
            goal: "Get stronger in 3 months",
            title: "12-week strength plan",
            startDate: start,
            endDate: day(83),
            summary: revision > 1
                ? "Same plan with 45-minute sessions: full-body basics for four weeks, then an upper/lower split."
                : "Three sessions a week after work: full-body basics for four weeks, then an upper/lower split.",
            phases: phases,
            sessions: sessions,
            milestones: milestones,
            nudge: PlanDraft.Nudge(hour: 7, minute: 30, message: "Training today at 18:30"),
            assumptions: ["Workouts at 18:30 after work", "Starts tomorrow"],
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

/// Design 04 focuses the busy day (Lunch, Meeting With Andrew, Deadline for Plan 5008), two days from today.
@MainActor
private func quickCapturePreview(_ mode: CalendarScope) -> some View {
    let schedule = ScheduleViewModel.preview(focusDay: WallClock().calendar.date(byAdding: .day, value: 2, to: Date()))
    return ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()
        QuickCaptureView(startsWithVoice: false, initialMode: mode, onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel.preview(schedule: schedule))
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
        }
        .padding(12)
    }
    .background(Theme.surface)
    .preferredColorScheme(.dark)
}

#Preview("Plan card · compact") {
    VStack(spacing: 16) {
        PlanPreviewCard(draft: PreviewPlans.strength(), status: .pending, style: .compact)
        PlanPreviewCard(draft: PreviewPlans.strength(), status: .adding, style: .compact)
        PlanPreviewCard(draft: PreviewPlans.strength(), status: .added(demo: true), style: .compact)
    }
    .padding(12)
    .background(Color(white: 0.15))
    .preferredColorScheme(.dark)
}
#endif
