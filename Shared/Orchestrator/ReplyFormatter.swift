import Foundation

/// Deterministic confirmations. For create/modify the app writes the reply itself instead of asking
/// Gemini for a second turn — one model round trip per utterance (~1 s saved on every input).
enum ReplyFormatter {
    static func confirmation(for events: [ScheduleEvent], clock: WallClock) -> String {
        guard let first = events.first else { return "" }
        if events.count == 1 {
            return String(localized: "Schedule set to Google Calendar on \(stamp(first, clock: clock))")
        }
        let lines = events.map { "• \($0.title) — \(stamp($0, clock: clock))" }
        return String(localized: "\(events.count) events set to Google Calendar:") + "\n" + lines.joined(separator: "\n")
    }

    static func updated(_ event: ScheduleEvent?, clock: WallClock) -> String {
        guard let event else { return String(localized: "Updated.") }
        return String(localized: "Updated: \(event.title) — \(stamp(event, clock: clock))")
    }

    static func conflicts(_ created: [ScheduleEvent], against existing: [ScheduleEvent]) -> String? {
        let clashes = created.flatMap { new in existing.filter { $0.overlaps(new) }.map { "\(new.title) ↔ \($0.title)" } }
        guard !clashes.isEmpty else { return nil }
        return "⚠️ " + String(localized: "Overlaps: \(clashes.prefix(3).joined(separator: ", "))")
    }

    static func agenda(_ events: [ScheduleEvent], clock: WallClock) -> String {
        guard !events.isEmpty else { return String(localized: "Nothing scheduled — you're free.") }
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = clock.timeZone
        return events.prefix(8).map { event in
            event.isAllDay ? "• \(event.title) (all day)" : "• \(event.start.formatted(timeStyle)) \(event.title)"
        }.joined(separator: "\n")
    }

    // MARK: Draft plan review

    /// Follows `summary_for_user` whenever a plan (or a revision) is shown for review.
    static var planReviewPrompt: String {
        String(localized: "Take a look: tap Add to put it in your calendar, or Keep editing to change something.")
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
        String(localized: "OK, I dropped the draft plan. Nothing was added to your calendar.")
    }

    static func stamp(_ event: ScheduleEvent, clock: WallClock) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)
        style.timeZone = clock.timeZone
        return event.start.formatted(style)
    }
}
