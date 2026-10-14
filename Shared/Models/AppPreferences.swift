import Foundation

/// Who delivers event reminders.
enum ReminderSource: String, Codable, CaseIterable, Sendable {
    case smartSchedule = "smart_schedule" // local, interactive; new events get no Google pop-ups
    case google                            // Google pop-ups only; no local reminders
    case both                              // today's behaviour
}

enum ReminderUrgency: String, Codable, CaseIterable, Sendable {
    case automatic                         // ≤ 30 min before → .timeSensitive, else .active (today's rule)
    case timeSensitive = "time_sensitive"  // .timeSensitive: breaks through Focus
    case normal                            // .active, default sound
    case quiet                             // .passive, no sound
}

struct QuietHours: Codable, Hashable, Sendable {
    var isEnabled = false
    var startMinute = 22 * 60   // minute of the local day, 0...1439
    var endMinute = 7 * 60      // exclusive; may be earlier than start (crosses midnight)

    /// False when disabled or when start == end.
    func contains(minuteOfDay: Int) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        if startMinute < endMinute { return minuteOfDay >= startMinute && minuteOfDay < endMinute }
        return minuteOfDay >= startMinute || minuteOfDay < endMinute
    }
}

struct DailyTime: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var minuteOfDay: Int        // 0...1439
}

enum WeekStart: String, Codable, CaseIterable, Sendable {
    case sunday, monday
    var firstWeekday: Int { self == .monday ? 2 : 1 }
}

enum ReplyLanguage: String, Codable, CaseIterable, Sendable {
    case matchInput = "match"
    case traditionalChinese = "zh-Hant"
    case english = "en"
}

enum SpeechLanguage: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case chineseTaiwan = "zh-TW"
    case englishUK = "en-GB"
    case englishUS = "en-US"
    /// nil = the device language (`Locale.current`).
    var localeIdentifier: String? { self == .automatic ? nil : rawValue }
}

enum AssistantAutonomy: String, Codable, CaseIterable, Sendable {
    case addDirectly = "add_directly"
    case askFirst = "ask_first"
}

enum ChatRetention: String, Codable, CaseIterable, Sendable {
    case week = "7d"
    case month = "30d"
    case forever
    /// nil = keep forever.
    var maxAge: TimeInterval? {
        switch self {
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .forever: nil
        }
    }
}

/// Every setting with its default. A fresh `AppPreferences()` behaves like the app did before Settings existed,
/// except the morning briefing (07:30) and the Dynamic Island lead time (30 min), which are new and on.
///
/// Stored in the App Group by `PreferencesStore`; read synchronously everywhere through `current()`.
struct AppPreferences: Codable, Hashable, Sendable {
    static let currentVersion = 1

    /// The Dynamic Island shows an event only when it is imminent: at most 30 minutes before it starts.
    static let defaultLiveActivityLeadMinutes = 30
    static let liveActivityLeadChoices = [30, 15, 10, 5]

    /// The choice at or below `minutes` (an older build offered 1 and 2 hours: read as 30); 5 below that.
    static func liveActivityLead(_ minutes: Int) -> Int {
        liveActivityLeadChoices.first { $0 <= minutes } ?? liveActivityLeadChoices[liveActivityLeadChoices.count - 1]
    }

    var version = AppPreferences.currentVersion

    // MARK: Notifications
    var reminderSource: ReminderSource = .both
    /// Minutes before start; 0 = at start. Descending, de-duplicated, ≤ 5 values, each 0...40320.
    var eventReminders: [Int] = [1440, 60, 30, 0]
    var deadlineReminders: [Int] = [1440, 60]
    var taskReminders: [Int] = [60]
    var routineReminders: [Int] = [30]
    /// All-day events and plan milestones: minutes before 00:00 of the event day (900 = the day before at 09:00),
    /// 1...1440. nil = no reminder.
    var allDayReminderMinutes: Int? = 900
    var eventUrgency: ReminderUrgency = .automatic
    var deadlineUrgency: ReminderUrgency = .automatic
    var taskUrgency: ReminderUrgency = .automatic
    var routineUrgency: ReminderUrgency = .automatic
    var quietHours = QuietHours()
    var morningBriefing = DailyTime(isEnabled: true, minuteOfDay: 7 * 60 + 30)
    var eveningPreview = DailyTime(isEnabled: false, minuteOfDay: 21 * 60)
    /// At most this many reminders per local day (1...50). nil = no limit.
    var dailyReminderCap: Int? = nil
    /// Settings › Dynamic Island: how many minutes before a timed event its Live Activity appears. nil = off.
    /// One of `liveActivityLeadChoices`; see `liveActivityLead(_:)` for values an older build stored.
    var liveActivityLeadMinutes: Int? = AppPreferences.defaultLiveActivityLeadMinutes

