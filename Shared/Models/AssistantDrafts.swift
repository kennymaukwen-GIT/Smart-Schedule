import Foundation

// Typed mirrors of the Gemini function declarations in Shared/AI/FunctionDeclarations.json.
// Decoded with `.convertFromSnakeCase`. Enum-like fields stay `String` and are validated by the mapper,
// so one unexpected value from the model degrades gracefully instead of failing the whole decode.
// The plan and create_events types are also Encodable (`.convertToSnakeCase`) so the offline demo can produce the
// same args JSON.

enum AssistantFunction: String, CaseIterable, Sendable {
    case createEvents = "create_events"
    case createLongTermPlan = "create_long_term_plan"
    case modifyEvent = "modify_event"
    case deleteEvents = "delete_events"
    case querySchedule = "query_schedule"
    case replyToUser = "reply_to_user"
    case confirmPlan = "confirm_plan"
    case updatePreferences = "update_preferences"
    /// Only in its own request (`ScheduleAssistant.suggestNotes`), never in conversation.
    case suggestEventNotes = "suggest_event_notes"

    /// What a chat turn may call: every function but `suggest_event_notes`.
    static var conversational: [AssistantFunction] {
        allCases.filter { $0 != .suggestEventNotes }
    }
}

// MARK: create_events

struct CreateEventsArgs: Codable, Sendable {
    var events: [EventDraft]
}

struct EventDraft: Codable, Sendable {
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
    /// Up to 4 things the event may need ("Bring passport"), offered as chips; never written to Google
    /// (`ScheduleEvent.suggestedNotes`).
    var suggestedNotes: [String]? = nil
}

struct RecurrenceDraft: Codable, Sendable {
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

// MARK: update_preferences

struct UpdatePreferencesArgs: Decodable, Sendable {
    struct Change: Decodable, Sendable {
        var key: String         // validated against PreferenceKey; unknown keys are rejected, not a decode failure
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }

        /// A number sent where the schema says string ("value": 120) still reads as "120".
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decode(String.self, forKey: .key)) ?? ""
            if let text = try? c.decode(String.self, forKey: .value) {
                value = text
            } else if let number = try? c.decode(Int.self, forKey: .value) {
                value = String(number)
            } else if let flag = try? c.decode(Bool.self, forKey: .value) {
                value = flag ? "on" : "off"
            } else {
                value = ""
            }
        }

        private enum CodingKeys: String, CodingKey { case key, value }
    }

    var changes: [Change]
    var summaryForUser: String

    init(changes: [Change], summaryForUser: String) {
        self.changes = changes
        self.summaryForUser = summaryForUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        changes = try c.decode([Change].self, forKey: .changes)
        summaryForUser = (try? c.decodeIfPresent(String.self, forKey: .summaryForUser)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case changes, summaryForUser }
}

// MARK: suggest_event_notes

/// `suggest_event_notes`: 2-4 items for one event. Tolerant: a missing `items` reads as none, a single string as one.
struct SuggestEventNotesArgs: Decodable, Sendable {
    var items: [String]
    var reason: String?

    init(items: [String], reason: String? = nil) {
        self.items = items
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? c.decodeIfPresent([String].self, forKey: .items) {
            items = list
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .items) {
            items = [single]
        } else {
            items = []
        }
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey { case items, reason }
}
