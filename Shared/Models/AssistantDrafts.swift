import Foundation

// Typed mirrors of the Gemini function declarations in Shared/AI/FunctionDeclarations.json.
// Decoded with `.convertFromSnakeCase`. Enum-like fields stay `String` and are validated by the mapper,
// so one unexpected value from the model degrades gracefully instead of failing the whole decode.
// The plan types are also Encodable (`.convertToSnakeCase`) so the offline demo can produce the same args JSON.

enum AssistantFunction: String, CaseIterable, Sendable {
    case createEvents = "create_events"
    case createLongTermPlan = "create_long_term_plan"
    case modifyEvent = "modify_event"
    case deleteEvents = "delete_events"
    case querySchedule = "query_schedule"
    case replyToUser = "reply_to_user"
    case confirmPlan = "confirm_plan"
}

// MARK: create_events

struct CreateEventsArgs: Decodable, Sendable {
    var events: [EventDraft]
}

struct EventDraft: Decodable, Sendable {
    var title: String
    var start: String                 // "YYYY-MM-DDTHH:mm" or "YYYY-MM-DD" (all-day)
    var end: String?
    var durationMinutes: Int?
    var allDay: Bool?
    var kind: String?                 // event | task | deadline | routine
    var location: String?
    var addVideoConference: Bool?
    var attendees: [String]?
    var recurrence: RecurrenceDraft?
    var reminderMinutes: [Int]?
    var notes: String?
}

struct RecurrenceDraft: Decodable, Sendable {
    var frequency: String             // DAILY | WEEKLY | MONTHLY | YEARLY
    var interval: Int?
    var byWeekday: [String]?          // MO TU WE TH FR SA SU
    var until: String?                // YYYY-MM-DD (inclusive, local)
    var count: Int?
}

// MARK: create_long_term_plan

struct LongTermPlanArgs: Codable, Sendable {
    var goal: String
    var planTitle: String
    var startDate: String
    var endDate: String
    var summaryForUser: String
    var phases: [PhaseDraft]
    var sessions: [SessionDraft]
    var dailyNudge: NudgeDraft?
    var milestones: [MilestoneDraft]?
    var assumptions: [String]?
}

struct PhaseDraft: Codable, Sendable {
    var name: String
    var startDate: String
    var endDate: String
    var focus: String?
}

/// Flattened (phase_index instead of nesting) to keep the schema shallow — deep nesting measurably
/// raises malformed-call rates and can hit schema-complexity limits.
struct SessionDraft: Codable, Sendable {
    var phaseIndex: Int
    var title: String
    var weekdays: [String]
    var startTime: String             // "HH:mm"
    var durationMinutes: Int
    var notes: String?
}

struct NudgeDraft: Codable, Sendable {
    var time: String                  // "HH:mm"
    var message: String
}

struct MilestoneDraft: Codable, Sendable {
    var date: String
    var title: String
}

// MARK: modify / delete / query / reply

struct ModifyEventArgs: Decodable, Sendable {
    var eventId: String
    var scope: String?                // this_occurrence | all_occurrences
    var changes: EventChangesDraft
}

struct EventChangesDraft: Decodable, Sendable {
    var title: String?
    var start: String?
    var end: String?
    var durationMinutes: Int?
    var location: String?
    var reminderMinutes: [Int]?
    var notes: String?
}

struct DeleteEventsArgs: Decodable, Sendable {
    var eventIds: [String]?
    var planId: String?
    var scope: String?
}

struct QueryScheduleArgs: Decodable, Sendable {
    var rangeStart: String
    var rangeEnd: String?
    var view: String?                 // day | week | month
}

struct ReplyToUserArgs: Decodable, Sendable {
    var message: String
    var needsClarification: Bool?
    var suggestedReplies: [String]?
}

// MARK: confirm_plan

struct ConfirmPlanArgs: Decodable, Sendable {
    var decision: String              // add | discard
}
