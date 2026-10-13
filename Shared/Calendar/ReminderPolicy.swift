import Foundation

/// Reminder offsets in minutes. Artboard 1 asks for "day before / 24h / 1h / 30min / at start".
/// Google allows at most 5 overrides, each 0…40320 (4 weeks).
struct ReminderPolicy: Sendable {
    var eventDefaults = [1440, 60, 30]
    var deadlineDefaults = [1440, 60]
    var taskDefaults = [60]
    /// Plan sessions recur 3–5×/week; 3 pings per session would train the user to ignore us.
    var routineDefaults = [30]
    /// Adds a 0-minute "starting now" ping for meetings.
    var includeStartPing = true

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
        let clamped = Set(base.map { min(max($0, 0), Self.googleMaxMinutes) })
        return Array(clamped.sorted(by: >).prefix(Self.googleMaxOverrides))
    }

    func googleReminders(for kind: ScheduleEvent.Kind, requested: [Int]?) -> GCalReminders {
        GCalReminders(
            useDefault: false,
            overrides: minutes(for: kind, requested: requested).map { .init(method: "popup", minutes: $0) }
        )
    }
}
