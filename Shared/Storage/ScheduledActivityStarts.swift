import Foundation

/// iOS 26: when each scheduled Live Activity (`.pending`) will start, by event ID. iOS alerts when it starts (sound,
/// screen on, the expanded island; Apple requires the alert), so `ReminderScheduler` leaves out that event's reminder
/// that says the same at the same moment (`ReminderPlanner.withoutLiveActivityDuplicates`). Written by
/// `ActivityScheduler` after every pass from what ActivityKit holds; read in the app and the notification content
/// extension. Always empty on iOS 18.
///
/// App Group `UserDefaults`, key "liveActivity.scheduledStarts": event ID → start (seconds since 1970). Local only,
/// never sent anywhere; "Erase all data" clears it.
enum ScheduledActivityStarts {
    static let key = "liveActivity.scheduledStarts"

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) -> [String: Date] {
        (defaults?.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Saves `starts`; true when they differ from what was saved (the reminders then need rescheduling). false
    /// without an App Group (nothing saved, so nothing changed).
    @discardableResult
    static func store(_ starts: [String: Date],
                      defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) -> Bool {
        guard let defaults else { return false }
        let values = starts.mapValues(\.timeIntervalSince1970)
        guard (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]) != values else { return false }
        defaults.set(values, forKey: key)
        return true
    }
}
