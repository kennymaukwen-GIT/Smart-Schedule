#if DEBUG
import SwiftUI

// Xcode Canvas previews of the drawer's Events section, the events list, the event page and its suggested notes, on
// in-memory demo data: nothing is loaded, saved or sent.

/// Preview-only events: the demo week plus a design review under way (so "Now" has a row), notes with a link on
/// the meeting with Joe, and a holiday in a calendar the sample account can only read. `chinese` gives the
/// titles in Traditional Chinese, as Google would show events typed in Chinese.
@MainActor
enum PreviewEvents {
    static let holidaysCalendar = CalendarRef(accountID: DemoData.personalAccountID, calendarID: "demo-holidays")
    static let reviewID = DemoData.idPrefix + "design-review"
    static let holidayID = DemoData.idPrefix + "chung-yeung"
    static var yogaSeriesID: String { DemoData.idPrefix + "yoga" }

    static func schedule(chinese: Bool = false) -> ScheduleViewModel {
        let schedule = ScheduleViewModel.preview()
        let clock = schedule.clock
        let now = Date()
        let calendar = clock.calendar

        // A read-only calendar on the first sample account.
        if !schedule.accounts.isEmpty {
            schedule.accounts[0].calendars.append(
                CalendarInfo(accountID: holidaysCalendar.accountID, accountEmail: DemoData.personalEmail,
                             calendarID: holidaysCalendar.calendarID, name: chinese ? "香港假期" : "Holidays in Hong Kong",
                             accessRole: "reader", googleColorHex: "#7986CB")
            )
        }

        let reviewStart = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
            .addingTimeInterval(-20 * 60)
        let review = ScheduleEvent(id: reviewID, seriesID: nil, title: chinese ? "設計審查" : "Design review",
                                   start: reviewStart, end: reviewStart.addingTimeInterval(50 * 60), isAllDay: false,
                                   kind: .event, colorHex: DemoData.schoolHex, location: chinese ? "3 樓會議室" : "Room 3",
                                   meetURL: nil, notes: nil, reminderMinutes: [10], planID: nil, htmlLink: nil,
                                   accountID: DemoData.schoolCalendar.accountID, calendarID: DemoData.schoolCalendar.calendarID,
                                   usesCalendarColor: true)
        let holidayDay = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: now)) ?? now
        let holiday = ScheduleEvent(id: holidayID, seriesID: nil, title: chinese ? "重陽節" : "Chung Yeung Festival",
                                    start: holidayDay, end: calendar.date(byAdding: .day, value: 1, to: holidayDay) ?? holidayDay,
                                    isAllDay: true, kind: .event, colorHex: "#7986CB", location: nil, meetURL: nil,
                                    notes: chinese ? "公眾假期，辦公室休息。" : "Public holiday. The office is closed.",
                                    reminderMinutes: nil, planID: nil, htmlLink: nil,
                                    accountID: holidaysCalendar.accountID, calendarID: holidaysCalendar.calendarID,
                                    usesCalendarColor: true)

        schedule.events = (schedule.events + [review, holiday])
            .map { event in
                var event = event
                if event.id == DemoData.meetingID {
                    event.notes = chinese
                        ? "產品品質檢討\n議程：當機率、發佈檢查清單\nhttps://example.com/agenda"
                        : "Product quality review\nAgenda: crash rate, release checklist\nhttps://example.com/agenda"
                }
                if chinese, let title = chineseTitles[event.title] { event.title = title }
                return event
            }
            .sorted { $0.start < $1.start }
        return schedule
    }

    private static let chineseTitles = [
        "Online meeting with Joe": "與 Joe 線上會議",
        "Lunch": "午餐",
        "Meeting With Andrew": "與 Andrew 開會",
        "Deadline for Plan 5008": "企劃 5008 截止",
        "Reply to Joe": "回覆 Joe",
        "Pay bills": "繳帳單",
        "Dentist": "看牙醫",
        "Concert": "音樂會",
        "Team dinner": "團隊晚餐",
        "Trip to San Diego": "聖地牙哥之旅",
        "Gym": "健身",
        "Weekly team sync": "每週團隊會議",
        "Yoga": "瑜伽"
    ]

    static func event(_ id: String, in schedule: ScheduleViewModel) -> ScheduleEvent {
        schedule.events.first { $0.id == id } ?? schedule.events[0]
    }

    /// The next Yoga class: an occurrence of a repeating series.
    static func yoga(in schedule: ScheduleViewModel) -> ScheduleEvent {
        schedule.events.first { $0.seriesID == yogaSeriesID && $0.end > Date() } ?? schedule.events[0]
    }

    static func locale(_ chinese: Bool) -> Locale {
        Locale(identifier: chinese ? "zh-Hant" : "en_US")
    }
}

// MARK: - Suggested notes

