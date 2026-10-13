import Foundation

/// Deterministic reply text. For create/modify the app writes the reply itself instead of asking
/// Gemini for a second turn — one model round trip per utterance (~1 s saved on every input).
///
/// Chat renders structured data where it has it (`Reply.addedEvents`, `Reply.agenda`, the plan card); the
/// strings here are the short text versions that Siri dialogs, notifications and VoiceOver use.
/// Times are always 24-hour ("18:30"); dates follow the language the UI strings resolved to.
enum ReplyFormatter {
    // MARK: Added / updated events

    /// "Added: Lunch with Andrew · Wed, Oct 14 · 13:00–14:00", or a count and one "• " line per event.
    static func confirmation(for events: [ScheduleEvent], clock: WallClock,
                             locale: Locale = ReplyFormatter.displayLocale) -> String {
        guard let first = events.first else { return "" }
        if events.count == 1 {
            return String(localized: "Added: \(first.title) · \(when(first, clock: clock, locale: locale))")
        }
        let lines = events.map { "• \($0.title) · \(when($0, clock: clock, locale: locale))" }
        return String(localized: "Added \(events.count) events:") + "\n" + lines.joined(separator: "\n")
    }

    static func updated(_ event: ScheduleEvent?, clock: WallClock, locale: Locale = ReplyFormatter.displayLocale) -> String {
        guard let event else { return String(localized: "Updated.") }
        return String(localized: "Updated: \(event.title) · \(when(event, clock: clock, locale: locale))")
    }

    static func conflicts(_ created: [ScheduleEvent], against existing: [ScheduleEvent]) -> String? {
        let clashes = created.flatMap { new in existing.filter { $0.overlaps(new) }.map { "\(new.title) ↔ \($0.title)" } }
        guard !clashes.isEmpty else { return nil }
        return "⚠️ " + String(localized: "Overlaps: \(clashes.prefix(3).joined(separator: ", "))")
    }

    /// Kept for callers that predate `when`; same output.
    static func stamp(_ event: ScheduleEvent, clock: WallClock) -> String {
        when(event, clock: clock)
    }

    // MARK: Deleting

    static func deletePrompt(_ summary: String) -> String {
        String(localized: "Delete \(summary)? Tap Confirm.")
    }

    /// Stands in for event titles when none are known.
    static func itemCount(_ count: Int) -> String {
        String(localized: "\(count) items")
    }

    // MARK: Agenda

    static var nothingScheduled: String { String(localized: "Nothing scheduled") }

    static var allDayLabel: String { String(localized: "All day") }

    /// Text version of the agenda card: its title, then "• 12:30  Lunch" rows, grouped under day labels when
    /// the range spans several days, and "+N more" past `limit` rows.
    static func agenda(_ digest: AgendaDigest, clock: WallClock,
                       locale: Locale = ReplyFormatter.displayLocale, limit: Int = 8) -> String {
        var lines = [digest.title]
        guard !digest.events.isEmpty else {
            lines.append(nothingScheduled)
            return lines.joined(separator: "\n")
        }
        let calendar = clock.calendar
        let groupsByDay = dayCount(of: digest.range, clock: clock) > 1
        var currentDay: Date?
        for event in digest.events.prefix(limit) {
            let day = calendar.startOfDay(for: max(event.start, digest.range.start))
            if groupsByDay, day != currentDay {
                lines.append(dayLabel(day, clock: clock, locale: locale))
                currentDay = day
            }
            lines.append("• " + agendaRow(event, clock: clock))
        }
        if digest.events.count > limit {
            lines.append(String(localized: "+\(digest.events.count - limit) more"))
        }
        return lines.joined(separator: "\n")
    }

    /// Rows only, without a title; kept for callers that predate `AgendaDigest`.
    static func agenda(_ events: [ScheduleEvent], clock: WallClock) -> String {
        guard !events.isEmpty else { return nothingScheduled }
        return events.prefix(8).map { "• " + agendaRow($0, clock: clock) }.joined(separator: "\n")
    }

    /// "12:30  Lunch" (two spaces, so rows line up in a monospaced-digit font); all-day "All day  Holiday".
    static func agendaRow(_ event: ScheduleEvent, clock: WallClock) -> String {
        "\(event.isAllDay ? allDayLabel : clockTime(event.start, clock: clock))  \(event.title)"
    }

    /// The agenda header: "Today · Thu, Oct 15" / "今天 · 10月15日（週四）" for one day,
    /// "This week · Oct 11 – Oct 17" for the current week, "Oct 11 – Oct 20" for other ranges.
    static func agendaTitle(for range: DateInterval, now: Date, clock: WallClock,
                            locale: Locale = ReplyFormatter.displayLocale) -> String {
        let calendar = clock.calendar
        let first = calendar.startOfDay(for: range.start)
        let days = dayCount(of: range, clock: clock)
        if days == 1 {
            let label = dayLabel(first, clock: clock, locale: locale)
            guard let relative = relativeDayName(first, now: now, clock: clock) else { return label }
            return relative + " · " + label
        }
        let last = calendar.date(byAdding: .day, value: days - 1, to: first) ?? first
        let span = shortDate(first, clock: clock, locale: locale) + " – " + shortDate(last, clock: clock, locale: locale)
        if days == 7, calendar.dateInterval(of: .weekOfYear, for: now)?.start == first {
            return String(localized: "This week") + " · " + span
        }
        return span
    }

