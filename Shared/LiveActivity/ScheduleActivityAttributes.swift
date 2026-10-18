import ActivityKit
import Foundation

/// Live Activity payload. Hard limits that shape this type:
/// • ActivityKit content (static + dynamic) must stay under 4 KB — titles are truncated by the builder.
/// • Views cannot do I/O at render time; everything shown must be in this state.
/// • Only Button/Toggle (App Intents) and Link are interactive — no TextField, no scrolling.
///
/// One activity per event about to start (`ActivityScheduler`). A push-to-start payload (iOS 18; only with
/// `AppConstants.pushToStartEnabled`, off in version 1.0) carries this type's JSON from the default `JSONEncoder`:
/// ActivityKit decodes pushed content with its default strategies.
struct ScheduleActivityAttributes: ActivityAttributes {
    /// The event this activity counts down to; `ActivityScheduler` finds the activity by it after the event changes.
    /// nil = the always-on activity of an older build, which the scheduler ends.
    var eventID: String? = nil

    struct ContentState: Codable, Hashable {
        var headline: String              // "Online meeting on the product quality"
        var shortHeadline: String         // "Online meeting" (compact island)
        var eventID: String?
        var countdownFrom: Date           // build time; guarantees from <= target for Text(timerInterval:)
        var countdownTarget: Date?        // next start, or current end if already in progress
        var isInProgress: Bool
        var weekStart: Date
        var todayIndex: Int
        /// Always 7, starting on `firstWeekday`. No view shows them since the island's week strip went (2026-10-18);
        /// still built and required when decoding, so every payload an older build wrote stays readable.
        var days: [DayDigest]
        /// The assistant's last reply. No view shows it any more.
        var lastAssistantLine: String?
        /// Settings › "Week starts on" (1 = Sunday, 2 = Monday) the week in `days` starts on; nil (older payloads) =
        /// Sunday.
        var firstWeekday: Int? = nil
        /// When the event starts (the build time when there is none). Older payloads: `countdownTarget`, else
        /// `countdownFrom`.
        var eventStart: Date = .distantPast
        /// When the event ends: once the start has passed (the content is stale), the island counts down to it.
        var eventEnd: Date? = nil
        /// The event's place, on the line under the headline: trimmed, its lines joined, at most 40 characters. nil
        /// when it has none (and in older payloads).
        var location: String? = nil
        /// "Up next": what comes after the event the same day, soonest first, at most 3 (`upNextMore` counts the rest
        /// of that day); with nothing more that day, the first item the next day alone (`isTomorrow`). [] = nothing
        /// after the event that day or the next. nil = no event or an older payload. No view shows it since the
        /// countdown bar replaced the list (owner's choice, 2026-10-18), so a change here updates no activity; still
        /// built, so the payloads stay as they were and the list can come back.
        var upNext: [UpNextItem]? = nil
        /// How many more items that day `upNext` leaves out (the list's "+N"); 0 when it holds them all. nil = no
        /// event, or an older payload. Not shown, like `upNext`.
        var upNextMore: Int? = nil
        /// Settings › "Time zone" the builder grouped the days in, so the times on screen are in it too (views format
        /// them at render time). nil (older payloads) = the iPhone's.
        var timeZoneIdentifier: String? = nil
        /// The ended activity's last look (`ActivityScheduler`'s final content): its countdown reads "Ended" instead
        /// of a dash, so a card left on the Lock Screen for its last minutes is not taken for a running one.
        /// nil (every other state and older payloads) = not ended.
        var hasEnded: Bool? = nil
        /// When the activity appeared: its trigger, the Settings lead (30, 15, 10 or 5 minutes) before the start, set
        /// by `ActivityPlanner.state(for:…)`; a running activity keeps the one it shows through updates
        /// (`ActivityPlanner.keptProgressStart`). The countdown bar runs from here to the start (`progressRange`).
        /// Not `countdownFrom`, which is the build time and moves with every update. nil (older payloads, and states
        /// built without a trigger) = the bar starts at `countdownFrom`.
        var progressStart: Date? = nil

