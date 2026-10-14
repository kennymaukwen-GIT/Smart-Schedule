import Foundation

/// One row of the drawer's "Events" section and of the events list: a one-off event, or a whole repeating series
/// shown by its occurrence that is under way or comes next.
struct ManagedEventRow: Identifiable, Hashable, Sendable {
    /// The event id, or "series:<seriesID>" for a series (`EventDigest.seriesRowPrefix`).
    var id: String
    /// The event; for a series, the occurrence happening now or the next one.
    var event: ScheduleEvent
    var isSeries: Bool
    /// For a series, how many of its occurrences among the events given have not ended (1 for a one-off event).
    var occurrenceCount: Int
    /// Under way at `now`. All-day events never are: they belong to "Today".
    var isHappeningNow: Bool
}

/// The events list's sections, in display order.
enum ManagedEventSection: String, CaseIterable, Sendable {
    case now, today, tomorrow, thisWeek, later, repeating

    var title: String {
        switch self {
        case .now: String(localized: "Now")
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case .thisWeek: String(localized: "This week")
        case .later: String(localized: "Later")
        case .repeating: String(localized: "Repeating")
        }
    }
}

/// Every event that has not ended, as the drawer and the events list manage them. Pure (Foundation only), so it is
/// unit-tested and compiles in every target.
///
/// Feed it the events the calendars show (`ScheduleViewModel.events`, i.e. `SharedStore.visibleEvents`): hidden
/// calendars and a Focus filter are already applied there, one copy per meeting, demo events only in demo mode.
/// Plan and "Ask me first" previews (`isDraft`) are left out here. Ended events drop out whenever it is evaluated
/// again with a later `now`.
enum EventDigest {
    static let seriesRowPrefix = "series:"

    /// Not ended at `now`, no drafts. Each series (`seriesID`) is one row showing its occurrence under way or its
    /// next one; other events are a row each. Sorted by the shown occurrence's start, then title.
    static func rows(from events: [ScheduleEvent], now: Date, calendar: Calendar) -> [ManagedEventRow] {
        var rows: [ManagedEventRow] = []
        var series: [String: [ScheduleEvent]] = [:]
        var seriesOrder: [String] = []
        var seen = Set<String>()
        for event in events where event.end > now && !event.isDraft {
            guard seen.insert(event.id).inserted else { continue } // one copy per id, like visibleEvents
            if let seriesID = event.seriesID {
                if series[seriesID] == nil { seriesOrder.append(seriesID) }
                series[seriesID, default: []].append(event)
            } else {
                rows.append(ManagedEventRow(id: event.id, event: event, isSeries: false, occurrenceCount: 1,
                                            isHappeningNow: isHappeningNow(event, at: now)))
            }
        }
        for seriesID in seriesOrder {
            guard let occurrences = series[seriesID]?.sorted(by: startsEarlier), let next = occurrences.first else { continue }
            let shown = occurrences.first(where: { isHappeningNow($0, at: now) }) ?? next
            rows.append(ManagedEventRow(id: seriesRowPrefix + seriesID, event: shown, isSeries: true,
                                        occurrenceCount: occurrences.count,
                                        isHappeningNow: isHappeningNow(shown, at: now)))
        }
        return rows.sorted(by: rowOrder)
    }

    /// Non-empty sections in display order. Anything under way is "Now" (a series too); other series are
    /// "Repeating"; one-off events by when they start: before tomorrow (all-day events covering today included)
    /// "Today", then "Tomorrow", the rest of the week (`calendar.firstWeekday`) "This week", after it "Later".
    /// Days are calendar days, so 23- and 25-hour days around DST changes count as one day.
    static func sections(_ rows: [ManagedEventRow], now: Date,
                         calendar: Calendar) -> [(ManagedEventSection, [ManagedEventRow])] {
        let bounds = DayBounds(now: now, calendar: calendar)
        var grouped: [ManagedEventSection: [ManagedEventRow]] = [:]
        for row in rows {
            grouped[section(of: row, bounds: bounds), default: []].append(row)
        }
        return ManagedEventSection.allCases.compactMap { section in
            guard let members = grouped[section], !members.isEmpty else { return nil }
            return (section, members.sorted(by: rowOrder))
        }
    }

    /// The section one row is listed in.
    static func section(of row: ManagedEventRow, now: Date, calendar: Calendar) -> ManagedEventSection {
        section(of: row, bounds: DayBounds(now: now, calendar: calendar))
    }

