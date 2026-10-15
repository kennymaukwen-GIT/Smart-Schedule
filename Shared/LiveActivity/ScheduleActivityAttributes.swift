import ActivityKit
import Foundation

/// Live Activity payload. Hard limits that shape this type:
/// • ActivityKit content (static + dynamic) must stay under 4 KB — chips are truncated by the builder.
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
        var days: [DayDigest]             // always 7, starting on `firstWeekday`
        var lastAssistantLine: String?
        /// Settings › "Week starts on" (1 = Sunday, 2 = Monday) for the week strip letters; nil (older payloads) = Sunday.
        var firstWeekday: Int? = nil
        /// When the event starts (the build time when there is none). Older payloads: `countdownTarget`, else
        /// `countdownFrom`.
        var eventStart: Date = .distantPast
        /// When the event ends: once the start has passed (the content is stale), the island counts down to it.
        var eventEnd: Date? = nil

        enum CodingKeys: String, CodingKey {
            case headline, shortHeadline, eventID, countdownFrom, countdownTarget, isInProgress, weekStart, todayIndex
            case days, lastAssistantLine, firstWeekday, eventStart, eventEnd
        }
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
    }

    /// What the countdown shows: to the start, or to the end once the event is under way — because the state says so
    /// or because its stale date (the start) has passed with no update from the app. nil = nothing to count.
    func countdownRange(isStale: Bool) -> ClosedRange<Date>? {
        if isStale, !isInProgress, let end = eventEnd, end > eventStart {
            return eventStart...end
        }
        guard let target = countdownTarget, target > countdownFrom else { return nil }
        return countdownFrom...target
    }
}