    // MARK: Input
    /// nil = automatic (the first account's primary calendar).
    var defaultCalendar: CalendarRef? = nil
    /// "<calendar displayName> | <account email>", as the CALENDARS prompt block lists it. nil with `defaultCalendar`.
    var defaultCalendarLabel: String? = nil
    /// Fallback length of timed `event` and `routine` items (minutes, 5...480). Tasks and deadlines keep 30.
    var defaultEventMinutes = 60
    var weekStart: WeekStart = .sunday
    /// nil = follow the device (`TimeZone.current`); otherwise an IANA identifier.
    var timeZoneIdentifier: String? = nil
    var replyLanguage: ReplyLanguage = .matchInput
    var speechLanguage: SpeechLanguage = .automatic
    var speechOnDevice = true
    var autonomy: AssistantAutonomy = .addDirectly

    // MARK: Data
    var chatRetention: ChatRetention = .month

    init() {}

    /// Tolerant: a missing, null-where-not-allowed or unknown value falls back to its default, so files written by
    /// older or newer builds always load. Values are clamped into their documented ranges.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()
        version = c.preferenceValue(.version, default: d.version)
        reminderSource = c.preferenceValue(.reminderSource, default: d.reminderSource)
        eventReminders = Self.sanitizedReminders(c.preferenceValue(.eventReminders, default: d.eventReminders))
        deadlineReminders = Self.sanitizedReminders(c.preferenceValue(.deadlineReminders, default: d.deadlineReminders))
        taskReminders = Self.sanitizedReminders(c.preferenceValue(.taskReminders, default: d.taskReminders))
        routineReminders = Self.sanitizedReminders(c.preferenceValue(.routineReminders, default: d.routineReminders))
        allDayReminderMinutes = c.preferenceOptional(.allDayReminderMinutes, default: d.allDayReminderMinutes)
            .map { min(max($0, 1), 1440) }
        eventUrgency = c.preferenceValue(.eventUrgency, default: d.eventUrgency)
        deadlineUrgency = c.preferenceValue(.deadlineUrgency, default: d.deadlineUrgency)
        taskUrgency = c.preferenceValue(.taskUrgency, default: d.taskUrgency)
        routineUrgency = c.preferenceValue(.routineUrgency, default: d.routineUrgency)
        quietHours = c.preferenceValue(.quietHours, default: d.quietHours)
        morningBriefing = c.preferenceValue(.morningBriefing, default: d.morningBriefing)
        eveningPreview = c.preferenceValue(.eveningPreview, default: d.eveningPreview)
        dailyReminderCap = c.preferenceOptional(.dailyReminderCap, default: d.dailyReminderCap).map { min(max($0, 1), 50) }
        liveActivityLeadMinutes = c.preferenceOptional(.liveActivityLeadMinutes, default: d.liveActivityLeadMinutes)
            .map(Self.liveActivityLead)
        defaultCalendar = c.preferenceOptional(.defaultCalendar, default: d.defaultCalendar)
        defaultCalendarLabel = defaultCalendar == nil ? nil : c.preferenceOptional(.defaultCalendarLabel, default: nil as String?)
        defaultEventMinutes = min(max(c.preferenceValue(.defaultEventMinutes, default: d.defaultEventMinutes), 5), 480)
        weekStart = c.preferenceValue(.weekStart, default: d.weekStart)
        timeZoneIdentifier = c.preferenceOptional(.timeZoneIdentifier, default: d.timeZoneIdentifier)
            .flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
        replyLanguage = c.preferenceValue(.replyLanguage, default: d.replyLanguage)
        speechLanguage = c.preferenceValue(.speechLanguage, default: d.speechLanguage)
        speechOnDevice = c.preferenceValue(.speechOnDevice, default: d.speechOnDevice)
        autonomy = c.preferenceValue(.autonomy, default: d.autonomy)
        chatRetention = c.preferenceValue(.chatRetention, default: d.chatRetention)
    }

    /// Optionals whose default is not nil are written as explicit `null`, so "no reminder" survives a round trip
    /// instead of reading back as the default.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(reminderSource, forKey: .reminderSource)
        try c.encode(eventReminders, forKey: .eventReminders)
        try c.encode(deadlineReminders, forKey: .deadlineReminders)
        try c.encode(taskReminders, forKey: .taskReminders)
        try c.encode(routineReminders, forKey: .routineReminders)
        try c.encodePreferenceOrNull(allDayReminderMinutes, forKey: .allDayReminderMinutes)
        try c.encode(eventUrgency, forKey: .eventUrgency)
        try c.encode(deadlineUrgency, forKey: .deadlineUrgency)
        try c.encode(taskUrgency, forKey: .taskUrgency)
        try c.encode(routineUrgency, forKey: .routineUrgency)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(morningBriefing, forKey: .morningBriefing)
        try c.encode(eveningPreview, forKey: .eveningPreview)
        try c.encodePreferenceOrNull(dailyReminderCap, forKey: .dailyReminderCap)
        try c.encodePreferenceOrNull(liveActivityLeadMinutes, forKey: .liveActivityLeadMinutes)
        try c.encodePreferenceOrNull(defaultCalendar, forKey: .defaultCalendar)
        try c.encodePreferenceOrNull(defaultCalendarLabel, forKey: .defaultCalendarLabel)
        try c.encode(defaultEventMinutes, forKey: .defaultEventMinutes)
        try c.encode(weekStart, forKey: .weekStart)
        try c.encodePreferenceOrNull(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try c.encode(replyLanguage, forKey: .replyLanguage)
        try c.encode(speechLanguage, forKey: .speechLanguage)
        try c.encode(speechOnDevice, forKey: .speechOnDevice)
        try c.encode(autonomy, forKey: .autonomy)
        try c.encode(chatRetention, forKey: .chatRetention)
    }

    private enum CodingKeys: String, CodingKey {
        case version, reminderSource, eventReminders, deadlineReminders, taskReminders, routineReminders
        case allDayReminderMinutes, eventUrgency, deadlineUrgency, taskUrgency, routineUrgency, quietHours
        case morningBriefing, eveningPreview, dailyReminderCap, liveActivityLeadMinutes, defaultCalendar
        case defaultCalendarLabel, defaultEventMinutes, weekStart, timeZoneIdentifier, replyLanguage
        case speechLanguage, speechOnDevice, autonomy, chatRetention
    }
}