    /// The drawer's short list: what is under way first, then the soonest.
    static func upcoming(_ rows: [ManagedEventRow], limit: Int) -> [ManagedEventRow] {
        let ordered = rows.sorted { lhs, rhs in
            if lhs.isHappeningNow != rhs.isHappeningNow { return lhs.isHappeningNow }
            return rowOrder(lhs, rhs)
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// The search field: every word of `query` appears in the title, the place or the notes, ignoring case, accents
    /// and full- or half-width forms. An empty query matches everything.
    static func matches(_ row: ManagedEventRow, query: String) -> Bool {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let text = [row.event.title, row.event.location ?? "", row.event.notes ?? ""].map(fold).joined(separator: "\n")
        return words.allSatisfy { text.contains($0) }
    }

    /// The occurrences of a series row's series among `events` (in the shown occurrence's calendar), for
    /// `repeatSummary`; just the event for a one-off row.
    static func occurrences(of row: ManagedEventRow, in events: [ScheduleEvent]) -> [ScheduleEvent] {
        guard row.isSeries, let seriesID = row.event.seriesID else { return [row.event] }
        return events.filter { $0.seriesID == seriesID && $0.calendarRef == row.event.calendarRef && !$0.isDraft }
            .sorted(by: startsEarlier)
    }

    // MARK: Repeat summary

    /// How a series repeats, with its time: "Every Sat 09:00", "Every Mon, Wed and Fri 18:30", "Every weekday 08:00",
    /// "Every day 07:00", "Every 2 weeks on Tue 10:00", "Every 3 days", "Every month on day 15", "Every year", or
    /// "Repeats" when the pattern cannot be told.
    ///
    /// Read from the occurrences' dates (the cache holds Google's expanded instances, not the RRULE): give it every
    /// cached occurrence (`occurrences(of:in:)`, past ones too), the more the surer. A week or two of gaps (a paused
    /// series) still reads as weekly. Weekday names come from `locale`; the sentence from the String Catalog.
    static func repeatSummary(for event: ScheduleEvent, occurrences: [ScheduleEvent], calendar: Calendar,
                              locale: Locale) -> String {
        let related = occurrences.filter { $0.seriesID == event.seriesID } + [event]
        let days = Array(Set(related.map { calendar.startOfDay(for: $0.start) })).sorted()
        guard let rule = rule(days: days, calendar: calendar, locale: locale) else {
            return String(localized: "Repeats")
        }
        guard !event.isAllDay else { return rule }
        let parts = calendar.dateComponents([.hour, .minute], from: event.start)
        return rule + " " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The rule the dates follow, nil when none fits.
    private static func rule(days: [Date], calendar: Calendar, locale: Locale) -> String? {
        guard days.count >= 2, let first = days.first, let last = days.last else { return nil }
        let gaps = zip(days, days.dropFirst()).map { dayCount(from: $0, to: $1, calendar: calendar) }
        guard gaps.allSatisfy({ $0 > 0 }) else { return nil }
        let weekdays = Set(days.map { calendar.component(.weekday, from: $0) })
        if gaps.allSatisfy({ $0 == 1 }) { return String(localized: "Every day") }

        // Monthly and yearly before the weekly rules: their gaps differ from month to month.
        let monthDays = Set(days.map { calendar.component(.day, from: $0) })
        if monthDays.count == 1, gaps.allSatisfy({ (28...31).contains($0) }), let day = monthDays.first {
            return String(localized: "Every month on day \(day)")
        }
        let months = Set(days.map { calendar.component(.month, from: $0) })
        if monthDays.count == 1, months.count == 1, gaps.allSatisfy({ (365...366).contains($0) }) {
            return String(localized: "Every year")
        }

        if gaps.allSatisfy({ $0 % 7 == 0 }), weekdays.count == 1 {
            let weeks = gaps.reduce(0) { gcd($0, $1) } / 7
            let name = weekdayList(weekdays, calendar: calendar, locale: locale)
            return weeks <= 1 ? String(localized: "Every \(name)") : String(localized: "Every \(weeks) weeks on \(name)")
        }
        if let step = gaps.first, step > 1, step % 7 != 0, gaps.allSatisfy({ $0 == step }) {
            return String(localized: "Every \(step) days")
        }

        // Daily or weekly on several days: most of the matching days in the span are there (a paused week is fine).
        let span = dayCount(from: first, to: last, calendar: calendar) + 1
        var expected = 0
        var day = first
        for _ in 0..<span {
            if weekdays.contains(calendar.component(.weekday, from: day)) { expected += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard expected > 0, Double(days.count) / Double(expected) >= 0.6, gaps.allSatisfy({ $0 <= 14 }) else {
            return nil
        }
        if weekdays.count == 7 { return String(localized: "Every day") }
        if weekdays == [2, 3, 4, 5, 6] { return String(localized: "Every weekday") }
        return String(localized: "Every \(weekdayList(weekdays, calendar: calendar, locale: locale))")
    }

    /// "Sat", "Mon, Wed and Fri" / "週六", "週一、週三和週五": short names in week order (from `firstWeekday`).
    private static func weekdayList(_ weekdays: Set<Int>, calendar: Calendar, locale: Locale) -> String {
        var named = calendar
        named.locale = locale
        let symbols = named.shortWeekdaySymbols
        let ordered = weekdays.sorted { (($0 - calendar.firstWeekday + 7) % 7) < (($1 - calendar.firstWeekday + 7) % 7) }
        let names = ordered.compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    // MARK: Helpers

    static func isHappeningNow(_ event: ScheduleEvent, at now: Date) -> Bool {
        !event.isAllDay && event.start <= now && now < event.end
    }

    private struct DayBounds {
        let tomorrow: Date
        let dayAfterTomorrow: Date
        let weekEnd: Date

        init(now: Date, calendar: Calendar) {
            let today = calendar.startOfDay(for: now)
            tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
            dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today) ?? tomorrow.addingTimeInterval(86_400)
            weekEnd = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? dayAfterTomorrow
        }
    }

    private static func section(of row: ManagedEventRow, bounds: DayBounds) -> ManagedEventSection {
        if row.isHappeningNow { return .now }
        if row.isSeries { return .repeating }
        let start = row.event.start
        if start < bounds.tomorrow { return .today }
        if start < bounds.dayAfterTomorrow { return .tomorrow }
        if start < bounds.weekEnd { return .thisWeek }
        return .later
    }

    private static func startsEarlier(_ lhs: ScheduleEvent, _ rhs: ScheduleEvent) -> Bool {
        lhs.start != rhs.start ? lhs.start < rhs.start : lhs.id < rhs.id
    }

    private static func rowOrder(_ lhs: ManagedEventRow, _ rhs: ManagedEventRow) -> Bool {
        if lhs.event.start != rhs.event.start { return lhs.event.start < rhs.event.start }
        let byTitle = lhs.event.title.localizedCaseInsensitiveCompare(rhs.event.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func dayCount(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? abs(a) : gcd(b, a % b)
    }
}
