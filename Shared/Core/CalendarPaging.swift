import Foundation

/// The slice of the calendar Quick Capture shows: DAY | WEEK | MONTH. The raw value is what gets remembered.
enum CalendarScope: String, CaseIterable, Sendable {
    case day
    case week
    case month

    /// The scope that fits a range the assistant asked to show: one day, up to seven days, or longer.
    static func fitting(_ range: DateInterval, calendar: Calendar) -> CalendarScope {
        let days = CalendarPaging.dayCount(of: range, calendar: calendar)
        if days <= 1 { return .day }
        return days <= 7 ? .week : .month
    }
}

/// Pure date math behind the calendars: Quick Capture's day and week pages and continuously scrolling month
/// grid, and the main view's month chips and month pages.
///
/// Day and week boundaries always come from `Calendar`, never from 86 400-second steps: London's 25 Oct 2026
/// has 25 hours, so `+ 7 × 86 400 s` from that Sunday lands on Saturday 23:00 instead of the next Sunday.
/// Weeks start on `calendar.firstWeekday` (Sunday for `WallClock().calendar`).
enum CalendarPaging {

    // MARK: Endless paging

    /// How far each pager reaches either side of its anchor date. Pages are lazy and all the same size, so only
    /// the few on screen are ever built, however many there are; nobody swipes a century by hand.
    static let reachYears = 101
    static let dayPages = -(reachYears * 366)...(reachYears * 366)
    static let weekPages = -(reachYears * 53)...(reachYears * 53)
    static let monthPages = -(reachYears * 12)...(reachYears * 12)

    /// Whether a pager can show `offset` from its current anchor. Past half its reach (only a jump decades
    /// away gets there) the pager re-anchors on the target instead, so neither end is ever in sight.
    static func isWithinReach(_ offset: Int, of pages: ClosedRange<Int>) -> Bool {
        abs(offset) <= pages.upperBound / 2
    }

    // MARK: Days and weeks

