import Foundation

/// Sample schedule mirroring the designer's artboards, laid out around the *current* week so Xcode Previews,
/// the Simulator and demo mode always look alive. Ids are deterministic and start with `demo-`.
///
/// Two sample accounts hold it: gym and yoga are in the personal account's "Gym" calendar, the team sync and the
/// Plan 5008 deadline in the school account, everything else in the personal account's primary calendar.
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

    // MARK: Sample accounts

    static let personalAccountID = idPrefix + "personal"
    static let schoolAccountID = idPrefix + "school"
    static let personalEmail = "you@example.com"
    static let schoolEmail = "student@university.example.edu"
    static let personalHex = eventHex   // Peacock
    static let gymHex = routineHex      // Basil
    static let schoolHex = "#7986CB"    // Lavender

    /// A primary calendar's id is the account's email, as in Google.
    static let personalCalendar = CalendarRef(accountID: personalAccountID, calendarID: personalEmail)
    static let gymCalendar = CalendarRef(accountID: personalAccountID, calendarID: idPrefix + "gym")
    static let schoolCalendar = CalendarRef(accountID: schoolAccountID, calendarID: schoolEmail)
    /// Where the demo assistant adds events unless "Use for new events" or `default_calendar` picks another.
    static var defaultCalendar: CalendarRef { personalCalendar }

    /// Two sample accounts, so the drawer, calendar visibility and `default_calendar` work offline. `AccountStore`
    /// returns them in demo mode with the user's settings for each calendar applied.
    static var accounts: [GoogleAccount] {
        let connectedAt = Date(timeIntervalSince1970: 1_791_849_600) // fixed: the sample never changes
        func calendar(_ ref: CalendarRef, email: String, name: String, primary: Bool, hex: String) -> CalendarInfo {
            CalendarInfo(accountID: ref.accountID, accountEmail: email, calendarID: ref.calendarID, name: name,
                         isPrimary: primary, accessRole: "owner", googleColorHex: hex)
        }
        return [
            GoogleAccount(id: personalAccountID, email: personalEmail, connectedAt: connectedAt,
                          grantedScopes: [GoogleAccount.calendarListScope],
                          calendars: [calendar(personalCalendar, email: personalEmail, name: personalEmail, primary: true, hex: personalHex),
                                      calendar(gymCalendar, email: personalEmail, name: "Gym", primary: false, hex: gymHex)],
                          calendarsUpdatedAt: connectedAt),
            GoogleAccount(id: schoolAccountID, email: schoolEmail, connectedAt: connectedAt,
                          grantedScopes: [GoogleAccount.calendarListScope],
                          calendars: [calendar(schoolCalendar, email: schoolEmail, name: schoolEmail, primary: true, hex: schoolHex)],
                          calendarsUpdatedAt: connectedAt)
        ]
    }

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

    /// The weeks `events(now:clock:)` fills, last week through five weeks ahead (Sunday to Sunday): the window
    /// to hand `SharedStore.replaceWindow` when seeding. Every seeded event lies inside it.
    static func seedWindow(now: Date = Date(), clock: WallClock = WallClock()) -> DateInterval {
        let calendar = clock.calendar
        let weekStart = sunday(onOrBefore: now, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let end = calendar.date(byAdding: .day, value: 42, to: weekStart) ?? weekStart
        return DateInterval(start: start, end: max(start, end))
    }

    /// The seed: one-off items placed relative to `now`, plus the weekly series over `seedWindow`.
    static func events(now: Date = Date(), clock: WallClock = WallClock()) -> [ScheduleEvent] {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: now)
        let weekStart = sunday(onOrBefore: now, calendar: calendar)

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
            make("deadline-5008", "Deadline for Plan 5008", deadline, minutes(30, after: deadline), .deadline,
                 calendar: schoolCalendar),
            make("reply-joe", "Reply to Joe", reply, minutes(30, after: reply), .task),
            make("pay-bills", "Pay bills", bills, minutes(30, after: bills), .task),
            make("dentist", "Dentist", dentist, minutes(60, after: dentist), .event, location: "Smile Dental"),
            make("concert", "Concert", concert, minutes(150, after: concert), .event, location: "The Observatory"),
            make("team-dinner", "Team dinner", dinner, minutes(120, after: dinner), .event, location: "Little Italy"),
            make("trip-san-diego", "Trip to San Diego", tripStart, tripEnd, .event, allDay: true)
        ]

        events += recurringEvents(in: seedWindow(now: now, clock: clock), clock: clock, pausedDuring: trip)

        // Keep the meeting the next thing on the island: drop anything that would be running before it ends.
        return events
            .filter { $0.id == meetingID || $0.isAllDay || $0.end <= now || $0.start >= meetingEnd }
            .sorted { $0.start < $1.start }
    }

    // MARK: Weekly series

    /// The weekly demo series in any range, so the calendars never run out of sample data however far they
    /// scroll. Each occurrence's id is `demo-<series>-<yyyy-MM-dd>`: unique, and the same whichever range
    /// produced it, so overlapping ranges merge instead of duplicating. One-off items are not included; they
    /// exist only in the seed. Gym and Yoga skip occurrences starting inside `pausedDuring` (the seeded trip).
    static func recurringEvents(in range: DateInterval,
                                clock: WallClock = WallClock(),
                                pausedDuring away: DateInterval? = nil) -> [ScheduleEvent] {
        guard range.duration > 0 else { return [] }
        let calendar = clock.calendar
        var events: [ScheduleEvent] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            let weekday = calendar.component(.weekday, from: day)
            for series in weeklySeries where series.weekdays.contains(weekday) {
                // Set on the day itself, not 86 400 s steps, so 18:30 stays 18:30 across DST changes.
                guard let start = clock.combine(day: day, time: (hour: series.hour, minute: series.minute)) else { continue }
                if series.pausesWhenAway, let away, away.contains(start) { continue }
                let end = start.addingTimeInterval(TimeInterval(series.minutes) * 60)
                guard start < range.end && end > range.start else { continue }
                events.append(make("\(series.key)-\(clock.dateString(start))", series.title, start, end, series.kind,
                                   seriesID: series.key, calendar: series.calendar))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return events
    }

    /// An occurrence `recurringEvents` can produce again, so the cache cap may drop it. Everything else with a
    /// demo id (one-offs, events the demo assistant created) exists only in the cache.
    static func isRecurringOccurrence(_ event: ScheduleEvent) -> Bool {
        guard let seriesID = event.seriesID else { return false }
        return weeklySeries.contains { idPrefix + $0.key == seriesID }
    }

    private struct WeeklySeries: Sendable {
        let key: String           // id stem and seriesID, without the prefix
        let title: String
        let weekdays: Set<Int>    // `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday
        let hour: Int
        let minute: Int
        let minutes: Int
        let kind: ScheduleEvent.Kind
        let pausesWhenAway: Bool
        let calendar: CalendarRef
    }

    private static let weeklySeries: [WeeklySeries] = [
        WeeklySeries(key: "gym", title: "Gym", weekdays: [2, 4, 6], hour: 18, minute: 30, minutes: 60,
                     kind: .routine, pausesWhenAway: true, calendar: gymCalendar),
        WeeklySeries(key: "team-sync", title: "Weekly team sync", weekdays: [2], hour: 10, minute: 0, minutes: 30,
                     kind: .event, pausesWhenAway: false, calendar: schoolCalendar),
        WeeklySeries(key: "yoga", title: "Yoga", weekdays: [7], hour: 9, minute: 0, minutes: 60,
                     kind: .routine, pausesWhenAway: true, calendar: gymCalendar)
    ]

    /// The colour a sample calendar is drawn in before the user overrides it.
    private static func googleColorHex(of calendar: CalendarRef) -> String {
        switch calendar {
        case gymCalendar: gymHex
        case schoolCalendar: schoolHex
        default: personalHex
        }
    }

    /// Sunday on or before `date`, whichever day "Week starts on" picks, so the sample week looks the same.
    private static func sunday(onOrBefore date: Date, calendar: Calendar) -> Date {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let today = sundayFirst.startOfDay(for: date)
        return sundayFirst.dateInterval(of: .weekOfYear, for: today)?.start ?? today
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
                             reminderMinutes: [Int]? = nil,
                             calendar: CalendarRef = DemoData.personalCalendar) -> ScheduleEvent {
        // Like Google: tasks and deadlines carry a colour of their own, everything else shows its calendar's.
        let usesCalendarColor = kind != .task && kind != .deadline
        return ScheduleEvent(
            id: idPrefix + id,
            seriesID: seriesID.map { idPrefix + $0 },
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            kind: kind,
            colorHex: usesCalendarColor ? googleColorHex(of: calendar) : colorHex(for: kind),
            location: location,
            meetURL: meetURL,
            notes: notes,
            reminderMinutes: reminderMinutes,
            planID: nil,
            htmlLink: nil,
            isCompleted: false,
            accountID: calendar.accountID,
            calendarID: calendar.calendarID,
            usesCalendarColor: usesCalendarColor
        )
    }
}
