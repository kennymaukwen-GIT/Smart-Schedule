import Foundation

/// Reminder offset wording shared by Settings, chat cards, the ledger and the event detail sheet.
/// Uses the same catalog keys `EventDetailSheet.reminderText` introduced.
enum ReminderText {
    /// "At start", "%lld minutes before", "1 hour before", "%lld hours before", "1 day before", "%lld days before";
    /// all-day (minutes before 00:00 of the event day): "The day before at %@", "On the day at %@",
    /// "%lld days before at %@".
    static func offset(_ minutes: Int, allDay: Bool = false) -> String {
        if allDay {
            let daysBefore = (minutes + 1439) / 1440
            let time = clock(daysBefore * 1440 - minutes)
            switch daysBefore {
            case ...0: return String(localized: "On the day at \(time)")
            case 1: return String(localized: "The day before at \(time)")
            default: return String(localized: "\(daysBefore) days before at \(time)")
            }
        }
        return switch minutes {
        case ...0: String(localized: "At start")
        case 1..<60: String(localized: "\(minutes) minutes before")
        case 60..<120: String(localized: "1 hour before")
        case 120..<1440: String(localized: "\(minutes / 60) hours before")
        case 1440..<2880: String(localized: "1 day before")
        default: String(localized: "\(minutes / 1440) days before")
        }
    }

    /// Compact list for rows and cards: "1 day, 1 h, 30 min, at start" / "1 天、1 小時、30 分鐘、開始時"; [] → "None".
    static func list(_ minutes: [Int]) -> String {
        guard !minutes.isEmpty else { return String(localized: "None") }
        return minutes.map(compact).joined(separator: separator)
    }

    /// "HH:mm" for a minute of the day.
    static func clock(_ minuteOfDay: Int) -> String {
        let minute = min(max(minuteOfDay, 0), 1439)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// ", " in English, "、" in Chinese: the UI language the strings resolved to.
    static var separator: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "、" : ", "
    }

    private static func compact(_ minutes: Int) -> String {
        if minutes <= 0 { return String(localized: "at start") }
        if minutes == 1440 { return String(localized: "1 day") }
        if minutes % 1440 == 0 { return String(localized: "\(minutes / 1440) days") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) h") }
        return String(localized: "\(minutes) min")
    }
}
