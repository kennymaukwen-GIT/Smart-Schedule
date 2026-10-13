import Foundation

/// Sample schedule mirroring the designer's artboards, laid out around the *current* week so Xcode Previews,
/// the Simulator and demo mode always look alive. Ids are deterministic and start with `demo-`.
///
/// Compiled into every target (Shared/Core), so it may only use Shared/Core + Shared/Models: colors are
/// literal Google Calendar palette hexes rather than `GoogleColor`.
enum DemoData {
    static let idPrefix = "demo-"

    static let eventHex = "#039BE5"     // Peacock (calendar default)
    static let taskHex = "#F6BF26"      // Banana
    static let deadlineHex = "#F4511E"  // Tangerine
    static let routineHex = "#0B8043"   // Basil

    static let meetingID = idPrefix + "meeting-joe"

    static func colorHex(for kind: ScheduleEvent.Kind) -> String {
        switch kind {
        case .event: eventHex
        case .task: taskHex
        case .deadline: deadlineHex
        case .routine: routineHex
        }
    }

    static func isDemoID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// Smallest interval containing every event: the window to hand `SharedStore.replaceWindow` when seeding.
    static func interval(covering events: [ScheduleEvent]) -> DateInterval? {
        guard let start = events.map(\.start).min(), let end = events.map(\.end).max(), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func events(now: Date = Date(), clock: WallClock = WallClock()) -> [ScheduleEvent] {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today // Sunday

        func day(_ offset: Int, from base: Date) -> Date {
            calendar.date(byAdding: .day, value: offset, to: base) ?? base
        }
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            clock.combine(day: day, time: (hour: hour, minute: minute)) ?? day
        }
        func minutes(_ value: Int, after start: Date) -> Date {
            start.addingTimeInterval(TimeInterval(value) * 60)
        }

        // Artboard 2: "Online meeting … in 21 MIN".
        let wholeMinute = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let meetingStart = Date(timeIntervalSinceReferenceDate: wholeMinute + 21 * 60)
        let meetingEnd = minutes(60, after: meetingStart)

        // Artboard 4 day: the day after tomorrow.
        let busyDay = day(2, from: today)
        let lunch = at(busyDay, 12, 30)
        let andrew = at(busyDay, 13, 0)
        let deadline = at(busyDay, 15, 0)

        // Thursday–Saturday of next week; all-day end is the exclusive midnight after the last day.
        let tripStart = day(11, from: weekStart)
        let tripEnd = day(14, from: weekStart)
        let trip = DateInterval(start: tripStart, end: tripEnd)

        let reply = at(day(1, from: today), 9, 0)
        let bills = at(day(3, from: today), 10, 0)
        let dentist = at(day(4, from: today), 9, 30)
        let concert = at(day(6, from: today), 20, 0)
        let dinner = at(day(8, from: today), 19, 0)

        var events: [ScheduleEvent] = [
            // 20 min before = about a minute after seeding, so the hold-to-reply reminder (Artboard 1) can be
            // tried in the Simulator right away.
            make("meeting-joe", "Online meeting with Joe", meetingStart, meetingEnd, .event,
                 meetURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                 notes: "Product quality review", reminderMinutes: [20, 5, 0]),
            make("lunch", "Lunch", lunch, minutes(60, after: lunch), .event, location: "Café Lucia"),
            make("andrew", "Meeting With Andrew", andrew, minutes(60, after: andrew), .event),
            make("deadline-5008", "Deadline for Plan 5008", deadline, minutes(30, after: deadline), .deadline),
            make("reply-joe", "Reply to Joe", reply, minutes(30, after: reply), .task),
            make("pay-bills", "Pay bills", bills, minutes(30, after: bills), .task),
            make("dentist", "Dentist", dentist, minutes(60, after: dentist), .event, location: "Smile Dental"),
            make("concert", "Concert", concert, minutes(150, after: concert), .event, location: "The Observatory"),
            make("team-dinner", "Team dinner", dinner, minutes(120, after: dinner), .event, location: "Little Italy"),
            make("trip-san-diego", "Trip to San Diego", tripStart, tripEnd, .event, allDay: true)
        ]

        // Weekly series from last week through ~6 weeks ahead. Weekday offsets are from Sunday.
        for week in -1..<6 {
            let base = day(7 * week, from: weekStart)
            for offset in [1, 3, 5] { // Mon, Wed, Fri
                let start = at(day(offset, from: base), 18, 30)
                guard !trip.contains(start) else { continue }
                events.append(make("gym-\(clock.dateString(start))", "Gym", start, minutes(60, after: start), .routine,
                                   seriesID: "gym"))
            }
            let sync = at(day(1, from: base), 10, 0)
            events.append(make("team-sync-\(clock.dateString(sync))", "Weekly team sync", sync, minutes(30, after: sync),
                               .event, seriesID: "team-sync"))
            let yoga = at(day(6, from: base), 9, 0)
            if !trip.contains(yoga) {
                events.append(make("yoga-\(clock.dateString(yoga))", "Yoga", yoga, minutes(60, after: yoga), .routine,
                                   seriesID: "yoga"))
            }
        }

        // Keep the meeting the next thing on the island: drop anything that would be running before it ends.
        return events
            .filter { $0.id == meetingID || $0.isAllDay || $0.end <= now || $0.start >= meetingEnd }
            .sorted { $0.start < $1.start }
    }

    private static func make(_ id: String,
                             _ title: String,
                             _ start: Date,
                             _ end: Date,
                             _ kind: ScheduleEvent.Kind,
                             seriesID: String? = nil,
                             allDay: Bool = false,
                             location: String? = nil,
                             meetURL: URL? = nil,
                             notes: String? = nil,
                             reminderMinutes: [Int]? = nil) -> ScheduleEvent {
        ScheduleEvent(
            id: idPrefix + id,
            seriesID: seriesID.map { idPrefix + $0 },
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            kind: kind,
            colorHex: colorHex(for: kind),
            location: location,
            meetURL: meetURL,
            notes: notes,
            reminderMinutes: reminderMinutes,
            planID: nil,
            htmlLink: nil,
            isCompleted: false
        )
    }
}
