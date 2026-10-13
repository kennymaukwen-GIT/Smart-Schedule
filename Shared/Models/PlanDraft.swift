import Foundation

/// A long-term plan the assistant designed but has NOT written to the calendar yet.
///
/// Plans are reviewed before they land: the draft is shown with "Add" and "Keep editing"; each change request
/// produces a complete new revision with the same `id`, and only "Add" writes it (as `planID == id`).
/// Stored in the App Group (`SharedStore.pendingPlan`) so the app, Siri and the notification extension share it.
///
/// Compiled into every target, so it depends on Foundation and `ScheduleEvent` only.
struct PlanDraft: Codable, Hashable, Sendable, Identifiable {
    /// Every `previewEvents` id starts with this, so a preview can never be mistaken for a real event.
    static let eventIDPrefix = "draft-"

    var id: String                // the planID used when committed; the same across revisions
    var revision: Int             // 1, 2, 3…
    var utterance: String         // the request that produced revision 1 (provenance line)
    var goal: String
    var title: String             // plan_title
    var startDate: Date           // start of the first day
    var endDate: Date             // start of the last day (inclusive)
    var summary: String           // summary_for_user
    var phases: [Phase]
    var sessions: [Session]
    var milestones: [Milestone]
    var nudge: Nudge?
    var assumptions: [String]
    var previewEvents: [ScheduleEvent]   // expanded occurrences for the calendars; never written anywhere
    var writeCount: Int                  // Google writes on Add (RRULE series + milestones)
    var argsJSON: Data                   // the raw create_long_term_plan args, re-decoded on commit

    struct Phase: Codable, Hashable, Sendable {
        var name: String
        var start: Date
        var end: Date             // start of the last day (inclusive)
        var focus: String?
    }

    struct Session: Codable, Hashable, Sendable {
        var phaseIndex: Int
        var title: String
        var weekdays: [String]    // MO TU WE TH FR SA SU, Monday first
        var startTime: String     // "HH:mm"
        var durationMinutes: Int
        var notes: String?
    }

    struct Milestone: Codable, Hashable, Sendable {
        var date: Date
        var title: String
    }

    struct Nudge: Codable, Hashable, Sendable {
        var hour: Int
        var minute: Int
        var message: String
    }
}

extension ScheduleEvent {
    /// True for the preview occurrences of a `PlanDraft`, which exist only on the review card.
    var isDraft: Bool { id.hasPrefix(PlanDraft.eventIDPrefix) }
}
