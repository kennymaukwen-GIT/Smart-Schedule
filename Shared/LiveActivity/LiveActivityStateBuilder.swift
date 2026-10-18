import Foundation

enum LiveActivityStateBuilder {
    private static let byteBudget = 3_200 // headroom under ActivityKit's 4 KB cap
    /// Rows of "Up next" the island and the Lock Screen have room for (their height budget, `ScheduleLiveActivity`).
    static let upNextLimit = 3
    /// Longest "Up next" title kept: about what one row holds at 12 pt on the widest iPhones. A longer one ends in
    /// "…" (`clipped`); a narrower iPhone's row cuts one too wide for it with its own "…".
    static let upNextTitleLength = 48
    /// Longest place kept for the line under the headline.
    static let locationLength = 40
    /// Longest headline kept: more than one line of the island or the Lock Screen holds (each ends a longer one with
    /// "…"), and a bound on the payload however long the event's title is.
    static let headlineLength = 80

    /// How hard the payload is squeezed, mildest first: the first level that fits the byte budget is used. What no
    /// view shows goes first: the week digest (`days`), then the assistant's last line, so what is on screen never
    /// depends on the assistant's last reply. Only then do the "Up next" titles and the place shrink.
    private struct Squeeze {
        let chipsPerDay: Int
        let chipTitleLength: Int
        let upNextTitleLength: Int
        let locationLength: Int
        let keepsAssistantLine: Bool
    }

    private static let squeezes = [
        Squeeze(chipsPerDay: 2, chipTitleLength: 10, upNextTitleLength: upNextTitleLength, locationLength: locationLength,
                keepsAssistantLine: true),
        Squeeze(chipsPerDay: 1, chipTitleLength: 8, upNextTitleLength: upNextTitleLength, locationLength: locationLength,
                keepsAssistantLine: true),
        Squeeze(chipsPerDay: 1, chipTitleLength: 5, upNextTitleLength: upNextTitleLength, locationLength: locationLength,
                keepsAssistantLine: true),
        Squeeze(chipsPerDay: 0, chipTitleLength: 0, upNextTitleLength: upNextTitleLength, locationLength: locationLength,
                keepsAssistantLine: true),
        Squeeze(chipsPerDay: 0, chipTitleLength: 0, upNextTitleLength: upNextTitleLength, locationLength: locationLength,
                keepsAssistantLine: false),
        Squeeze(chipsPerDay: 0, chipTitleLength: 0, upNextTitleLength: 28, locationLength: locationLength,
                keepsAssistantLine: false),
        Squeeze(chipsPerDay: 0, chipTitleLength: 0, upNextTitleLength: 16, locationLength: locationLength,
                keepsAssistantLine: false),
        Squeeze(chipsPerDay: 0, chipTitleLength: 0, upNextTitleLength: 10, locationLength: 20,
                keepsAssistantLine: false)
    ]

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
    /// push starts it (iOS 18), so "Up next" and the countdown are right then, not when it was planned.
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
        let eventPlace = next.flatMap { place($0.location) }
        let following = next.map { upNext(after: $0, events: events, now: now, calendar: calendar) }
        let assistantLine = lastLine.map { String($0.prefix(60)) }

        var state = ScheduleActivityAttributes.ContentState(
            headline: next.map { clipped($0.title, headlineLength) } ?? String(localized: "Nothing next — type a plan"),
            shortHeadline: String((next?.title ?? "Smart Schedules").prefix(16)),
            eventID: next?.id,
            countdownFrom: now,
            countdownTarget: next.map { $0.start > now ? $0.start : $0.end },
            isInProgress: next.map { $0.start <= now } ?? false,
            weekStart: weekStart,
            todayIndex: min(max(todayIndex, 0), 6),
            days: [],
            lastAssistantLine: assistantLine,
            firstWeekday: calendar.firstWeekday,
            eventStart: next?.start ?? now,
            eventEnd: next?.end,
            location: eventPlace,
            upNext: nil,
            upNextMore: following.map { $0.more },
            timeZoneIdentifier: clock.timeZone.identifier
        )

