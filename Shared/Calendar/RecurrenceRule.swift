import Foundation

/// RFC 5545 RRULE construction for Google Calendar `recurrence`.
enum RecurrenceRule {
    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] // index = Calendar weekday - 1
    private static let frequencies: Set<String> = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]

    /// Builds `RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;UNTIL=20270412T225959Z`.
    /// UNTIL is converted to UTC because DTSTART carries a TZID (RFC 5545 §3.3.10).
    static func make(frequency: String,
                     interval: Int? = nil,
                     byWeekday: [String]? = nil,
                     untilDay: Date? = nil,
                     count: Int? = nil,
                     clock: WallClock) -> String? {
        let freq = frequency.uppercased()
        guard frequencies.contains(freq) else { return nil }
        var parts = ["FREQ=\(freq)"]
        if let interval, interval > 1 { parts.append("INTERVAL=\(min(interval, 52))") }
        let days = normalizedWeekdays(byWeekday)
        if !days.isEmpty, freq == "WEEKLY" || freq == "DAILY" {
            parts.append("BYDAY=\(days.joined(separator: ","))")
        }
        // UNTIL and COUNT must not both appear; UNTIL wins (more robust to edits).
        if let untilDay, let lastInstant = endOfDay(untilDay, clock: clock) {
            parts.append("UNTIL=\(WallClock.icsUTCString(lastInstant))")
        } else if let count, count > 0 {
            parts.append("COUNT=\(min(count, 730))")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    static func make(from draft: RecurrenceDraft, clock: WallClock) -> String? {
        make(frequency: draft.frequency,
             interval: draft.interval,
             byWeekday: draft.byWeekday,
             untilDay: draft.until.flatMap(clock.date),
             count: draft.count,
             clock: clock)
    }

    /// RFC 5545 counts DTSTART as the first instance even if it does not match BYDAY, so a plan phase
    /// starting on a Tuesday with BYDAY=MO,WE,FR must be anchored on Wednesday.
    static func firstMatchingDay(onOrAfter day: Date, weekdays: [String], clock: WallClock) -> Date? {
        let wanted = Set(normalizedWeekdays(weekdays))
        guard !wanted.isEmpty else { return day }
        let calendar = clock.calendar
        for offset in 0..<7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
            let code = weekdayCodes[calendar.component(.weekday, from: candidate) - 1]
            if wanted.contains(code) { return candidate }
        }
        return nil
    }

    static func normalizedWeekdays(_ values: [String]?) -> [String] {
        let valid = Set(weekdayCodes)
        var seen = Set<String>()
        return (values ?? [])
            .map { $0.uppercased().prefix(2).description }
            .filter { valid.contains($0) && seen.insert($0).inserted }
            .sorted { order($0) < order($1) }
    }

    private static func order(_ code: String) -> Int {
        // Monday-first ordering reads naturally in RRULEs.
        ["MO", "TU", "WE", "TH", "FR", "SA", "SU"].firstIndex(of: code) ?? 7
    }

    private static func endOfDay(_ day: Date, clock: WallClock) -> Date? {
        let calendar = clock.calendar
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start)
    }
}
