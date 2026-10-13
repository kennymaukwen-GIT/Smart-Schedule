import Foundation

/// Expands the weekly series the plan mapper writes (`DTSTART` wall time + `RRULE:FREQ=WEEKLY;BYDAY=…;UNTIL=…Z`)
/// into single occurrences, the way Google's `singleEvents=true` listing does. Used for plan previews and for
/// demo mode, which has no Google to expand them.
///
/// DST-safe: days are stepped with `Calendar` in the clock's zone and every occurrence keeps DTSTART's wall-clock
/// time, so an 18:30 session stays 18:30 across BST/GMT changes. Supports what `RecurrenceRule` emits for plans
/// (WEEKLY with BYDAY, INTERVAL, UNTIL or COUNT); any other frequency expands to nothing.
enum RecurrenceExpander {
    struct Rule: Equatable, Sendable {
        var frequency: String
        var interval = 1
        var weekdays: [String] = []
        var until: Date?
        var count: Int?

        /// Parses `RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20261130T235959Z` (the `RRULE:` prefix is optional).
        init?(_ rrule: String) {
            let body = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst("RRULE:".count)) : rrule
            var fields: [String: String] = [:]
            for part in body.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0].uppercased()] = pair[1] }
            }
            guard let frequency = fields["FREQ"]?.uppercased() else { return nil }
            self.frequency = frequency
            interval = max(Int(fields["INTERVAL"] ?? "") ?? 1, 1)
            weekdays = RecurrenceRule.normalizedWeekdays(fields["BYDAY"]?.split(separator: ",").map(String.init))
            until = fields["UNTIL"].flatMap(RecurrenceExpander.parseICSUTC)
            count = fields["COUNT"].flatMap { Int($0) }
        }
    }

    /// Start instants of a weekly series, oldest first: days on or after `firstStart` whose weekday is in BYDAY
    /// (DTSTART's own weekday when BYDAY is absent), at DTSTART's wall time, up to UNTIL (inclusive), COUNT and
    /// `horizon` (exclusive).
    static func weeklyStarts(firstStart: Date, rule: Rule, through horizon: Date, clock: WallClock) -> [Date] {
        guard rule.frequency == "WEEKLY" else { return [] }
        let calendar = clock.calendar
        let time = calendar.dateComponents([.hour, .minute], from: firstStart)
        let firstDay = calendar.startOfDay(for: firstStart)
        let wanted = Set(rule.weekdays.isEmpty ? [code(for: firstDay, calendar: calendar)] : rule.weekdays)

        var starts: [Date] = []
        var day = firstDay
        var week = 0 // RFC 5545 default WKST=MO: INTERVAL counts weeks that begin on Monday
        while day < horizon {
            let weekday = code(for: day, calendar: calendar)
            if weekday == "MO", day != firstDay { week += 1 }
            if week % rule.interval == 0, wanted.contains(weekday),
               let start = clock.combine(day: day, time: (hour: time.hour ?? 0, minute: time.minute ?? 0)),
               start >= firstStart {
                if start >= horizon { break }
                if let until = rule.until, start > until { break }
                starts.append(start)
                if let count = rule.count, starts.count >= count { break }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return starts
    }

    static func weeklyStarts(firstStart: Date, rrule: String, through horizon: Date, clock: WallClock) -> [Date] {
        guard let rule = Rule(rrule) else { return [] }
        return weeklyStarts(firstStart: firstStart, rule: rule, through: horizon, clock: clock)
    }

    /// The occurrences of one series body (from `CalendarEventMapper`), shaped like Google's expanded instances:
    /// id `<idPrefix><seriesId>_<yyyyMMdd>`, `seriesID` set, same duration, title, colour and plan id.
    static func instances(of series: GCalEvent,
                          through horizon: Date,
                          idPrefix: String,
                          mapper: CalendarEventMapper) -> [ScheduleEvent] {
        let clock = mapper.clock
        guard let rrule = series.recurrence?.first(where: { $0.hasPrefix("RRULE:") }),
              let startRaw = series.start?.dateTime, let firstStart = parse(startRaw, clock: clock),
              let endRaw = series.end?.dateTime, let firstEnd = parse(endRaw, clock: clock) else { return [] }
        let duration = firstEnd.timeIntervalSince(firstStart)
        let seriesID = idPrefix + (series.id ?? "series")

        return weeklyStarts(firstStart: firstStart, rrule: rrule, through: horizon, clock: clock).compactMap { start -> ScheduleEvent? in
            var instance = series
            instance.id = seriesID + "_" + clock.dateString(start).replacingOccurrences(of: "-", with: "")
            instance.recurringEventId = seriesID
            instance.recurrence = nil
            instance.start = mapper.timed(start)
            instance.end = mapper.timed(start.addingTimeInterval(duration))
            return mapper.scheduleEvent(from: instance)
        }
    }

    /// `20270412T225959Z` → instant. Date-only `20270412` is midnight UTC.
    static func parseICSUTC(_ value: String) -> Date? {
        let digits = Array(value.filter { $0.isASCII && $0.isNumber })
        guard digits.count >= 8 else { return nil }
        func field(_ start: Int, _ length: Int) -> Int? {
            guard digits.count >= start + length else { return nil }
            return Int(String(digits[start..<(start + length)]))
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: field(0, 4), month: field(4, 2), day: field(6, 2),
                                             hour: field(8, 2) ?? 0, minute: field(10, 2) ?? 0, second: field(12, 2) ?? 0))
    }

    private static func code(for day: Date, calendar: Calendar) -> String {
        RecurrenceRule.weekdayCodes[calendar.component(.weekday, from: day) - 1] // Calendar weekday 1 = Sunday
    }

    private static func parse(_ raw: String, clock: WallClock) -> Date? {
        WallClock.parseRFC3339(raw) ?? clock.dateTime(raw)
    }
}
