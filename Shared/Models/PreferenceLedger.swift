import Foundation

/// Where a preference change came from: shown under each line of "What the assistant remembers".
enum LedgerSource: Codable, Hashable, Sendable {
    case voice(utterance: String)   // "You said: “…”" (utterance trimmed to 80 characters)
    case learned                    // "Learned from your habits"
    case settings                   // "Changed in Settings"

    static let maxUtteranceLength = 80

    var label: String {
        switch self {
        case let .voice(utterance):
            let quoted = String(utterance.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxUtteranceLength))
            return String(localized: "You said: “\(quoted)”")
        case .learned:
            return String(localized: "Learned from your habits")
        case .settings:
            return String(localized: "Changed in Settings")
        }
    }

    /// The utterance cut to what the label shows, so stored receipts and ledger lines stay small.
    var trimmed: LedgerSource {
        guard case let .voice(utterance) = self else { return self }
        let clean = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        return .voice(utterance: String(clean.prefix(Self.maxUtteranceLength)))
    }

    // Flat JSON ({"type": "voice", "utterance": "…"}); an unknown type reads as `.settings`.
    private enum CodingKeys: String, CodingKey { case type, utterance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.preferenceValue(.type, default: "settings") {
        case "voice": self = .voice(utterance: c.preferenceValue(.utterance, default: ""))
        case "learned": self = .learned
        default: self = .settings
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .voice(utterance):
            try c.encode("voice", forKey: .type)
            try c.encode(utterance, forKey: .utterance)
        case .learned:
            try c.encode("learned", forKey: .type)
        case .settings:
            try c.encode("settings", forKey: .type)
        }
    }
}

/// One line of "What the assistant remembers". Invariant: at most one entry per key, and only for keys whose
/// current value differs from `AppPreferences()`. Changing a key back to its default removes its entry.
struct LedgerEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var key: PreferenceKey
    var value: String               // canonical value this change set
    var display: String             // localized display of `value` at change time
    var previousDisplay: String     // localized display of the value it replaced
    var source: LedgerSource
    var date: Date
}

struct PreferenceChange: Codable, Hashable, Sendable {
    var key: PreferenceKey
    var oldValue: String            // canonical
    var newValue: String            // canonical
    var oldDisplay: String
    var newDisplay: String
    /// The ledger entry this change replaced (restored by undo); nil when the key was at its default.
    var replacedEntry: LedgerEntry?

    /// Model-facing values without account emails (`AppPreferences.promptValue(canonical:for:)`). The update_preferences
    /// function response uses `CalendarAliases.promptValue(canonical:for:)`, which names a calendar as CALENDARS does.
    var oldPromptValue: String { AppPreferences.promptValue(canonical: oldValue, for: key) }
    var newPromptValue: String { AppPreferences.promptValue(canonical: newValue, for: key) }
}

/// What one voice command, Settings edit or accepted suggestion changed. Drives the "Settings updated" card and Undo.
struct PreferenceChangeReceipt: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var source: LedgerSource
    var changes: [PreferenceChange]

    /// True when any change needs `ReminderScheduler.reschedule()`.
    var affectsNotifications: Bool { changes.contains { $0.key.affectsNotifications } }
}

struct PreferenceChangeRequest: Codable, Hashable, Sendable {
    var key: PreferenceKey
    var value: String               // model-facing format of the update_preferences declaration
}

struct PreferenceRejection: Codable, Hashable, Sendable {
    var key: String                 // as received (may be unknown)
    var value: String
    var reason: String              // English, also sent back to Gemini
}

struct PreferenceApplyResult: Sendable {
    var receipt: PreferenceChangeReceipt?   // nil when nothing changed
    var rejected: [PreferenceRejection]
}

/// A resolved default_calendar value.
struct CalendarChoice: Hashable, Sendable {
    var ref: CalendarRef
    var label: String               // "My calendar | example@yourmail.com" (`CalendarInfo.promptLabel`, kept on this iPhone)
}