extension QuietHours {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietHours()
        isEnabled = c.preferenceValue(.isEnabled, default: d.isEnabled)
        startMinute = AppPreferences.clampedMinuteOfDay(c.preferenceValue(.startMinute, default: d.startMinute))
        endMinute = AppPreferences.clampedMinuteOfDay(c.preferenceValue(.endMinute, default: d.endMinute))
    }
}

extension DailyTime {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.preferenceValue(.isEnabled, default: false)
        minuteOfDay = AppPreferences.clampedMinuteOfDay(c.preferenceValue(.minuteOfDay, default: 0))
    }
}

extension AppPreferences {
    var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    var firstWeekday: Int { weekStart.firstWeekday }
    var localRemindersEnabled: Bool { reminderSource != .google }
    var writesGooglePopups: Bool { reminderSource != .smartSchedule }

    static let maxReminders = 5
    static let maxReminderMinutes = 40_320

    func reminders(for kind: ScheduleEvent.Kind) -> [Int] {
        switch kind {
        case .event: eventReminders
        case .deadline: deadlineReminders
        case .task: taskReminders
        case .routine: routineReminders
        }
    }

    /// Clamps to 0...40320, de-duplicates, sorts descending and keeps the 5 largest (Google's limits).
    mutating func setReminders(_ minutes: [Int], for kind: ScheduleEvent.Kind) {
        let clean = Self.sanitizedReminders(minutes)
        switch kind {
        case .event: eventReminders = clean
        case .deadline: deadlineReminders = clean
        case .task: taskReminders = clean
        case .routine: routineReminders = clean
        }
    }

