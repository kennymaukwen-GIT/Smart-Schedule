#if DEBUG
import SwiftUI

// Xcode Canvas previews. Everything runs on in-memory `DemoData` and the offline `DemoAssistant`:
// no network, no keychain, no ActivityKit request.

extension ScheduleViewModel {
    /// Preview-only: demo events in memory; `bootstrap()` is never called, so nothing touches Google.
    static func preview(focusDay: Date? = nil, isDemo: Bool = true) -> ScheduleViewModel {
        let model = ScheduleViewModel()
        model.events = DemoData.events(clock: model.clock)
        model.isDemo = isDemo
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
#endif
