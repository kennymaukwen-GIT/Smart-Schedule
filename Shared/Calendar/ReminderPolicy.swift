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
    /// A timed one-off event, deadline or task created for later the same day gets these instead of its kind's
    /// defaults: 10 minutes before and at the start (owner decision, 18 Oct 2026). The day-before and hour-before
    /// defaults would mostly be past already. Not a setting: `ReminderPolicy(preferences:)` keeps it.
    /// See `sameDayMinutes(for:start:createdAt:calendar:)`.
    var sameDayDefaults = [10, 0]

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

    /// The reminders of a timed one-off item created at `now` that starts later the same day: `sameDayDefaults`
    /// (10 minutes before and at the start), clamped like every list. nil when the kind's defaults apply instead:
    /// a routine (plan sessions), a start that is not after `now`, a start on another day of `calendar` (the app's
    /// `WallClock` calendar, so its time zone decides), or a kind whose defaults are "none" (an empty list, which
    /// stays none). Reminders already past when it is created are not scheduled (`ReminderPlanner` skips them).
    /// The caller checks the rest: only when the user asked for no specific reminders, and not for all-day or
    /// repeating items.
    func sameDayMinutes(for kind: ScheduleEvent.Kind, start: Date, createdAt now: Date, calendar: Calendar) -> [Int]? {
        guard kind != .routine, start > now, calendar.isDate(start, inSameDayAs: now),
              !defaults(for: kind).isEmpty else { return nil }
        let minutes = Self.clean(sameDayDefaults)
        return minutes.isEmpty ? nil : minutes
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
    /// keeps "at start", so `includeStartPing` is off. `sameDayDefaults` stays [10, 0] (not a setting).
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
