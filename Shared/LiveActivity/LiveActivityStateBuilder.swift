import Foundation

enum LiveActivityStateBuilder {
    private static let byteBudget = 3_200 // headroom under ActivityKit's 4 KB cap

    static func build(events: [ScheduleEvent],
                      lastLine: String?,
                      now: Date = Date(),
                      clock: WallClock = WallClock()) -> ScheduleActivityAttributes.ContentState {
        let events = events.filter { !$0.isDraft } // previews of plans and "Ask me first" batches are not booked
        let next = events
            .filter { !$0.isAllDay && $0.end > now && !$0.isCompleted }
            .min { $0.start < $1.start }
        return make(next: next, events: events, lastLine: lastLine, now: now, clock: clock)
    }

    /// The state of `event`'s own activity as it looks at `asOf`: when a scheduled activity appears (iOS 26) or a
    /// push starts it (iOS 18), so the week strip's "today" and the countdown are right then, not when it was planned.
    static func build(for event: ScheduleEvent,
                      events: [ScheduleEvent],
                      lastLine: String?,
                      asOf: Date,
                      clock: WallClock = WallClock()) -> ScheduleActivityAttributes.ContentState {
        make(next: event, events: events.filter { !$0.isDraft }, lastLine: lastLine, now: asOf, clock: clock)
    }

    private static func make(next: ScheduleEvent?,
                             events: [ScheduleEvent],
                             lastLine: String?,
                             now: Date,
                             clock: WallClock) -> ScheduleActivityAttributes.ContentState {
        let calendar = clock.calendar
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let todayIndex = calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: now)).day ?? 0

        var state = ScheduleActivityAttributes.ContentState(
            headline: next?.title ?? String(localized: "Nothing next — type a plan"),
            shortHeadline: String((next?.title ?? "Smart Schedules").prefix(16)),
            eventID: next?.id,
            countdownFrom: now,
            countdownTarget: next.map { $0.start > now ? $0.start : $0.end },
            isInProgress: next.map { $0.start <= now } ?? false,
            weekStart: weekStart,
            todayIndex: min(max(todayIndex, 0), 6),
            days: [],
            lastAssistantLine: lastLine.map { String($0.prefix(60)) },
            firstWeekday: calendar.firstWeekday,
            eventStart: next?.start ?? now,
            eventEnd: next?.end
        )

        for (chipsPerDay, titleLength) in [(2, 10), (1, 8), (1, 5)] {
            state.days = (0..<7).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: weekStart)!
                let interval = DateInterval(start: day, duration: 86_400)
                let dayEvents = events.filter { $0.intersects(interval) }.sorted { $0.start < $1.start }
                return ScheduleActivityAttributes.DayDigest(
                    dayNumber: calendar.component(.day, from: day),
                    chips: dayEvents.prefix(chipsPerDay).map {
                        ScheduleActivityAttributes.Chip(title: String($0.title.prefix(titleLength)), colorHex: $0.colorHex, isTask: $0.kind == .task)
                    },
                    overflow: max(0, dayEvents.count - chipsPerDay)
                )
            }
            if ((try? JSONEncoder().encode(state))?.count ?? 0) <= byteBudget { break }
        }
        return state
    }

    /// Settings › Dynamic Island "Show next event": true when the next visible timed event is in progress or starts
    /// within `leadMinutes`. nil lead = never.
    static func isNextEventDue(events: [ScheduleEvent], leadMinutes: Int?, now: Date = Date()) -> Bool {
        guard let leadMinutes else { return false }
        let horizon = now.addingTimeInterval(TimeInterval(leadMinutes) * 60)
        return events.contains { event in
            !event.isAllDay && !event.isCompleted && !event.isDraft && event.end > now && event.start <= horizon
        }
    }
}