    func urgency(for kind: ScheduleEvent.Kind) -> ReminderUrgency {
        switch kind {
        case .event: eventUrgency
        case .deadline: deadlineUrgency
        case .task: taskUrgency
        case .routine: routineUrgency
        }
    }

    mutating func setUrgency(_ urgency: ReminderUrgency, for kind: ScheduleEvent.Kind) {
        switch kind {
        case .event: eventUrgency = urgency
        case .deadline: deadlineUrgency = urgency
        case .task: taskUrgency = urgency
        case .routine: routineUrgency = urgency
        }
    }

    static func sanitizedReminders(_ minutes: [Int]) -> [Int] {
        Array(Set(minutes.map { min(max($0, 0), maxReminderMinutes) }).sorted(by: >).prefix(maxReminders))
    }

    static func clampedMinuteOfDay(_ minute: Int) -> Int {
        min(max(minute, 0), 1439)
    }
}

// MARK: - Preference keys

/// The preferences the assistant may change by voice (`update_preferences`) and the ledger tracks.
/// Raw values are the function's enum strings.
enum PreferenceKey: String, Codable, CaseIterable, Sendable {
    case eventReminders = "event_reminders"
    case deadlineReminders = "deadline_reminders"
    case taskReminders = "task_reminders"
    case routineReminders = "routine_reminders"
    case allDayReminder = "all_day_reminder"
    case eventUrgency = "event_urgency"
    case deadlineUrgency = "deadline_urgency"
    case taskUrgency = "task_urgency"
    case routineUrgency = "routine_urgency"
    case quietHours = "quiet_hours"
    case morningBriefing = "morning_briefing"
    case eveningPreview = "evening_preview"
    case dailyReminderCap = "daily_reminder_cap"
    case defaultCalendar = "default_calendar"
    case defaultDuration = "default_duration"
    case weekStart = "week_start"
    case replyLanguage = "reply_language"
    case autonomy = "autonomy"

    var title: String {
        switch self {
        case .eventReminders: String(localized: "Event reminders")
        case .deadlineReminders: String(localized: "Deadline reminders")
        case .taskReminders: String(localized: "Task reminders")
        case .routineReminders: String(localized: "Routine reminders")
        case .allDayReminder: String(localized: "All-day event reminder")
        case .eventUrgency: String(localized: "Event urgency")
        case .deadlineUrgency: String(localized: "Deadline urgency")
        case .taskUrgency: String(localized: "Task urgency")
        case .routineUrgency: String(localized: "Routine urgency")
        case .quietHours: String(localized: "Quiet hours")
        case .morningBriefing: String(localized: "Morning briefing")
        case .eveningPreview: String(localized: "Evening preview")
        case .dailyReminderCap: String(localized: "Daily reminder limit")
        case .defaultCalendar: String(localized: "Calendar for new events")
        case .defaultDuration: String(localized: "Default duration")
        case .weekStart: String(localized: "Week starts on")
        case .replyLanguage: String(localized: "Reply language")
        case .autonomy: String(localized: "Adding events")
        }
    }

    /// The event kind of a `*_reminders` / `*_urgency` key.
    var reminderKind: ScheduleEvent.Kind? {
        switch self {
        case .eventReminders, .eventUrgency: .event
        case .deadlineReminders, .deadlineUrgency: .deadline
        case .taskReminders, .taskUrgency: .task
        case .routineReminders, .routineUrgency: .routine
        default: nil
        }
    }

