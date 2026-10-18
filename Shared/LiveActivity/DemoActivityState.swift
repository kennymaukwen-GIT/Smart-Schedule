import Foundation

extension ScheduleActivityAttributes.ContentState {
    /// Island / Lock Screen state built from `DemoData` — for Xcode Previews and demo mode. Pure value
    /// construction; no ActivityKit request is made.
    static func demo(now: Date = Date()) -> Self {
        LiveActivityStateBuilder.build(events: DemoData.events(now: now),
                                       lastLine: "Added: Gym · Mon 18:30",
                                       now: now)
    }

    /// The island at its tallest, for Xcode Previews: a school drop-off at 08:15 with its place, then four more items
    /// that morning and evening, so "Up next" shows three rows and "+1". Built as of 07:55 on the next morning still
    /// to come, so the countdown has not run out in the canvas. Pure value construction, like `demo`.
    static func sampleMorning(now: Date = Date(), clock: WallClock = WallClock()) -> Self {
        let calendar = clock.calendar
        var day = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int) -> Date {
            clock.combine(day: day, time: (hour: hour, minute: minute)) ?? day
        }
        if at(7, 55) <= now {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        func item(_ id: String, _ title: String, _ start: Date, minutes: Int, kind: ScheduleEvent.Kind = .event,
                  colorHex: String = DemoData.eventHex, location: String? = nil) -> ScheduleEvent {
            ScheduleEvent(id: DemoData.idPrefix + "sample-" + id, seriesID: nil, title: title, start: start,
                          end: start.addingTimeInterval(TimeInterval(minutes) * 60), isAllDay: false, kind: kind,
                          colorHex: colorHex, location: location, meetURL: nil, notes: nil, reminderMinutes: nil,
                          planID: nil, htmlLink: nil)
        }
        let dropOff = item("school-run", "School drop-off", at(8, 15), minutes: 30, location: "Riverside Primary School")
        let events = [
            dropOff,
            item("standup", "Weekly team sync", at(9, 30), minutes: 30, colorHex: DemoData.schoolHex),
            item("reply", "Reply to Joe", at(11, 0), minutes: 15, kind: .task, colorHex: DemoData.taskHex),
            item("lunch", "Lunch with Andrew", at(12, 30), minutes: 60, location: "Café Lucia"),
            item("gym", "Gym", at(18, 30), minutes: 60, kind: .routine, colorHex: DemoData.gymHex)
        ]
        return LiveActivityStateBuilder.build(for: dropOff, events: events, lastLine: nil, asOf: at(7, 55), clock: clock)
    }
}