        enum CodingKeys: String, CodingKey {
            case headline, shortHeadline, eventID, countdownFrom, countdownTarget, isInProgress, weekStart, todayIndex
            case days, lastAssistantLine, firstWeekday, eventStart, eventEnd
            case location, upNext, upNextMore, timeZoneIdentifier, hasEnded, progressStart
        }
    }

    /// One item of "Up next" (not shown since 2026-10-18): its start time, its colour, whether it is a task, and its
    /// title, truncated by the builder.
    struct UpNextItem: Codable, Hashable {
        var title: String
        var start: Date
        var colorHex: String
        var isTask: Bool
        /// On the day after the event: the row reads "Tomorrow 09:00".
        var isTomorrow: Bool
    }

    struct DayDigest: Codable, Hashable {
        var dayNumber: Int
        var chips: [Chip]
        var overflow: Int
    }

    struct Chip: Codable, Hashable {
        var title: String
        var colorHex: String
        var isTask: Bool
    }
}

// In an extension, so the memberwise initializer stays.
extension ScheduleActivityAttributes.ContentState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decode(String.self, forKey: .headline)
        shortHeadline = try c.decode(String.self, forKey: .shortHeadline)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        countdownFrom = try c.decode(Date.self, forKey: .countdownFrom)
        countdownTarget = try c.decodeIfPresent(Date.self, forKey: .countdownTarget)
        isInProgress = try c.decode(Bool.self, forKey: .isInProgress)
        weekStart = try c.decode(Date.self, forKey: .weekStart)
        todayIndex = try c.decode(Int.self, forKey: .todayIndex)
        days = try c.decode([ScheduleActivityAttributes.DayDigest].self, forKey: .days)
        lastAssistantLine = try c.decodeIfPresent(String.self, forKey: .lastAssistantLine)
        firstWeekday = try c.decodeIfPresent(Int.self, forKey: .firstWeekday)
        eventStart = try c.decodeIfPresent(Date.self, forKey: .eventStart) ?? countdownTarget ?? countdownFrom
        eventEnd = try c.decodeIfPresent(Date.self, forKey: .eventEnd)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        upNext = try c.decodeIfPresent([ScheduleActivityAttributes.UpNextItem].self, forKey: .upNext)
        upNextMore = try c.decodeIfPresent(Int.self, forKey: .upNextMore)
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        hasEnded = try c.decodeIfPresent(Bool.self, forKey: .hasEnded)
        progressStart = try c.decodeIfPresent(Date.self, forKey: .progressStart)
    }

    /// What the countdown shows: to the start, or to the end once the event is under way — because the state says so
    /// or because its stale date (the start) has passed with no update from the app. nil = nothing to count.
    func countdownRange(isStale: Bool) -> ClosedRange<Date>? {
        if countsToTheEndOnceStale(isStale), let end = eventEnd {
            return eventStart...end
        }
        guard let target = countdownTarget, target > countdownFrom else { return nil }
        return countdownFrom...target
    }

    /// The stale switch of `countdownRange`: the start has passed with no update from the app, so the countdown runs
    /// from the start to the end instead.
    private func countsToTheEndOnceStale(_ isStale: Bool) -> Bool {
        guard isStale, !isInProgress, let end = eventEnd else { return false }
        return end > eventStart
    }

    /// The countdown bar under the headline shows only the time until the start (owner, 2026-10-18: 「就單純是距離
    /// 行程開始的時間」). Before the start it fills (`ProgressView(timerInterval:countsDown: false)`, which moves by
    /// itself with no update from the app) from when the activity appeared (`progressStart`, its trigger) to the start,
    /// ending where the capsule's countdown ends; without a usable `progressStart` (an older payload, or one not before
    /// the start) it fills from the countdown's own start (`countdownFrom`, the build time). nil once the event is under
    /// way (the bar is full: `progressIsFull`), once ended (`hasEnded`), with no event, or with no countdown at all.
    /// The lower bound is always before the upper.
    func progressRange(isStale: Bool) -> ClosedRange<Date>? {
        guard eventID != nil, hasEnded != true, !progressIsFull(isStale: isStale),
              let countdown = countdownRange(isStale: isStale) else { return nil }
        let end = countdown.upperBound
        guard let start = progressStart, start < end else { return countdown }
        return start...end
    }

    /// Whether the countdown bar is full: the event is under way (`isInProgress`, or the content went stale at the
    /// start with an end, as `countdownRange` switches), so the time until the start has run out. It stays full until
    /// the activity's last look ("Ended", no bar). False with no event.
    func progressIsFull(isStale: Bool) -> Bool {
        eventID != nil && hasEnded != true && (isInProgress || countsToTheEndOnceStale(isStale))
    }

    /// The zone the times on screen are shown in: the builder's (Settings › "Time zone"), else the iPhone's.
    var displayTimeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Hour and minute in `displayTimeZone`, in `locale`'s style (12- or 24-hour, as the iPhone is set).
    func timeStyle(locale: Locale = .autoupdatingCurrent) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, timeZone: displayTimeZone).hour().minute()
    }

    /// The line under the headline: "08:15–08:45 · St Mary's School" (the start alone once the end is gone, in the
    /// ended activity's last look). Formatted when shown, so it follows the iPhone's 12/24-hour setting. nil when
    /// there is no event.
    func detailLine(locale: Locale = .autoupdatingCurrent) -> String? {
        guard eventID != nil else { return nil }
        let style = timeStyle(locale: locale)
        var time = eventStart.formatted(style)
        if let end = eventEnd, end > eventStart {
            time += "–" + end.formatted(style)
        }
        guard let location, !location.isEmpty else { return time }
        return time + " · " + location
    }

    /// Whether the island and the Lock Screen would look the same with `other`, so a running activity needs no
    /// update: the headlines, the line under the headline (`hasSameDetailLine`), the countdown (`countdownTarget`,
    /// `isInProgress`) and where its bar starts (`progressStart`). Leaves out what no view shows: the build time
    /// (`countdownFrom`: the timer counts to the same target from any earlier start, and the bar starts at
    /// `progressStart`), "Up next" (`upNext`, `upNextMore`), the week digest (`days`, `weekStart`, `todayIndex`,
    /// `firstWeekday`) and the assistant's last line.
    func looksTheSame(as other: Self) -> Bool {
        guard headline == other.headline, shortHeadline == other.shortHeadline, eventID == other.eventID else {
            return false
        }
        guard countdownTarget == other.countdownTarget, isInProgress == other.isInProgress,
              progressStart == other.progressStart else { return false }
        return hasSameDetailLine(as: other)
    }

    /// Whether the line under the headline (`detailLine`) reads the same: the event's start and end, its place and
    /// the zone the times are shown in.
    func hasSameDetailLine(as other: Self) -> Bool {
        eventStart == other.eventStart && eventEnd == other.eventEnd && location == other.location
            && timeZoneIdentifier == other.timeZoneIdentifier
    }

    /// Whether `upNext`, `upNextMore`, the place and the time zone are the same. No longer used by the scheduler:
    /// since the countdown bar replaced the "Up next" list (2026-10-18) a change after the event replaces no
    /// scheduled activity (`ActivityPlanner.scheduledActivityMatches`).
    func hasSameUpNext(as other: Self) -> Bool {
        guard location == other.location, timeZoneIdentifier == other.timeZoneIdentifier else { return false }
        return upNext == other.upNext && upNextMore == other.upNextMore
    }
}

extension ScheduleActivityAttributes.DayDigest {
    /// What one day of a week view shows in at most `rows` rows: its first chips, then "+N" in the last row for every
    /// event not shown (`more`). The island used it for its week strip (two rows a day), gone since 2026-10-18.
    func visibleRows(_ rows: Int) -> (chips: [ScheduleActivityAttributes.Chip], more: Int) {
        let total = chips.count + overflow
        let shown = Array(chips.prefix(total <= rows ? rows : max(0, rows - 1)))
        return (shown, total - shown.count)
    }
}