    /// Keys whose change needs `ReminderScheduler.reschedule()` (reminders, urgency, quiet hours, briefings, cap).
    var affectsNotifications: Bool {
        switch self {
        case .defaultCalendar, .defaultDuration, .weekStart, .replyLanguage, .autonomy: false
        default: true
        }
    }
}

enum PreferenceValueError: Error, Equatable, Sendable {
    /// English reason, returned to Gemini and shown in the chat, e.g. "quiet_hours must be HH:mm-HH:mm or off".
    case invalid(String)

    var reason: String {
        switch self {
        case let .invalid(reason): reason
        }
    }
}

// MARK: - Values per key
//
// Three forms per key:
// • canonical: stored in receipts, the ledger and undo; round-trips exactly ("1440,60", "none", "900",
//   "on 22:00-07:00", "off 07:30", "10", "off", "automatic", "<accountID>/<calendarID>|<label>", "60", …)
// • prompt: the model-facing value of the update_preferences declaration ("1440,60", "09:00", "22:00-07:00", …)
// • display: localized for cards, the ledger and Settings.

extension AppPreferences {
    func canonicalValue(for key: PreferenceKey) -> String {
        switch key {
        case .eventReminders, .deadlineReminders, .taskReminders, .routineReminders:
            return Self.reminderList(reminders(for: key.reminderKind!))
        case .allDayReminder:
            return allDayReminderMinutes.map(String.init) ?? "none"
        case .eventUrgency, .deadlineUrgency, .taskUrgency, .routineUrgency:
            return urgency(for: key.reminderKind!).rawValue
        case .quietHours:
            return (quietHours.isEnabled ? "on " : "off ") + Self.timeRange(quietHours.startMinute, quietHours.endMinute)
        case .morningBriefing:
            return Self.canonical(morningBriefing)
        case .eveningPreview:
            return Self.canonical(eveningPreview)
        case .dailyReminderCap:
            return dailyReminderCap.map(String.init) ?? "off"
        case .defaultCalendar:
            guard let defaultCalendar else { return "automatic" }
            return defaultCalendar.key + "|" + (defaultCalendarLabel ?? "")
        case .defaultDuration:
            return String(defaultEventMinutes)
        case .weekStart:
            return weekStart.rawValue
        case .replyLanguage:
            return replyLanguage.rawValue
        case .autonomy:
            return autonomy.rawValue
        }
    }

    /// The model-facing value, as the PREFERENCES prompt block shows it. default_calendar →
    /// `defaultCalendarLabel ?? "automatic"`.
    func promptValue(for key: PreferenceKey) -> String {
        switch key {
        case .allDayReminder:
            return allDayReminderMinutes.map { Self.hhmm(1440 - $0) } ?? "none"
        case .quietHours:
            return quietHours.isEnabled ? Self.timeRange(quietHours.startMinute, quietHours.endMinute) : "off"
        case .morningBriefing:
            return morningBriefing.isEnabled ? Self.hhmm(morningBriefing.minuteOfDay) : "off"
        case .eveningPreview:
            return eveningPreview.isEnabled ? Self.hhmm(eveningPreview.minuteOfDay) : "off"
        case .defaultCalendar:
            return defaultCalendar == nil ? "automatic" : (defaultCalendarLabel ?? "automatic")
        default:
            return canonicalValue(for: key)
        }
    }

