import Foundation

/// Reminder offsets in minutes. Artboard 1 asks for "day before / 24h / 1h / 30min / at start".
/// Google allows at most 5 overrides, each 0…40320 (4 weeks).
///
/// `ReminderPolicy()` is the built-in default; the app uses `ReminderPolicy(preferences:)`, built per request from
/// Settings › Notifications.
struct ReminderPolicy: Sendable {
    var eventDefaults = [1440, 60, 30]
    var deadlineDefaults = [1440, 60]
    var taskDefaults = [60]
    /// Plan sessions recur 3–5×/week; 3 pings per session would train the user to ignore us.
    var routineDefaults = [30]
    /// Adds a 0-minute "starting now" ping for meetings.
    var includeStartPing = true
    /// All-day events and plan milestones: minutes before 00:00 of the event day (900 = the day before at 09:00).
    /// [] = no reminder.
    var allDayDefaults: [Int] = [900]
    /// False in "Smart Schedules only" mode: new and edited events get no Google pop-ups (empty overrides), so
    /// only Smart Schedule's interactive reminders alert.
    var writesGooglePopups = true

    static let googleMaxOverrides = 5
    static let googleMaxMinutes = 40_320

    func defaults(for kind: ScheduleEvent.Kind) -> [Int] {
        switch kind {
        case .event: includeStartPing ? eventDefaults + [0] : eventDefaults
        case .deadline: deadlineDefaults
        case .task: taskDefaults
        case .routine: routineDefaults
        }
    }

    /// Requested values (if any) or defaults → clamped, de-duplicated, descending, ≤ 5.
    func minutes(for kind: ScheduleEvent.Kind, requested: [Int]?) -> [Int] {
        let base = (requested?.isEmpty == false ? requested! : defaults(for: kind))
        return Self.clean(base)
    }

    func googleReminders(for kind: ScheduleEvent.Kind, requested: [Int]?) -> GCalReminders {
        guard writesGooglePopups else { return Self.noPopups }
        return GCalReminders(
            useDefault: false,
            overrides: minutes(for: kind, requested: requested).map { .init(method: "popup", minutes: $0) }
        )
    }

    /// `useDefault: false` with no overrides: Google shows nothing for this event.
    static let noPopups = GCalReminders(useDefault: false, overrides: [])

    private static func clean(_ minutes: [Int]) -> [Int] {
        let clamped = Set(minutes.map { min(max($0, 0), googleMaxMinutes) })
        return Array(clamped.sorted(by: >).prefix(googleMaxOverrides))
    }
}

// In an extension so the synthesized `init()` and memberwise initializer stay available.
extension ReminderPolicy {
    /// Defaults from Settings › Notifications. The event list already carries its 0-minute ping when the user
    /// keeps "at start", so `includeStartPing` is off.
    init(preferences: AppPreferences) {
        self.init()
        eventDefaults = preferences.eventReminders
        deadlineDefaults = preferences.deadlineReminders
        taskDefaults = preferences.taskReminders
        routineDefaults = preferences.routineReminders
        includeStartPing = false
        allDayDefaults = preferences.allDayReminderMinutes.map { [$0] } ?? []
        writesGooglePopups = preferences.writesGooglePopups
    }

    /// All-day events and plan milestones: requested values (if any) or `allDayDefaults` → clamped, de-duplicated,
    /// descending, ≤ 5. Each value counts back from 00:00 of the event day.
    func allDayMinutes(requested: [Int]?) -> [Int] {
        Self.clean(requested?.isEmpty == false ? requested! : allDayDefaults)
    }

    func googleAllDayReminders(requested: [Int]?) -> GCalReminders {
        guard writesGooglePopups else { return Self.noPopups }
        return GCalReminders(
            useDefault: false,
            overrides: allDayMinutes(requested: requested).map { .init(method: "popup", minutes: $0) }
        )
    }
}