        var fits = false
        for squeeze in squeezes {
            state.days = (0..<7).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: weekStart)!
                let interval = DateInterval(start: day, duration: 86_400)
                let dayEvents = events.filter { $0.intersects(interval) }.sorted { $0.start < $1.start }
                return ScheduleActivityAttributes.DayDigest(
                    dayNumber: calendar.component(.day, from: day),
                    chips: dayEvents.prefix(squeeze.chipsPerDay).map {
                        ScheduleActivityAttributes.Chip(title: String($0.title.prefix(squeeze.chipTitleLength)),
                                                        colorHex: $0.colorHex, isTask: $0.kind == .task)
                    },
                    overflow: max(0, dayEvents.count - squeeze.chipsPerDay)
                )
            }
            state.upNext = following.map { found in
                found.items.map {
                    ScheduleActivityAttributes.UpNextItem(title: clipped($0.title, squeeze.upNextTitleLength),
                                                          start: $0.start, colorHex: $0.colorHex,
                                                          isTask: $0.kind == .task, isTomorrow: found.isTomorrow)
                }
            }
            state.location = eventPlace.map { clipped($0, squeeze.locationLength) }
            state.lastAssistantLine = squeeze.keepsAssistantLine ? assistantLine : nil
            if ((try? JSONEncoder().encode(state))?.count ?? 0) <= byteBudget {
                fits = true
                break
            }
        }
        if !fits {
            // Last resort, for characters of many Unicode scalars each (long emoji sequences, stacked accents), which
            // a count of characters does not bound: cut by scalars, which bounds the bytes, and leave out the place.
            state.headline = scalarPrefix(state.headline, 60)
            state.shortHeadline = scalarPrefix(state.shortHeadline, 16)
            state.upNext = state.upNext?.map { original in
                var row = original
                row.title = scalarPrefix(row.title, 10)
                return row
            }
            state.location = nil
        }
        return state
    }

    /// `text` cut to at most `length` characters. A cut one ends in "…" (counted in `length`), so it does not read
    /// like a typo when the row has room for more.
    static func clipped(_ text: String, _ length: Int) -> String {
        guard text.count > length else { return text }
        guard length > 1 else { return String(text.prefix(max(0, length))) }
        return String(text.prefix(length - 1)).trimmingCharacters(in: cutEnds) + "…"
    }

    /// Left off the end of a cut text before its "…".
    private static let cutEnds = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；"))

    private static func scalarPrefix(_ text: String, _ count: Int) -> String {
        guard text.unicodeScalars.count > count else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(count)))
    }

    /// "Up next" after `next`: timed, booked, unfinished items other than `next` that start no earlier than it, on
    /// its day (the day under way once it is in progress), soonest first (then by title), not yet over at `now`; at
    /// most `upNextLimit`, `more` counting the rest of that day. With none that day: the first such item the next day
    /// alone, `isTomorrow`. `events` are the visible ones, drafts already removed.
    static func upNext(after next: ScheduleEvent,
                       events: [ScheduleEvent],
                       now: Date,
                       calendar: Calendar) -> (items: [ScheduleEvent], more: Int, isTomorrow: Bool) {
        let day = calendar.startOfDay(for: max(next.start, now))
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: nextDay) else { return ([], 0, false) }
        let candidates = events
            .filter { !$0.isAllDay && !$0.isDraft && !$0.isCompleted && $0.id != next.id }
            .filter { $0.start >= next.start && ($0.end > now || $0.start >= now) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let sameDay = candidates.filter { $0.start >= day && $0.start < nextDay }
        if !sameDay.isEmpty {
            let shown = Array(sameDay.prefix(upNextLimit))
            return (shown, sameDay.count - shown.count, false)
        }
        if let tomorrow = candidates.first(where: { $0.start >= nextDay && $0.start < dayAfter }) {
            return ([tomorrow], 0, true)
        }
        return ([], 0, false)
    }

    /// The place for the line under the headline: its lines trimmed and joined with ", ", at most `locationLength`
    /// characters (a cut one ends in "…"); nil when nothing is left.
    static func place(_ location: String?) -> String? {
        guard let location else { return nil }
        let joined = location
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let cut = clipped(joined, locationLength)
        return cut.isEmpty ? nil : cut
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