    /// Localized: "1 day, 1 h, 30 min, at start", "None", "The day before at 09:00", "Automatic", "Time Sensitive",
    /// "22:00–08:00", "Off", "07:30", "10 a day", "60 min", "Sunday", "繁體中文", "Ask me first", the calendar label, …
    func displayValue(for key: PreferenceKey) -> String {
        switch key {
        case .eventReminders, .deadlineReminders, .taskReminders, .routineReminders:
            return ReminderText.list(reminders(for: key.reminderKind!))
        case .allDayReminder:
            return allDayReminderMinutes.map { ReminderText.offset($0, allDay: true) } ?? String(localized: "None")
        case .eventUrgency, .deadlineUrgency, .taskUrgency, .routineUrgency:
            return Self.display(urgency(for: key.reminderKind!))
        case .quietHours:
            guard quietHours.isEnabled else { return String(localized: "Off") }
            return ReminderText.clock(quietHours.startMinute) + "–" + ReminderText.clock(quietHours.endMinute)
        case .morningBriefing:
            return morningBriefing.isEnabled ? ReminderText.clock(morningBriefing.minuteOfDay) : String(localized: "Off")
        case .eveningPreview:
            return eveningPreview.isEnabled ? ReminderText.clock(eveningPreview.minuteOfDay) : String(localized: "Off")
        case .dailyReminderCap:
            guard let cap = dailyReminderCap else { return String(localized: "Off") }
            return String(localized: "\(cap) a day")
        case .defaultCalendar:
            guard defaultCalendar != nil, let label = defaultCalendarLabel, !label.isEmpty else {
                return String(localized: "Automatic")
            }
            return label.replacingOccurrences(of: " | ", with: " · ")
        case .defaultDuration:
            return String(localized: "\(defaultEventMinutes) min")
        case .weekStart:
            return weekStart == .monday ? String(localized: "Monday") : String(localized: "Sunday")
        case .replyLanguage:
            switch replyLanguage {
            case .matchInput: return String(localized: "Match what I type")
            // Language names are shown in their own language, whatever the UI language.
            case .traditionalChinese: return "繁體中文"
            case .english: return "English"
            }
        case .autonomy:
            return autonomy == .askFirst ? String(localized: "Ask me first") : String(localized: "Add directly")
        }
    }

    static func display(_ urgency: ReminderUrgency) -> String {
        switch urgency {
        case .automatic: String(localized: "Automatic")
        case .timeSensitive: String(localized: "Time Sensitive")
        case .normal: String(localized: "Normal")
        case .quiet: String(localized: "Quiet")
        }
    }