/// Preview-only events for suggested notes: a flight to Tokyo the day after tomorrow (travel abroad) next to the
/// demo week's Gym series (workout).
extension PreviewEvents {
    static let tripID = DemoData.idPrefix + "tokyo-flight"
    static var gymSeriesID: String { DemoData.idPrefix + "gym" }

    /// `schedule(chinese:)` plus the flight; `tripNotes` are its notes in the calendar.
    static func notesSchedule(chinese: Bool = false, tripNotes: String? = nil) -> ScheduleViewModel {
        let model = schedule(chinese: chinese)
        var flight = trip(in: model, chinese: chinese)
        flight.notes = tripNotes
        model.events = (model.events + [flight]).sorted { $0.start < $1.start }
        return model
    }

    static func trip(in schedule: ScheduleViewModel, chinese: Bool) -> ScheduleEvent {
        let calendar = schedule.clock.calendar
        let day = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date())) ?? Date()
        let start = schedule.clock.combine(day: day, time: (hour: 8, minute: 50)) ?? day
        return ScheduleEvent(id: tripID, seriesID: nil, title: chinese ? "飛東京" : "Flight to Tokyo",
                             start: start, end: start.addingTimeInterval(3.5 * 3600), isAllDay: false, kind: .event,
                             colorHex: DemoData.personalHex,
                             location: chinese ? "桃園機場第二航廈" : "Taoyuan Airport Terminal 2",
                             meetURL: nil, notes: nil, reminderMinutes: nil, planID: nil, htmlLink: nil,
                             accountID: DemoData.personalCalendar.accountID,
                             calendarID: DemoData.personalCalendar.calendarID, usesCalendarColor: true)
    }

    /// The next Gym session: an occurrence of a repeating series.
    static func gym(in schedule: ScheduleViewModel) -> ScheduleEvent {
        schedule.events.first { $0.seriesID == gymSeriesID && $0.end > Date() } ?? schedule.events[0]
    }

    /// What Gemini's `create_events` might give the flight as `suggested_notes`.
    static func tripSuggestedNotes(chinese: Bool) -> [String] {
        chinese ? ["護照", "日圓現金", "Suica 或 PASMO 交通卡"] : ["Passport", "Yen cash", "Suica or PASMO card"]
    }

    /// What "AI suggestions" might bring for the flight.
    static func tripRequested(chinese: Bool) -> [NoteSuggestion] {
        (chinese ? ["日圓現金", "IC 交通卡", "Visit Japan Web 入境 QR 碼"]
                 : ["Yen cash", "IC transit card", "Visit Japan Web entry QR"])
            .map { NoteSuggestion.ai($0) }
    }
}

@MainActor
private func eventsDrawerPreview(chinese: Bool = false) -> some View {
    let schedule = PreviewEvents.schedule(chinese: chinese)
    return ZStack(alignment: .top) {
        Theme.canvas.ignoresSafeArea()
        Color.black.opacity(0.45).ignoresSafeArea()
        CalendarDrawer(onClose: {})
    }
    .environment(schedule)
    .environment(ChatViewModel(schedule: schedule, assistant: DemoAssistant()))
    .environment(AppRouter())
    .environment(\.locale, PreviewEvents.locale(chinese))
    .preferredColorScheme(.dark)
}

@MainActor
private func eventsListPreview(chinese: Bool = false) -> some View {
    let schedule = PreviewEvents.schedule(chinese: chinese)
    return NavigationStack {
        AllEventsView()
    }
    .frame(maxWidth: 340)
    .environment(schedule)
    .environment(AppRouter())
    .environment(\.locale, PreviewEvents.locale(chinese))
    .preferredColorScheme(.dark)
}

@MainActor
private func eventPagePreview(chinese: Bool = false,
                              _ pick: (ScheduleViewModel) -> ScheduleEvent) -> some View {
    let schedule = PreviewEvents.schedule(chinese: chinese)
    return EventDetailSheet(event: pick(schedule))
        .environment(schedule)
        .environment(AppRouter())
        .environment(\.locale, PreviewEvents.locale(chinese))
}

#Preview("Drawer · events") {
    eventsDrawerPreview()
}

#Preview("Drawer · events · zh-Hant") {
    eventsDrawerPreview(chinese: true)
}

#Preview("All events") {
    eventsListPreview()
}

#Preview("All events · zh-Hant") {
    eventsListPreview(chinese: true)
}

#Preview("Event page · notes") {
    eventPagePreview { PreviewEvents.event(DemoData.meetingID, in: $0) }
}

#Preview("Event page · notes · zh-Hant") {
    eventPagePreview(chinese: true) { PreviewEvents.event(DemoData.meetingID, in: $0) }
}

#Preview("Event page · repeating") {
    eventPagePreview { PreviewEvents.yoga(in: $0) }
}

