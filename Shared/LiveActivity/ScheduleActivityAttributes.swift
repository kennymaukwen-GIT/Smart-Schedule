import ActivityKit
import Foundation

/// Live Activity payload. Hard limits that shape this type:
/// • ActivityKit content (static + dynamic) must stay under 4 KB — chips are truncated by the builder.
/// • Views cannot do I/O at render time; everything shown must be in this state.
/// • Only Button/Toggle (App Intents) and Link are interactive — no TextField, no scrolling.
struct ScheduleActivityAttributes: ActivityAttributes {
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