    /// Model-facing value (update_preferences) → canonical. "on" / "off" keep the stored times. Throws
    /// `PreferenceValueError`. default_calendar is resolved by `PreferencesStore.apply`; only "automatic" passes here.
    func normalized(_ modelValue: String, for key: PreferenceKey) throws -> String {
        let value = modelValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        switch key {
        case .eventReminders, .deadlineReminders, .taskReminders, .routineReminders:
            let reason = "\(key.rawValue) must be minutes before start, comma-separated (at most 5, each 0-40320), or none"
            if ["none", "off"].contains(lower) { return "none" }
            let parts = value.components(separatedBy: CharacterSet(charactersIn: ",，、;/ ")).filter { !$0.isEmpty }
            guard !parts.isEmpty else { throw PreferenceValueError.invalid(reason) }
            var minutes: [Int] = []
            for part in parts {
                guard let number = Int(part), (0...Self.maxReminderMinutes).contains(number) else {
                    throw PreferenceValueError.invalid(reason)
                }
                minutes.append(number)
            }
            let unique = Array(Set(minutes)).sorted(by: >)
            guard unique.count <= Self.maxReminders else { throw PreferenceValueError.invalid(reason) }
            return Self.reminderList(unique)

        case .allDayReminder:
            if ["none", "off"].contains(lower) { return "none" }
            guard let minuteOfDay = Self.parseClock(value) else {
                throw PreferenceValueError.invalid("all_day_reminder must be HH:mm (the day before) or none")
            }
            return String(1440 - minuteOfDay) // 00:00 → 1440

        case .eventUrgency, .deadlineUrgency, .taskUrgency, .routineUrgency:
            let raw = lower.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            guard let urgency = ReminderUrgency(rawValue: raw) else {
                throw PreferenceValueError.invalid("\(key.rawValue) must be automatic, time_sensitive, normal or quiet")
            }
            return urgency.rawValue

        case .quietHours:
            let reason = "quiet_hours must be HH:mm-HH:mm or off"
            switch lower {
            case "off": return "off " + Self.timeRange(quietHours.startMinute, quietHours.endMinute)
            case "on": return "on " + Self.timeRange(quietHours.startMinute, quietHours.endMinute)
            default:
                let ends = value.components(separatedBy: CharacterSet(charactersIn: "-–—~")).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard ends.count == 2, let start = Self.parseClock(ends[0]), let end = Self.parseClock(ends[1]) else {
                    throw PreferenceValueError.invalid(reason)
                }
                guard start != end else {
                    throw PreferenceValueError.invalid("quiet_hours must start and end at different times")
                }
                return "on " + Self.timeRange(start, end)
            }

        case .morningBriefing, .eveningPreview:
            let current = key == .morningBriefing ? morningBriefing : eveningPreview
            switch lower {
            case "off": return "off " + Self.hhmm(current.minuteOfDay)
            case "on": return "on " + Self.hhmm(current.minuteOfDay)
            default:
                guard let minuteOfDay = Self.parseClock(value) else {
                    throw PreferenceValueError.invalid("\(key.rawValue) must be HH:mm or off")
                }
                return "on " + Self.hhmm(minuteOfDay)
            }

        case .dailyReminderCap:
            if ["off", "none"].contains(lower) { return "off" }
            guard let cap = Int(value), (1...50).contains(cap) else {
                throw PreferenceValueError.invalid("daily_reminder_cap must be a number from 1 to 50 or off")
            }
            return String(cap)

        case .defaultCalendar:
            guard lower == "automatic" else {
                throw PreferenceValueError.invalid("default_calendar must be one line of CALENDARS or automatic")
            }
            return "automatic"

        case .defaultDuration:
            guard let minutes = Int(value), (5...480).contains(minutes) else {
                throw PreferenceValueError.invalid("default_duration must be minutes from 5 to 480")
            }
            return String(minutes)

        case .weekStart:
            guard let start = WeekStart(rawValue: lower) else {
                throw PreferenceValueError.invalid("week_start must be sunday or monday")
            }
            return start.rawValue

        case .replyLanguage:
            switch lower.replacingOccurrences(of: "_", with: "-") {
            case "match", "match-input", "auto": return ReplyLanguage.matchInput.rawValue
            case "zh-hant", "zh-tw", "zh-hant-tw", "zh", "zh-hk": return ReplyLanguage.traditionalChinese.rawValue
            case "en", "en-us", "en-gb", "english": return ReplyLanguage.english.rawValue
            default: throw PreferenceValueError.invalid("reply_language must be match, zh-Hant or en")
            }

        case .autonomy:
            guard let autonomy = AssistantAutonomy(rawValue: lower) else {
                throw PreferenceValueError.invalid("autonomy must be add_directly or ask_first")
            }
            return autonomy.rawValue
        }
    }