    static func day(_ offset: Int, after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: offset, to: date) ?? date
    }

    /// Calendar days from the day containing `reference` to the day containing `date` (negative = earlier).
    static func dayOffset(of date: Date, from reference: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: reference),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Local midnight to the next local midnight (23 or 25 hours on DST days).
    static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: day(1, after: start, calendar: calendar))
        return DateInterval(start: start, end: max(start, end))
    }

    /// Calendar days a range covers. A 23 h or 25 h DST day still counts as one, and a `7 × 86 400 s` range
    /// across a DST change as seven.
    static func dayCount(of range: DateInterval, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.day, .hour], from: range.start, to: range.end)
        let days = (parts.day ?? 0) + ((parts.hour ?? 0) >= 12 ? 1 : 0)
        return max(1, days)
    }

    /// Midnight of the `calendar.firstWeekday` on or before `date`.
    static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let daysBack = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
        return day(-daysBack, after: calendar.startOfDay(for: date), calendar: calendar)
    }

    static func week(_ offset: Int, from weekStart: Date, calendar: Calendar) -> Date {
        day(7 * offset, after: weekStart, calendar: calendar)
    }

    static func weekInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = weekStart(containing: date, calendar: calendar)
        return DateInterval(start: start, end: max(start, week(1, from: start, calendar: calendar)))
    }

    static func days(ofWeekStarting weekStart: Date, calendar: Calendar) -> [Date] {
        (0..<7).map { day($0, after: weekStart, calendar: calendar) }
    }

    /// Whole weeks from the week containing `reference` to the week containing `date` (negative = earlier).
    static func weekOffset(of date: Date, from reference: Date, calendar: Calendar) -> Int {
        let from = weekStart(containing: reference, calendar: calendar)
        let to = weekStart(containing: date, calendar: calendar)
        return (calendar.dateComponents([.day], from: from, to: to).day ?? 0) / 7
    }

    // MARK: Months

    /// The first moment of the month containing `date`.
    static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The first moment of the month `offset` months from the one containing `date`.
    static func month(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
        let start = monthStart(containing: date, calendar: calendar)
        guard let shifted = calendar.date(byAdding: .month, value: offset, to: start) else { return start }
        return monthStart(containing: shifted, calendar: calendar)
    }

    /// Whole months from the month containing `reference` to the month containing `date` (negative = earlier).
    static func monthOffset(of date: Date, from reference: Date, calendar: Calendar) -> Int {
        let from = calendar.dateComponents([.year, .month], from: reference)
        let to = calendar.dateComponents([.year, .month], from: date)
        return ((to.year ?? 0) - (from.year ?? 0)) * 12 + (to.month ?? 0) - (from.month ?? 0)
    }

    static func monthInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = monthStart(containing: date, calendar: calendar)
        return DateInterval(start: start, end: max(start, month(1, from: start, calendar: calendar)))
    }

    /// Whole weeks covering the month containing `date`, as the main month grid draws it.
    static func monthGridInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let interval = monthInterval(containing: date, calendar: calendar)
        let first = weekStart(containing: interval.start, calendar: calendar)
        let last = weekStart(containing: lastDay(of: interval, calendar: calendar), calendar: calendar)
        return DateInterval(start: first, end: max(first, week(1, from: last, calendar: calendar)))
    }

    // MARK: Month window

    /// `weeks` continuous weeks starting `leadWeeks` before the week containing `date`. `end` is exclusive.
    static func monthWindow(around date: Date, leadWeeks: Int = 1, weeks: Int = 5, calendar: Calendar) -> DateInterval {
        let first = week(-leadWeeks, from: weekStart(containing: date, calendar: calendar), calendar: calendar)
        return DateInterval(start: first, end: max(first, week(weeks, from: first, calendar: calendar)))
    }

    /// The month most of the window shows (the one holding its middle day); days outside it are dimmed.
    static func referenceMonth(of window: DateInterval, calendar: Calendar) -> DateInterval? {
        let days = calendar.dateComponents([.day], from: window.start, to: window.end).day ?? 0
        let middle = day(days / 2, after: window.start, calendar: calendar)
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: middle)),
              let end = calendar.date(byAdding: .month, value: 1, to: start), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// How many week rows fit `height` without going under `minimumRowHeight`, clamped to `range`.
    static func visibleWeekCount(forHeight height: Double, minimumRowHeight: Double, range: ClosedRange<Int>) -> Int {
        guard minimumRowHeight > 0, height.isFinite, height > 0 else { return range.upperBound }
        let fitting = Int((height / minimumRowHeight).rounded(.down))
        return min(max(fitting, range.lowerBound), range.upperBound)
    }

    // MARK: Titles

    /// Start of the last day inside `range` (whose `end` is exclusive).
    static func lastDay(of range: DateInterval, calendar: Calendar) -> Date {
        calendar.startOfDay(for: range.end > range.start ? range.end.addingTimeInterval(-1) : range.start)
    }

    /// "Oct 11 – Oct 17" in en_US; month and day follow `locale` ("10月11日 – 10月17日" in zh-Hant).
    static func rangeTitle(_ range: DateInterval, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: range.start) + " – " + formatter.string(from: lastDay(of: range, calendar: calendar))
    }

    /// A month chip: "Oct" / "10月", and on January the year as well, "Jan 2027" / "2027年1月", so scrolling
    /// past a new year shows which one it is.
    static func monthChipLabel(_ month: Date, calendar: Calendar, locale: Locale) -> String {
        let isJanuary = calendar.component(.month, from: month) == 1
        return formatted(month, template: isJanuary ? "yMMM" : "MMM", calendar: calendar, locale: locale)
    }

    /// "2031" / "2031年" when `range` lies outside the year of `now` ("2030 – 2031" across New Year), nil
    /// inside it: titles like "Mar 9 – Mar 15" leave the year out.
    static func yearLabel(for range: DateInterval, now: Date, calendar: Calendar, locale: Locale) -> String? {
        let first = calendar.component(.year, from: range.start)
        let lastDate = lastDay(of: range, calendar: calendar)
        let last = calendar.component(.year, from: lastDate)
        let current = calendar.component(.year, from: now)
        guard first != current || last != current else { return nil }
        let start = formatted(range.start, template: "y", calendar: calendar, locale: locale)
        guard first != last else { return start }
        return start + " – " + formatted(lastDate, template: "y", calendar: calendar, locale: locale)
    }

    private static func formatted(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // MARK: Events per day

    /// Drawn as a bar across day columns: all-day events covering two or more days, and timed events lasting
    /// at least a whole day. Anything shorter is a chip on each day it touches.
    static func isMultiDay(_ event: ScheduleEvent, calendar: Calendar) -> Bool {
        if event.isAllDay {
            return day(1, after: calendar.startOfDay(for: event.start), calendar: calendar) < event.end
        }
        guard let oneDayLater = calendar.date(byAdding: .day, value: 1, to: event.start) else { return false }
        return oneDayLater <= event.end
    }

    /// Everything on `day`: multi-day events first (so bars line up across cells), then all-day, then by time.
    static func events(on day: Date, from events: [ScheduleEvent], calendar: Calendar) -> [ScheduleEvent] {
        let interval = dayInterval(containing: day, calendar: calendar)
        return events
            .filter { $0.intersects(interval) }
            .map { (event: $0, isMultiDay: isMultiDay($0, calendar: calendar)) }
            .sorted { lhs, rhs in
                lhs.isMultiDay != rhs.isMultiDay ? lhs.isMultiDay : precedes(lhs.event, rhs.event)
            }
            .map { $0.event }
    }

    /// The chips of `day`: events on it that are not drawn as multi-day bars.
    static func singleDayEvents(on day: Date, from events: [ScheduleEvent], calendar: Calendar) -> [ScheduleEvent] {
        let interval = dayInterval(containing: day, calendar: calendar)
        return events
            .filter { $0.intersects(interval) && !isMultiDay($0, calendar: calendar) }
            .sorted(by: precedes)
    }

    // MARK: Week rows

    /// A multi-day event clipped to one week row. Columns are 0...6 from the week's first day.
    struct WeekSpan: Equatable, Identifiable {
        let event: ScheduleEvent
        let firstColumn: Int
        let lastColumn: Int
        /// Row under the date numbers; overlapping spans get different lanes.
        let lane: Int
        /// Started in an earlier week / ends in a later one (drawn without the rounded end).
        let continuesBefore: Bool
        let continuesAfter: Bool

        var id: String { event.id }
        var columnCount: Int { lastColumn - firstColumn + 1 }

        func covers(_ column: Int) -> Bool {
            firstColumn <= column && column <= lastColumn
        }
    }

    struct WeekLayout: Equatable {
        let days: [Date]
        let spans: [WeekSpan]
        /// Chips per column, in display order.
        let singles: [[ScheduleEvent]]

        var laneCount: Int { (spans.map(\.lane).max() ?? -1) + 1 }
    }

    static func weekLayout(startingAt weekStart: Date, events: [ScheduleEvent], calendar: Calendar) -> WeekLayout {
        let columns = Self.days(ofWeekStarting: weekStart, calendar: calendar)
        let weekEnd = day(7, after: weekStart, calendar: calendar)
        let inWeek = events.filter { $0.start < weekEnd && $0.end > weekStart }
        let chips = inWeek.filter { !isMultiDay($0, calendar: calendar) }.sorted(by: precedes)
        let singles = columns.map { column in
            let interval = dayInterval(containing: column, calendar: calendar)
            return chips.filter { $0.intersects(interval) }
        }
        return WeekLayout(days: columns,
                          spans: Self.spans(inWeekStarting: weekStart, events: inWeek, calendar: calendar),
                          singles: singles)
    }

    /// Multi-day events of the week as bars, each in the lowest lane free over its columns.
    static func spans(inWeekStarting weekStart: Date, events: [ScheduleEvent], calendar: Calendar) -> [WeekSpan] {
        let weekEnd = day(7, after: weekStart, calendar: calendar)
        let candidates = events
            .filter { $0.start < weekEnd && $0.end > weekStart && isMultiDay($0, calendar: calendar) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end > rhs.end }
                return lhs.id < rhs.id
            }

        var laneEnds: [Int] = [] // last column taken in each lane
        var result: [WeekSpan] = []
        for event in candidates {
            let firstDay = calendar.startOfDay(for: event.start)
            let lastDay = calendar.startOfDay(for: event.end.addingTimeInterval(-1)) // `end` is exclusive
            let first = max(0, column(of: firstDay, weekStart: weekStart, calendar: calendar))
            let last = min(6, column(of: lastDay, weekStart: weekStart, calendar: calendar))
            guard first <= last else { continue }

            let lane = laneEnds.firstIndex { $0 < first } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(last) } else { laneEnds[lane] = last }
            result.append(WeekSpan(event: event,
                                   firstColumn: first,
                                   lastColumn: last,
                                   lane: lane,
                                   continuesBefore: firstDay < weekStart,
                                   continuesAfter: lastDay >= weekEnd))
        }
        return result
    }

    /// How a month cell spends the `lines` under its date number.
    struct CellLayout: Equatable {
        /// Lines at the top taken by bars (up to the deepest visible lane over this column).
        var barLines: Int
        /// Single-day chips shown, from the start of the column's list.
        var chips: Int
        /// The "+N" count; 0 means no overflow line.
        var more: Int
    }

    /// Bars keep their lanes, chips fill what is left, and when the rest doesn't fit the last line becomes "+N":
    /// with two lines, three or more chips show as one chip and "+2", "+3", ….
    /// When bars take every line there is no room for "+N" and `more` is 0.
    static func cellLayout(column: Int, in week: WeekLayout, lines: Int) -> CellLayout {
        let available = max(0, lines)
        let covering = week.spans.filter { $0.covers(column) }
        let shown = covering.filter { $0.lane < available }
        let barLines = shown.map(\.lane).max().map { $0 + 1 } ?? 0
        let hiddenBars = covering.count - shown.count
        let chips = week.singles.indices.contains(column) ? week.singles[column].count : 0
        let capacity = available - barLines

        if hiddenBars == 0 && chips <= capacity {
            return CellLayout(barLines: barLines, chips: chips, more: 0)
        }
        guard capacity > 0 else { return CellLayout(barLines: barLines, chips: 0, more: 0) }
        let shownChips = min(chips, capacity - 1)
        return CellLayout(barLines: barLines, chips: shownChips, more: chips - shownChips + hiddenBars)
    }

    // MARK: Helpers

    private static func column(of day: Date, weekStart: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: weekStart, to: day).day ?? 0
    }

    /// All-day first, then by start, longer first, then id so the order is stable.
    private static func precedes(_ lhs: ScheduleEvent, _ rhs: ScheduleEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end > rhs.end }
        return lhs.id < rhs.id
    }
}