/// "You dismissed the 1-day-before reminder 5 times. Stop sending it?" Offered once per (kind, offset), applied only
/// after the user taps "Stop it".
struct LearnedSuggestion: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, accepted, declined }
    static let dismissThreshold = 5

    var id: UUID
    var kind: ScheduleEvent.Kind
    var offsetMinutes: Int          // for all-day: minutes before 00:00
    var isAllDay: Bool
    var dismissCount: Int
    var createdAt: Date
    var status: Status
    var shownInChat: Bool

    /// "event.1440", "deadline.60", "event.allday": one suggestion per key, ever.
    var streakKey: String { Self.streakKey(kind: kind, offsetMinutes: offsetMinutes, isAllDay: isAllDay) }

    static func streakKey(kind: ScheduleEvent.Kind, offsetMinutes: Int, isAllDay: Bool) -> String {
        isAllDay ? "\(kind.rawValue).allday" : "\(kind.rawValue).\(offsetMinutes)"
    }

    /// "You dismissed the “1 day before” reminder for events 5 times in a row. Stop sending it?"
    var question: String {
        let offset = ReminderText.offset(offsetMinutes, allDay: isAllDay)
        let kinds: String
        if isAllDay {
            kinds = String(localized: "all-day events")
        } else {
            switch kind {
            case .event: kinds = String(localized: "events")
            case .deadline: kinds = String(localized: "deadlines")
            case .task: kinds = String(localized: "tasks")
            case .routine: kinds = String(localized: "routines")
            }
        }
        return String(localized: "You dismissed the “\(offset)” reminder for \(kinds) \(dismissCount) times in a row. Stop sending it?")
    }
}

// MARK: - Tolerant decoding (receipts and suggestions are persisted in chat history and preferences.json)

extension LedgerEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(PreferenceKey.self, forKey: .key) // an unknown key drops the entry
        id = c.preferenceValue(.id, default: UUID())
        value = c.preferenceValue(.value, default: "")
        display = c.preferenceValue(.display, default: "")
        previousDisplay = c.preferenceValue(.previousDisplay, default: "")
        source = c.preferenceValue(.source, default: .settings)
        date = c.preferenceValue(.date, default: Date(timeIntervalSince1970: 0))
    }
}

extension PreferenceChange {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(PreferenceKey.self, forKey: .key)
        oldValue = c.preferenceValue(.oldValue, default: "")
        newValue = c.preferenceValue(.newValue, default: "")
        oldDisplay = c.preferenceValue(.oldDisplay, default: "")
        newDisplay = c.preferenceValue(.newDisplay, default: "")
        replacedEntry = c.preferenceOptional(.replacedEntry, default: nil as LedgerEntry?)
    }
}

extension PreferenceChangeReceipt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.preferenceValue(.id, default: UUID())
        date = c.preferenceValue(.date, default: Date(timeIntervalSince1970: 0))
        source = c.preferenceValue(.source, default: .settings)
        // A change for a key this build does not know is dropped, not the whole receipt.
        changes = c.preferenceValue(.changes, default: [PreferenceLossy<PreferenceChange>]()).compactMap(\.value)
    }
}

extension LearnedSuggestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ScheduleEvent.Kind.self, forKey: .kind)
        id = c.preferenceValue(.id, default: UUID())
        offsetMinutes = c.preferenceValue(.offsetMinutes, default: 0)
        isAllDay = c.preferenceValue(.isAllDay, default: false)
        dismissCount = c.preferenceValue(.dismissCount, default: LearnedSuggestion.dismissThreshold)
        createdAt = c.preferenceValue(.createdAt, default: Date(timeIntervalSince1970: 0))
        status = c.preferenceValue(.status, default: .declined)
        shownInChat = c.preferenceValue(.shownInChat, default: true)
    }
}

/// Decodes one array element without failing the whole array: an unreadable element becomes nil.
struct PreferenceLossy<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
