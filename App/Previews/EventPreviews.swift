#if DEBUG
import SwiftUI

// Xcode Canvas previews of the drawer's Events section, the events list and the event page, on in-memory demo
// data: nothing is loaded, saved or sent.

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