    /// Sets a canonical value (from `normalized` or a receipt). Throws `PreferenceValueError`.
    mutating func apply(canonical: String, for key: PreferenceKey) throws {
        let invalid = PreferenceValueError.invalid("\(key.rawValue): unreadable stored value “\(canonical)”")
        switch key {
        case .eventReminders, .deadlineReminders, .taskReminders, .routineReminders:
            if canonical == "none" {
                setReminders([], for: key.reminderKind!)
                return
            }
            let minutes = canonical.split(separator: ",").map { Int($0) }
            guard !minutes.isEmpty, minutes.allSatisfy({ $0 != nil }) else { throw invalid }
            setReminders(minutes.compactMap { $0 }, for: key.reminderKind!)

        case .allDayReminder:
            if canonical == "none" {
                allDayReminderMinutes = nil
                return
            }
            guard let minutes = Int(canonical), (1...1440).contains(minutes) else { throw invalid }
            allDayReminderMinutes = minutes

        case .eventUrgency, .deadlineUrgency, .taskUrgency, .routineUrgency:
            guard let urgency = ReminderUrgency(rawValue: canonical) else { throw invalid }
            setUrgency(urgency, for: key.reminderKind!)

        case .quietHours:
            let parts = canonical.split(separator: " ")
            guard parts.count == 2, ["on", "off"].contains(parts[0]) else { throw invalid }
            let ends = parts[1].split(separator: "-").map(String.init)
            guard ends.count == 2, let start = Self.parseClock(ends[0]), let end = Self.parseClock(ends[1]) else {
                throw invalid
            }
            quietHours = QuietHours(isEnabled: parts[0] == "on", startMinute: start, endMinute: end)

        case .morningBriefing, .eveningPreview:
            let parts = canonical.split(separator: " ")
            guard parts.count == 2, ["on", "off"].contains(parts[0]), let minuteOfDay = Self.parseClock(String(parts[1])) else {
                throw invalid
            }
            let time = DailyTime(isEnabled: parts[0] == "on", minuteOfDay: minuteOfDay)
            if key == .morningBriefing { morningBriefing = time } else { eveningPreview = time }

        case .dailyReminderCap:
            if canonical == "off" {
                dailyReminderCap = nil
                return
            }
            guard let cap = Int(canonical), (1...50).contains(cap) else { throw invalid }
            dailyReminderCap = cap

        case .defaultCalendar:
            if canonical == "automatic" {
                defaultCalendar = nil
                defaultCalendarLabel = nil
                return
            }
            // "<accountID>/<calendarID>|<label>": ids contain no "|", the label may.
            guard let bar = canonical.firstIndex(of: "|"),
                  let ref = CalendarRef(key: String(canonical[..<bar])) else { throw invalid }
            let label = String(canonical[canonical.index(after: bar)...])
            defaultCalendar = ref
            defaultCalendarLabel = label.isEmpty ? nil : label

        case .defaultDuration:
            guard let minutes = Int(canonical), (5...480).contains(minutes) else { throw invalid }
            defaultEventMinutes = minutes

        case .weekStart:
            guard let start = WeekStart(rawValue: canonical) else { throw invalid }
            weekStart = start

        case .replyLanguage:
            guard let language = ReplyLanguage(rawValue: canonical) else { throw invalid }
            replyLanguage = language

        case .autonomy:
            guard let autonomy = AssistantAutonomy(rawValue: canonical) else { throw invalid }
            self.autonomy = autonomy
        }
    }

    /// The model-facing form of a canonical value (receipts store canonical values; the update_preferences function
    /// response and the PREFERENCES block use this form). An unreadable value is returned as it is.
    static func promptValue(canonical: String, for key: PreferenceKey) -> String {
        var preferences = AppPreferences()
        guard (try? preferences.apply(canonical: canonical, for: key)) != nil else { return canonical }
        return preferences.promptValue(for: key)
    }

    /// Back to `AppPreferences()`'s value for this key (default_calendar also clears the label).
    mutating func reset(_ key: PreferenceKey) {
        // The default's canonical value always parses.
        try? apply(canonical: AppPreferences().canonicalValue(for: key), for: key)
    }

    // MARK: Formatting helpers

    /// "1440,60,30,0"; [] → "none".
    static func reminderList(_ minutes: [Int]) -> String {
        minutes.isEmpty ? "none" : minutes.map(String.init).joined(separator: ",")
    }

    /// "07:30" for a minute of the day.
    static func hhmm(_ minuteOfDay: Int) -> String {
        let minute = clampedMinuteOfDay(minuteOfDay)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// "22:00-07:00".
    static func timeRange(_ start: Int, _ end: Int) -> String {
        hhmm(start) + "-" + hhmm(end)
    }

    /// "HH:mm" or "H:mm" (24-hour) → minute of the day.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func canonical(_ time: DailyTime) -> String {
        (time.isEnabled ? "on " : "off ") + hhmm(time.minuteOfDay)
    }
}

// MARK: - Tolerant decoding helpers

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when it is missing, null or unreadable (an unknown enum raw value included).
    func preferenceValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// For optionals whose nil means something ("no reminder"): missing → `fallback`, explicit null → nil,
    /// unreadable → `fallback`.
    func preferenceOptional<T: Decodable>(_ key: Key, default fallback: T?) -> T? {
        guard contains(key) else { return fallback }
        if (try? decodeNil(forKey: key)) == true { return nil }
        return (try? decode(T.self, forKey: key)) ?? fallback
    }
}

extension KeyedEncodingContainer {
    /// Writes `null` for nil instead of leaving the key out.
    mutating func encodePreferenceOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