    // MARK: Dates and times

    /// "07:30": 24-hour in the clock's time zone, whatever the device's 12/24-hour setting.
    static func clockTime(_ date: Date, clock: WallClock) -> String {
        let parts = clock.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "13:00–14:00".
    static func timeRange(_ event: ScheduleEvent, clock: WallClock) -> String {
        clockTime(event.start, clock: clock) + "–" + clockTime(event.end, clock: clock)
    }

    /// "Wed, Oct 14" (en_US) / "10月14日（週三）" (Chinese).
    static func dayLabel(_ date: Date, clock: WallClock, locale: Locale = ReplyFormatter.displayLocale) -> String {
        if isChinese(locale) {
            let weekday = date.formatted(style(locale, clock).weekday(.abbreviated))
            return shortDate(date, clock: clock, locale: locale) + "（" + weekday + "）"
        }
        return date.formatted(style(locale, clock).weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Oct 14" / "10月14日".
    static func shortDate(_ date: Date, clock: WallClock, locale: Locale = ReplyFormatter.displayLocale) -> String {
        date.formatted(style(locale, clock).month(.abbreviated).day())
    }

    /// When an event happens, for confirmation rows: "Wed, Oct 14 · 13:00–14:00" / "10月14日（週三）13:00–14:00";
    /// all-day "Wed, Oct 14 · All day"; an all-day span "Wed, Oct 14 – Fri, Oct 16".
    static func when(_ event: ScheduleEvent, clock: WallClock, locale: Locale = ReplyFormatter.displayLocale) -> String {
        let day = dayLabel(event.start, clock: clock, locale: locale)
        guard event.isAllDay else { return dayAndTime(day, timeRange(event, clock: clock), locale: locale) }
        let calendar = clock.calendar
        let firstDay = calendar.startOfDay(for: event.start)
        // All-day ends are exclusive: an event on Oct 14 ends at Oct 15 00:00.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: event.end).map { calendar.startOfDay(for: $0) } ?? firstDay
        if lastDay > firstDay {
            return day + " – " + dayLabel(lastDay, clock: clock, locale: locale)
        }
        return dayAndTime(day, allDayLabel, locale: locale)
    }

    /// "Today" / "Tomorrow" / "Yesterday", nil for other days.
    static func relativeDayName(_ day: Date, now: Date, clock: WallClock) -> String? {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: now)
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day ?? .min {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default: return nil
        }
    }

    /// The locale dates are written in: the language the UI strings resolved to (en or zh-Hant), keeping the
    /// device's region when its language matches, so a phone in another language gets English dates inside
    /// English sentences.
    static var displayLocale: Locale {
        let uiIsChinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        let device = Locale.current
        if device.language.languageCode?.identifier == (uiIsChinese ? "zh" : "en") { return device }
        return Locale(identifier: uiIsChinese ? "zh_Hant_TW" : "en_US")
    }

    static func isChinese(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    /// Chinese closes the day label with "）", so the time follows directly; English separates them with " · ".
    private static func dayAndTime(_ day: String, _ time: String, locale: Locale) -> String {
        isChinese(locale) ? day + time : day + " · " + time
    }

    private static func style(_ locale: Locale, _ clock: WallClock) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: clock.calendar, timeZone: clock.timeZone)
    }

    /// Calendar days touched by `range`, whose end is exclusive (at least 1).
    private static func dayCount(of range: DateInterval, clock: WallClock) -> Int {
        let calendar = clock.calendar
        let first = calendar.startOfDay(for: range.start)
        let whole = calendar.dateComponents([.day], from: first, to: range.end).day ?? 1
        let boundary = calendar.date(byAdding: .day, value: whole, to: first) ?? range.end
        return max(1, boundary < range.end ? whole + 1 : whole)
    }

    // MARK: Draft plan review

    /// Follows `summary_for_user` whenever a plan (or a revision) is shown for review.
    static var planReviewPrompt: String {
        String(localized: "Tap Add to put it in your calendar, or Keep editing to change it.")
    }

    /// Asked after "Keep editing", with `planEditSuggestions` as one-tap answers.
    static var planEditQuestion: String { String(localized: "What would you like to change?") }

    static var planEditSuggestions: [String] {
        [String(localized: "Change the training days"),
         String(localized: "Change the time"),
         String(localized: "Make sessions shorter"),
         String(localized: "Start on a different date")]
    }

    static var planDiscarded: String {
        String(localized: "Draft dropped. Nothing was added to your calendar.")
    }

    static func planAdded(_ title: String) -> String {
        String(localized: "Added “\(title)” to Google Calendar.")
    }
}