#Preview("Event page · repeating · zh-Hant") {
    eventPagePreview(chinese: true) { PreviewEvents.yoga(in: $0) }
}

#Preview("Event page · read-only") {
    eventPagePreview { PreviewEvents.event(PreviewEvents.holidayID, in: $0) }
}

#Preview("Event page · read-only · zh-Hant") {
    eventPagePreview(chinese: true) { PreviewEvents.event(PreviewEvents.holidayID, in: $0) }
}

/// The event page with its "Suggested" row; `phase` and `requested` set the "AI suggestions" state.
@MainActor
private func suggestionsPagePreview(chinese: Bool = false,
                                    phase: NoteSuggestionsModel.Phase = .idle,
                                    requested: [NoteSuggestion] = [],
                                    _ pick: (ScheduleViewModel) -> ScheduleEvent) -> some View {
    let schedule = PreviewEvents.notesSchedule(chinese: chinese)
    let event = pick(schedule)
    return NavigationStack {
        EventPage(event: event,
                  noteSuggestions: NoteSuggestionsModel(event: event, phase: phase, requested: requested))
    }
    .preferredColorScheme(.dark)
    .environment(schedule)
    .environment(AppRouter())
    .environment(\.locale, PreviewEvents.locale(chinese))
}

#Preview("Event page · trip suggestions") {
    suggestionsPagePreview { PreviewEvents.trip(in: $0, chinese: false) }
}

#Preview("Event page · trip suggestions · zh-Hant") {
    suggestionsPagePreview(chinese: true) { PreviewEvents.trip(in: $0, chinese: true) }
}

#Preview("Event page · workout suggestions") {
    suggestionsPagePreview { PreviewEvents.gym(in: $0) }
}

#Preview("Event page · workout suggestions · zh-Hant") {
    suggestionsPagePreview(chinese: true) { PreviewEvents.gym(in: $0) }
}

#Preview("Event page · AI suggestions loading") {
    suggestionsPagePreview(phase: .loading) { PreviewEvents.trip(in: $0, chinese: false) }
}

#Preview("Event page · AI suggestions loading · zh-Hant") {
    suggestionsPagePreview(chinese: true, phase: .loading) { PreviewEvents.trip(in: $0, chinese: true) }
}

#Preview("Event page · AI suggestions added") {
    suggestionsPagePreview(phase: .loaded(fromRules: false, added: 3),
                           requested: PreviewEvents.tripRequested(chinese: false)) {
        PreviewEvents.trip(in: $0, chinese: false)
    }
}

#Preview("Event page · AI suggestions added · zh-Hant") {
    suggestionsPagePreview(chinese: true, phase: .loaded(fromRules: false, added: 3),
                           requested: PreviewEvents.tripRequested(chinese: true)) {
        PreviewEvents.trip(in: $0, chinese: true)
    }
}

#Preview("Event page · suggestions from Smart Schedule (demo, offline)") {
    suggestionsPagePreview(phase: .loaded(fromRules: true, added: 0)) { PreviewEvents.gym(in: $0) }
}

/// The chat's added-event card for a flight (Gemini's `suggested_notes`, one of them already added) and a Gym series
/// (Smart Schedule's rules). Nothing is saved from the canvas: a tapped chip ends at "Couldn't add the note.".
@MainActor
private func addedEventChipsPreview(chinese: Bool = false) -> some View {
    let tripNotes = chinese ? "• 日圓現金" : "• Yen cash"
    let schedule = PreviewEvents.notesSchedule(chinese: chinese, tripNotes: tripNotes)
    var trip = PreviewEvents.trip(in: schedule, chinese: chinese)
    trip.suggestedNotes = PreviewEvents.tripSuggestedNotes(chinese: chinese)
    // As the assistant added it: the series itself, whose next occurrence the calendar shows.
    var gym = PreviewEvents.gym(in: schedule)
    gym.id = PreviewEvents.gymSeriesID
    gym.seriesID = nil
    let message = ChatViewModel.Message(role: .assistant, text: "", addedEvents: [trip, gym])
    return ScrollView {
        AssistantMessageView(message: message, isDemo: true)
            .padding(16)
    }
    .background(Theme.surface)
    .environment(schedule)
    .environment(AppRouter())
    .environment(\.locale, PreviewEvents.locale(chinese))
    .preferredColorScheme(.dark)
}

#Preview("Added event · note suggestions") {
    addedEventChipsPreview()
}

#Preview("Added event · note suggestions · zh-Hant") {
    addedEventChipsPreview(chinese: true)
}

#Preview("Added event · Manage") {
    let schedule = PreviewEvents.schedule()
    EventAddedRows(events: [PreviewEvents.event(DemoData.meetingID, in: schedule)], isDemo: true)
        .padding(12)
        .background(Theme.canvas)
        .environment(schedule)
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
#endif
